# cube unite [-0.5, 0.5]^3 au format glTF (positions, normales, uv, tangentes), materiau mat clair
import json, struct, os
D = os.path.dirname(os.path.abspath(__file__))
faces = [((1,0,0),(0,0,-1)),((-1,0,0),(0,0,1)),((0,1,0),(1,0,0)),((0,-1,0),(1,0,0)),((0,0,1),(1,0,0)),((0,0,-1),(-1,0,0))]
P, N, T, UV, I = [], [], [], [], []
for n, t in faces:
    b = [n[1]*t[2]-n[2]*t[1], n[2]*t[0]-n[0]*t[2], n[0]*t[1]-n[1]*t[0]]
    base = len(P)
    for su, sv in ((-1,-1),(1,-1),(1,1),(-1,1)):
        P.append([0.5*(n[k] + su*t[k] + sv*b[k]) for k in range(3)]); N.append(list(n)); T.append(list(t)+[1.0]); UV.append([(su+1)/2,(sv+1)/2])
    I += [base, base+1, base+2, base, base+2, base+3]
blob = b"".join(struct.pack("<3f", *p) for p in P) + b"".join(struct.pack("<3f", *n) for n in N) + b"".join(struct.pack("<4f", *t) for t in T) + b"".join(struct.pack("<2f", *u) for u in UV)
off_i = len(blob); blob += b"".join(struct.pack("<H", i) for i in I)
open(os.path.join(D, "box.bin"), "wb").write(blob)
nv = len(P)
g = {"asset": {"version": "2.0"}, "scene": 0, "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "box"}],
     "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TANGENT": 2, "TEXCOORD_0": 3}, "indices": 4, "material": 0}]}],
     "materials": [{"name": "panneau", "pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.5, 0.5, 1.0], "metallicFactor": 0.0, "roughnessFactor": 0.9}}],
     "buffers": [{"uri": "box.bin", "byteLength": len(blob)}],
     "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": nv*12, "target": 34962}, {"buffer": 0, "byteOffset": nv*12, "byteLength": nv*12, "target": 34962},
                     {"buffer": 0, "byteOffset": nv*24, "byteLength": nv*16, "target": 34962}, {"buffer": 0, "byteOffset": nv*40, "byteLength": nv*8, "target": 34962},
                     {"buffer": 0, "byteOffset": off_i, "byteLength": len(I)*2, "target": 34963}],
     "accessors": [{"bufferView": 0, "componentType": 5126, "count": nv, "type": "VEC3", "min": [-0.5]*3, "max": [0.5]*3},
                   {"bufferView": 1, "componentType": 5126, "count": nv, "type": "VEC3"}, {"bufferView": 2, "componentType": 5126, "count": nv, "type": "VEC4"},
                   {"bufferView": 3, "componentType": 5126, "count": nv, "type": "VEC2"}, {"bufferView": 4, "componentType": 5123, "count": len(I), "type": "SCALAR"}]}
json.dump(g, open(os.path.join(D, "box.gltf"), "w"), indent=1)
print("ok", nv, len(I))
