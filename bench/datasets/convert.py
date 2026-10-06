"""Convertit les jeux bruts (data/raw) en références du banc (data/bench).

  python bench/datasets/convert.py [vlasic] [disney] [smoke DOSSIER_CACHE]

- vlasic : séquences OBJ -> data/bench/geom/vlasic_<seq>.abc (+ .json),
  Alembic Ogawa « topologie + positions » via objseq2abc.
- disney : nuage 1/4 et 1/2 -> data/bench/vol/disney_<res>/ en float32 Blosc
  via vdbnorm.
- smoke DOSSIER : cache OpenVDB Mantaflow -> data/bench/vol/smoke/ via vdbnorm.

Sans argument : vlasic et disney.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / "build" / "tools" / "RelWithDebInfo"
RAW = ROOT / "data" / "raw"
BENCH = ROOT / "data" / "bench"

# Cadence de capture de Vlasic et al. 2008 (non précisée sur la page du jeu).
VLASIC_FPS = 30


def run(*cmd):
    print(">", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run([str(c) for c in cmd], check=True)


def convert_vlasic():
    out = BENCH / "geom"
    out.mkdir(parents=True, exist_ok=True)
    seqs = sorted((RAW / "vlasic").iterdir())
    bases = [s.name.split("_", 1)[1] for s in seqs]
    for seq_dir, base in zip(seqs, bases):
        # march et squat existent en deux versions (I_ et D_) : suffixe I ou D.
        name = f"{base}_{seq_dir.name[0]}" if bases.count(base) > 1 else base
        abc = out / f"vlasic_{name}.abc"
        run(TOOLS / "objseq2abc.exe", seq_dir / "meshes", "-o", abc,
            "--fps", VLASIC_FPS, "--name", name, "--json", abc.with_suffix(".json"))


def convert_disney():
    for res in ("quarter", "half"):
        src = RAW / "disney" / f"wdas_cloud_{res}.vdb"
        dst = BENCH / "vol" / f"disney_{res}"
        run(TOOLS / "vdbnorm.exe", src, "-o", dst, "--prefix", f"disney_{res}",
            "--json", dst / "stats.json")


def convert_smoke(cache_dir, dst=None):
    # Les VDB de Mantaflow sont dans <cache>/data/fluid_data_NNNN.vdb.
    src = Path(cache_dir) / "data" if (Path(cache_dir) / "data").is_dir() else Path(cache_dir)
    dst = Path(dst) if dst else BENCH / "vol" / "smoke"
    run(TOOLS / "vdbnorm.exe", src, "-o", dst, "--prefix", "smoke",
        "--json", dst / "stats.json")


def main(argv):
    if not argv:
        argv = ["vlasic", "disney"]
    i = 0
    while i < len(argv):
        if argv[i] == "vlasic":
            convert_vlasic()
        elif argv[i] == "disney":
            convert_disney()
        elif argv[i] == "smoke" and i + 1 < len(argv):
            i += 1
            convert_smoke(Path(argv[i]))
        else:
            sys.exit(__doc__)
        i += 1


if __name__ == "__main__":
    main(sys.argv[1:])
