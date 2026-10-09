"""Convertit une scene glTF 2.0 en maillage pour le bench CUDA (format MSH1).
Converts a glTF 2.0 scene into a mesh for the CUDA bench (MSH1 format).

    python3 convertir.py <scene.gltf> <sortie.mesh> [--echelle S]

- Tous les noeuds de la scene sont parcourus (matrices et TRS, instances comprises), triangles seulement.
- Repere : glTF (y vers le haut) -> bench (z vers le haut). Unites : metres. Si la scene semble etre en centimetres
  (diagonale > 400), elle est ramenee en metres ; --echelle force le facteur.
- Albedo par triangle : couleur de base du materiau (baseColorFactor, ou diffuseFactor pour les materiaux
  specular-glossiness), en luminance. Les textures ne sont pas lues (aucune bibliotheque d'image requise) : un materiau
  texture recoit 0,5 x son facteur, la reflectance moyenne typique d'une texture. Albedo borne a [0,05 ; 0,85].
- Materiaux transparents (alphaMode BLEND ou KHR_materials_transmission) : ignores (la lumiere les traverse).
  Les materiaux MASK (feuillages, rideaux de Sponza) sont gardes opaques : simplification.
- doubleSided est conserve : les deux faces portent des points de cache.

Format de sortie (little endian) : "MSH1", int32 n, float32[n][9] sommets, float32[n] albedo, uint8[n] double face.
"""
import base64
import json
import math
import os
import struct
import sys

try:
    import numpy as np
except ImportError:
    sys.exit("ERREUR : numpy manquant. Ubuntu : sudo apt install python3-numpy ; ailleurs : pip install numpy")

CT = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NC = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load_buffers(g, base):
    out = []
    for b in g["buffers"]:
        uri = b.get("uri", "")
        if uri.startswith("data:"):
            out.append(base64.b64decode(uri.split(",", 1)[1]))
        else:
            out.append(open(os.path.join(base, uri.replace("%20", " ")), "rb").read())
    return out


def accessor(g, bufs, i):
    a = g["accessors"][i]
    n, k, dt = a["count"], NC[a["type"]], CT[a["componentType"]]
    if "bufferView" not in a:
        return np.zeros((n, k), dt)
    bv = g["bufferViews"][a["bufferView"]]
    buf = bufs[bv["buffer"]]
    off = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
    item = np.dtype(dt).itemsize * k
    stride = bv.get("byteStride", item)
    if stride == item:
        arr = np.frombuffer(buf, dt, n * k, off).reshape(n, k)
    else:
        raw = np.frombuffer(buf, np.uint8, (n - 1) * stride + item, off)
        arr = np.lib.stride_tricks.as_strided(raw, (n, item), (stride, 1)).copy().view(dt).reshape(n, k)
    if a.get("normalized") and dt != np.float32:
        arr = arr.astype(np.float32) / np.iinfo(dt).max
    return arr


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def node_matrix(nd):
    if "matrix" in nd:
        return np.array(nd["matrix"], float).reshape(4, 4).T
    M = np.eye(4)
    M[:3, :3] = quat_mat(nd.get("rotation", [0, 0, 0, 1])) * np.array(nd.get("scale", [1, 1, 1]))[None, :]
    M[:3, 3] = nd.get("translation", [0, 0, 0])
    return M


def material_info(g, mi):
    """(albedo, double face, transparent)"""
    if mi is None:
        return 0.6, False, False
    m = g["materials"][mi]
    ext = m.get("extensions", {})
    sg = ext.get("KHR_materials_pbrSpecularGlossiness")
    if sg is not None:
        f, tex = sg.get("diffuseFactor", [1, 1, 1, 1]), "diffuseTexture" in sg
    else:
        p = m.get("pbrMetallicRoughness", {})
        f, tex = p.get("baseColorFactor", [1, 1, 1, 1]), "baseColorTexture" in p
    lum = 0.2126 * f[0] + 0.7152 * f[1] + 0.0722 * f[2]
    alb = min(0.85, max(0.05, lum * (0.5 if tex else 1.0)))
    tr = ext.get("KHR_materials_transmission", {}).get("transmissionFactor", 0) > 0 or m.get("alphaMode") == "BLEND"
    return alb, bool(m.get("doubleSided", False)), tr


