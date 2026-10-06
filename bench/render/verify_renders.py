"""Vérifie les rendus avant de les renvoyer.

  python bench/render/verify_renders.py            # rendus complets (data/renders)
  python bench/render/verify_renders.py --quick    # test rapide (data/renders_quick)

Pour chaque jeu présent dans data/ et chaque label (orig, seedB) : présence de
toutes les images attendues (mêmes numéros que render_bench.py), résolution
de chaque PNG (lue dans l'en-tête), et timings.json (Blender 5.0.x, carte
utilisée, échantillons, graine). Termine par « COMPLET » ou la liste des manques.
"""
import argparse
import json
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_renders import DATA, DATASETS  # noqa: E402


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


def expected_frames(path_abc_json, count):
    """Mêmes images que render_bench.py : `count` réparties sur la séquence."""
    if count == 1:
        return [1]
    info = json.loads(path_abc_json.read_text(encoding="utf-8"))
    n = info["frames"]
    return sorted({1 + round(i * (n - 1) / max(1, count - 1)) for i in range(min(count, n))})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--labels", nargs="+", default=["orig", "seedB"])
    args = ap.parse_args()
    root = DATA / ("renders_quick" if args.quick else "renders")
    want_res = (960, 540) if args.quick else (3840, 2160)
    problems, total = [], 0

    for name, (rel, kind, count) in DATASETS.items():
        src = DATA / rel
        if not src.exists():
            continue
        n = min(2, count) if args.quick else count
        frames = expected_frames(src.with_suffix(".json"), n) if kind == "abc" else None
        for label in args.labels:
            folder = root / name / label
            pngs = sorted(folder.glob("*.png"))
            issues = []
            if frames is not None:
                missing = [f for f in frames if not (folder / f"{f:04d}.png").exists()]
                if missing:
                    issues.append(f"images manquantes {missing}")
            elif len(pngs) < n:
                issues.append(f"{len(pngs)}/{n} images")
            bad = [p.name for p in pngs if png_size(p) != want_res]
            if bad:
                issues.append(f"résolution incorrecte ({', '.join(bad[:3])}…)")
            timings = folder / "timings.json"
            gpu = "?"
            if timings.exists():
                t = json.loads(timings.read_text(encoding="utf-8"))
                gpu = ", ".join(t.get("devices", [])) or "AUCUNE (rendu CPU ?)"
                if not str(t.get("blender", "")).startswith("5.0."):
                    issues.append(f"Blender {t.get('blender')}")
                if not t.get("devices"):
                    issues.append("aucune carte utilisée")
            else:
                issues.append("timings.json absent")
            total += len(pngs)
            status = "OK" if not issues else "KO"
            print(f"  [{status}] {name:16s} {label:6s} {len(pngs):2d} PNG  {gpu}"
                  + (f"  -> {'; '.join(issues)}" if issues else ""))
            if issues:
                problems.append(f"{name}/{label}")

    print()
    if problems:
        print(f"INCOMPLET : {', '.join(problems)}. Relance run_renders.py (reprise automatique).")
        return 1
    print(f"COMPLET : {total} images. Étape suivante : python bench/render/pack_inputs.py --renders")
    return 0


if __name__ == "__main__":
    sys.exit(main())
