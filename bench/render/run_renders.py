"""Lance les rendus de comparaison du banc, jeu par jeu (reprise automatique).

  python bench/render/run_renders.py                 # tout ce qui est disponible
  python bench/render/run_renders.py --quick         # test rapide (2 images, 960x540)
  python bench/render/run_renders.py --only cloth_violent vlasic_samba
  python bench/render/run_renders.py --labels decoded --decoded-root data/decoded

Pour chaque jeu présent dans data/ : rendus « orig » (graine 1) et « seedB »
(graine différente, plancher de bruit), 12 images en 4K entière, caméra figée
lue dans bench/render/cameras/<jeu>.json. Sorties : data/renders/<jeu>/<label>/.
Un rendu déjà présent n'est pas refait : on peut interrompre et relancer.
"""
import argparse
import glob
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "data"
CAMERAS = Path(__file__).parent / "cameras"
SCRIPT = Path(__file__).parent / "render_bench.py"


def find_blender():
    """Blender 5.0 : variable BLENDER, sinon emplacements habituels (Windows, Linux)."""
    if os.environ.get("BLENDER"):
        return os.environ["BLENDER"]
    if platform.system() == "Windows":
        return r"C:\Program Files\Blender Foundation\Blender 5.0\blender.exe"
    # Linux : archive officielle décompressée (~/blender-5.0.1-linux-x64/blender),
    # /opt, ou un « blender » dans le PATH.
    home = os.path.expanduser("~")
    for pattern in (f"{home}/blender-5.0*/blender", f"{home}/*/blender-5.0*/blender",
                    "/opt/blender-5.0*/blender", "/opt/blender*/blender"):
        hits = sorted(glob.glob(pattern))
        if hits:
            return hits[-1]
    return shutil.which("blender") or "blender"


DEFAULT_BLENDER = find_blender()

# jeu -> (chemin sous data/, type, nombre d'images rendues)
DATASETS = {
    "vlasic_samba":    ("bench/geom/vlasic_samba.abc", "abc", 12),
    "vlasic_bouncing": ("bench/geom/vlasic_bouncing.abc", "abc", 12),
    "vlasic_march_I":  ("bench/geom/vlasic_march_I.abc", "abc", 12),
    "cloth_violent":   ("bench/geom/cloth_violent.abc", "abc", 12),
    "cloth_slow":      ("bench/geom/cloth_slow.abc", "abc", 12),
    "character":       ("bench/geom/character.abc", "abc", 12),
    "crowd":           ("bench/geom/crowd.abc", "abc", 12),
    "smoke":           ("bench/vol/smoke", "vdb", 12),
    "explosion":       ("bench/vol/explosion", "vdb", 12),
    "disney_cloud":    ("bench/vol/disney_quarter", "vdb", 1),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--blender", default=DEFAULT_BLENDER)
    ap.add_argument("--only", nargs="+", choices=list(DATASETS))
    ap.add_argument("--labels", nargs="+", default=["orig", "seedB"],
                    choices=["orig", "seedB", "decoded"])
    ap.add_argument("--decoded-root", help="racine des jeux décodés (même arborescence que data/)")
    ap.add_argument("--quick", action="store_true", help="2 images en 960x540 (test de la machine)")
    args = ap.parse_args()

    if not Path(args.blender).exists():
        sys.exit(f"Blender introuvable : {args.blender} (option --blender ou variable BLENDER)")
    out_root = DATA / ("renders_quick" if args.quick else "renders")
    report = {}
    for name, (rel, kind, count) in DATASETS.items():
        if args.only and name not in args.only:
            continue
        src = DATA / rel
        if not src.exists():
            print(f"[{name}] absent ({rel}) : ignoré")
            continue
        camera = CAMERAS / f"{name}.json"
        if not camera.exists():
            print(f"[{name}] ATTENTION : pas de caméra figée, elle sera créée ({camera}).")
            print("        Renvoie ce fichier avec les rendus : les rendus décodés devront l'utiliser.")
        for label in args.labels:
            if label == "decoded":
                if not args.decoded_root:
                    sys.exit("--labels decoded demande --decoded-root")
                src_label = Path(args.decoded_root) / rel
                if not src_label.exists():
                    print(f"[{name}/decoded] absent ({src_label}) : ignoré")
                    continue
            else:
                src_label = src
            out = out_root / name
            n = min(2, count) if args.quick else count
            if len(list((out / label).glob("*.png"))) >= n:
                print(f"[{name}/{label}] déjà fait")
                continue
            cmd = [args.blender, "-b", "--factory-startup", "--python-exit-code", "1",
                   "--python", str(SCRIPT), "--",
                   "--abc" if kind == "abc" else "--vdb", str(src_label),
                   "--camera", str(camera), "--label", label, "--out", str(out),
                   "--count", str(n)]
            if args.quick:
                cmd += ["--res", "960", "540", "--samples", "64"]
            print(f"[{name}/{label}] {n} image(s)...", flush=True)
            t0 = time.time()
            log = out / f"{label}.log"
            log.parent.mkdir(parents=True, exist_ok=True)
            with open(log, "w", encoding="utf-8") as f:
                ok = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT).returncode == 0
            minutes = round((time.time() - t0) / 60, 1)
            report[f"{name}/{label}"] = {"ok": ok, "minutes": minutes}
            print(f"[{name}/{label}] {'OK' if ok else 'ÉCHEC (voir ' + str(log) + ')'} en {minutes} min",
                  flush=True)
    out_root.mkdir(parents=True, exist_ok=True)
    (out_root / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return 0 if all(r["ok"] for r in report.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