def main():
    args = [a for a in sys.argv[1:]]
    scale = None
    if "--echelle" in args:
        i = args.index("--echelle"); scale = float(args[i + 1]); del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    src, dst = args
    g = json.load(open(src, encoding="utf-8"))
    bufs = load_buffers(g, os.path.dirname(os.path.abspath(src)))
    mats = [material_info(g, i) for i in range(len(g.get("materials", [])))]
    cache = {}
    tris, albs, dss = [], [], []
    skipped = 0

    def visit(ni, parent):
        nonlocal skipped
        nd = g["nodes"][ni]
        M = parent @ node_matrix(nd)
        if "mesh" in nd:
            for p in g["meshes"][nd["mesh"]]["primitives"]:
                if p.get("mode", 4) != 4:
                    continue
                mi = p.get("material")
                alb, ds, tr = mats[mi] if mi is not None else (0.6, False, False)
                if tr:
                    skipped += 1
                    continue
                key = (p["attributes"]["POSITION"], p.get("indices"))
                if key not in cache:
                    P = accessor(g, bufs, key[0]).astype(np.float64)
                    I = accessor(g, bufs, key[1]).reshape(-1).astype(np.int64) if key[1] is not None else np.arange(len(P))
                    cache[key] = (P, I[: len(I) // 3 * 3].reshape(-1, 3))
                P, I = cache[key]
                W = P @ M[:3, :3].T + M[:3, 3]
                T = W[I]                                   # (n, 3, 3)
                if np.linalg.det(M[:3, :3]) < 0:           # miroir : on garde l'orientation des faces
                    T = T[:, [0, 2, 1]]
                tris.append(T.astype(np.float32))
                albs.append(np.full(len(T), alb, np.float32))
                dss.append(np.full(len(T), 1 if ds else 0, np.uint8))
        for c in nd.get("children", []):
            visit(c, M)

    sys.setrecursionlimit(100000)
    sc = g["scenes"][g.get("scene", 0)] if "scenes" in g else {"nodes": list(range(len(g["nodes"])))}
    for ni in sc["nodes"]:
        visit(ni, np.eye(4))
    T = np.concatenate(tris).reshape(-1, 9)
    A = np.concatenate(albs)
    D = np.concatenate(dss)
    T = T.reshape(-1, 3, 3)[:, :, [0, 2, 1]]          # y vers le haut -> z vers le haut : (x, y, z) -> (x, -z, y)
    T[:, :, 1] *= -1
    T = T.reshape(-1, 9)                                # (x,-z,y) garde l'orientation (rotation propre)
    lo, hi = T.reshape(-1, 3).min(0), T.reshape(-1, 3).max(0)
    diag = float(np.linalg.norm(hi - lo))
    if scale is None:
        scale = 0.01 if diag > 400 else 1.0
    T *= scale
    e1, e2 = T[:, 3:6] - T[:, 0:3], T[:, 6:9] - T[:, 0:3]
    keep = np.linalg.norm(np.cross(e1, e2), axis=1) > 1e-10
    T, A, D = T[keep], A[keep], D[keep]
    with open(dst, "wb") as f:
        f.write(b"MSH1")
        f.write(struct.pack("<i", len(T)))
        f.write(np.ascontiguousarray(T, np.float32).tobytes())
        f.write(np.ascontiguousarray(A, np.float32).tobytes())
        f.write(np.ascontiguousarray(D, np.uint8).tobytes())
    lo, hi = T.reshape(-1, 3).min(0), T.reshape(-1, 3).max(0)
    print(json.dumps({"type": "maillage", "source": os.path.basename(src), "triangles": int(len(T)),
                      "transparents_ignores": skipped, "echelle": scale, "taille_m": [round(float(x), 2) for x in hi - lo],
                      "double_face": round(float(D.mean()), 3), "albedo_moyen": round(float(A.mean()), 3)}))


if __name__ == "__main__":
    main()
