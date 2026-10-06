"""Mesure les références du banc et écrit data/results/refs/*.json + un résumé.

  python bench/refs/measure_refs.py [geom] [vol]

Géométrie (data/bench/geom/*.abc, contenu « topologie + positions ») :
  - positions brutes float32 (12 o par sommet et par image) ;
  - Alembic Ogawa (le fichier tel quel) ;
  - Alembic + zstd niveaux 3 et 19 (fichier entier) ;
  - USD crate (.usdc avec time samples, exporté par Blender 5.0).
Volumes (data/bench/vol/<jeu>/) : outil vdbref (OpenVDB Blosc, NanoVDB
float/Fp16/Fp8/FpN, Fp8 + zstd, ZFP par feuille 8^3).

Draco n'est pas mesuré (non installé) : à ajouter si besoin.
"""
import json
import subprocess
import sys
from compression import zstd
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
OUT = DATA / "results" / "refs"
TOOLS = ROOT / "build" / "tools" / "RelWithDebInfo"
BLENDER = Path(r"C:\Program Files\Blender Foundation\Blender 5.0\blender.exe")
USDC_SCRIPT = ROOT / "bench" / "datasets" / "blender" / "usdc_export.py"


def measure_geom():
    rows = []
    for abc in sorted((DATA / "bench" / "geom").glob("*.abc")):
        if "quick" in abc.stem:
            continue
        info = json.loads(abc.with_suffix(".json").read_text(encoding="utf-8"))
        data = abc.read_bytes()
        raw = info["vertices"] * 12 * info["frames"]
        usdc = DATA / "work" / "usdc" / f"{abc.stem}.usdc"
        usdc.parent.mkdir(parents=True, exist_ok=True)
        if not usdc.exists():
            subprocess.run([str(BLENDER), "-b", "--factory-startup", "--python", str(USDC_SCRIPT),
                            "--", str(abc), str(usdc), str(info.get("fps", 24))],
                           check=True, capture_output=True)
        sizes = {
            "raw_float32": raw,
            "alembic_ogawa": len(data),
            "alembic_zstd3": len(zstd.compress(data, level=3)),
            "alembic_zstd19": len(zstd.compress(data, level=19)),
            "usdc": usdc.stat().st_size,
        }
        row = {"dataset": abc.stem, "frames": info["frames"], "vertices": info["vertices"],
               "bytes": sizes,
               "bits_per_vertex_frame": {k: 8 * v / (info["vertices"] * info["frames"])
                                         for k, v in sizes.items()},
               "linear_residual_mean_rel": info.get("motion", {}).get("linear_residual_mean_rel")}
        rows.append(row)
        b = row["bits_per_vertex_frame"]
        print(f"{abc.stem:22s} {info['vertices']:7d} s x {info['frames']:3d} i | bits/sommet/image :"
              f" Ogawa {b['alembic_ogawa']:5.1f}  +zstd3 {b['alembic_zstd3']:5.1f}"
              f"  +zstd19 {b['alembic_zstd19']:5.1f}  usdc {b['usdc']:5.1f}")
    (OUT / "geom.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")


def measure_vol():
    for d in sorted((DATA / "bench" / "vol").iterdir()):
        if d.is_dir() and "quick" not in d.name:
            print(f"== {d.name}", flush=True)
            subprocess.run([str(TOOLS / "vdbref.exe"), str(d), "--json", str(OUT / f"{d.name}.json")],
                           check=True)


def main(argv):
    OUT.mkdir(parents=True, exist_ok=True)
    todo = argv or ["geom", "vol"]
    if "geom" in todo:
        measure_geom()
    if "vol" in todo:
        measure_vol()


if __name__ == "__main__":
    main(sys.argv[1:])
