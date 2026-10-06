"""Prépare les archives à envoyer à la personne qui fait les rendus.

  python bench/render/pack_inputs.py          # -> data/render_inputs.zip
  python bench/render/pack_inputs.py --renders # -> data/renders.zip (au retour)

render_inputs.zip contient, pour chaque jeu de run_renders.DATASETS présent,
les fichiers sous data/ (Alembic + manifeste .json, ou dossier VDB), avec les
chemins relatifs « data/... » : il suffit de décompresser à la racine du dépôt.
Pour les volumes, seules les images rendues sont incluses (archive allégée).
Les fichiers sont stockés sans recompression (Alembic et VDB se compressent mal).
"""
import argparse
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_renders import DATA, DATASETS, ROOT  # noqa: E402


def frame_number(path):
    digits = "".join(c if c.isdigit() else " " for c in path.stem).split()
    return int(digits[-1]) if digits else 1


def add(z, path):
    z.write(path, path.relative_to(ROOT).as_posix())
    return path.stat().st_size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--renders", action="store_true", help="archive les rendus faits")
    args = ap.parse_args()
    if args.renders:
        dst, files = DATA / "renders.zip", sorted((DATA / "renders").rglob("*"))
        files += sorted((Path(__file__).parent / "cameras").glob("*.json"))
    else:
        dst, files = DATA / "render_inputs.zip", []
        for name, (rel, kind, count) in DATASETS.items():
            src = DATA / rel
            if not src.exists():
                print(f"  {name} : absent, non inclus")
                continue
            if kind == "vdb":
                # Seulement les images rendues (mêmes numéros que render_bench.py) :
                # la fumée complète pèse 7,5 Go, ses 12 images rendues ~750 Mo.
                vdbs = sorted(src.glob("*.vdb"), key=frame_number)
                last = frame_number(vdbs[-1])
                keep = {1 + round(i * (last - 1) / max(1, count - 1)) for i in range(min(count, last))}
                files += [f for f in vdbs if frame_number(f) in keep] + sorted(src.glob("*.json"))
            else:
                files += [src, src.with_suffix(".json")]
            print(f"  {name} : inclus")
    total = 0
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED) as z:
        for f in files:
            if f.is_file():
                total += add(z, f)
    print(f"{dst} : {total / 1e6:,.0f} Mo")


if __name__ == "__main__":
    main()
