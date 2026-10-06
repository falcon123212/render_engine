"""Prépare les archives à envoyer à la personne qui fait les rendus.

  python bench/render/pack_inputs.py          # -> data/render_inputs.zip
  python bench/render/pack_inputs.py --renders # -> data/renders.zip (au retour)

render_inputs.zip contient, pour chaque jeu de run_renders.DATASETS présent,
les fichiers sous data/ (Alembic + manifeste .json, ou dossier VDB), avec les
chemins relatifs « data/... » : il suffit de décompresser à la racine du dépôt.
Les fichiers sont stockés sans recompression (Alembic et VDB se compressent mal).
"""
import argparse
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_renders import DATA, DATASETS, ROOT  # noqa: E402


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
        for name, (rel, kind, _) in DATASETS.items():
            src = DATA / rel
            if not src.exists():
                print(f"  {name} : absent, non inclus")
                continue
            files += sorted(src.glob("*")) if kind == "vdb" else [src, src.with_suffix(".json")]
            print(f"  {name} : inclus")
    total = 0
    with zipfile.ZipFile(dst, "w", zipfile.ZIP_STORED) as z:
        for f in files:
            if f.is_file():
                total += add(z, f)
    print(f"{dst} : {total / 1e6:,.0f} Mo")


if __name__ == "__main__":
    main()
