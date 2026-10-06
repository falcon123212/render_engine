"""Génère les jeux de données synthétiques du banc (à lancer le soir).

  python bench/datasets/generate.py [--character perso.fbx] [--only cloth smoke ...]
                                    [--quick]

Étapes (dans l'ordre, une seule tâche lourde à la fois pour tenir dans 16 Go) :
  cloth      tissu violent, 64 k sommets, 120 images      ~30-90 min
  character  personnage héros ~100 k sommets (--character) ~5 min
  crowd      foule de 200 agents ~10 k sommets (--character) ~10-20 min
  smoke      fumée Mantaflow 256, 120 images + vdbnorm      ~1-2 h
--quick : petites résolutions, pour vérifier la chaîne en quelques minutes.

Journaux : data/logs/<étape>.log ; résumé : data/logs/generate_summary.json.
"""
import argparse
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = Path(__file__).parent / "blender"
DATA = ROOT / "data"
BLENDER = Path(r"C:\Program Files\Blender Foundation\Blender 5.0\blender.exe")
MIN_FREE_GB = 30

sys.path.insert(0, str(Path(__file__).parent))
import convert  # noqa: E402


def blender(script, *script_args):
    return [str(BLENDER), "-b", "--factory-startup", "--python-exit-code", "1",
            "--python", str(SCRIPTS / script), "--", *map(str, script_args)]


def steps(args):
    geom, work = DATA / "bench" / "geom", DATA / "work"
    q = args.quick
    out = {}
    out["cloth"] = [blender("gen_cloth_violent.py",
                            *(["--nx", 80, "--ny", 50, "--frames", 24] if q else []),
                            "--out", geom / ("cloth_violent_quick.abc" if q else "cloth_violent.abc"))]
    if args.character:
        out["character"] = [blender("gen_crowd.py", "--character", args.character, "--agents", 1,
                                    "--target-verts", 10000 if q else 100000,
                                    *(["--frames", 24] if q else []),
                                    "--out", geom / ("character_quick.abc" if q else "character.abc"))]
        out["crowd"] = [blender("gen_crowd.py", "--character", args.character,
                                *(["--agents", 10, "--frames", 24] if q else []),
                                "--out", geom / ("crowd_quick.abc" if q else "crowd.abc"))]
    cache = work / ("smoke_cache_quick" if q else "smoke_cache")
    out["smoke"] = [blender("gen_smoke.py", *(["--res", 48, "--frames", 24] if q else []),
                            "--cache", cache),
                    lambda: convert.convert_smoke(
                        cache, DATA / "bench" / "vol" / ("smoke_quick" if q else "smoke"))]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--character", help="FBX/glTF/.blend du personnage (ex. Mixamo)")
    ap.add_argument("--only", nargs="+", choices=["cloth", "character", "crowd", "smoke"])
    ap.add_argument("--quick", action="store_true")
    args = ap.parse_args()

    free_gb = shutil.disk_usage(DATA if DATA.exists() else ROOT).free / 1e9
    if free_gb < MIN_FREE_GB and not args.quick:
        sys.exit(f"seulement {free_gb:.0f} Go libres (minimum {MIN_FREE_GB})")
    plan = steps(args)
    if not args.character and not args.only:
        print("  sans --character : personnage et foule ignorés")
    names = [n for n in plan if not args.only or n in args.only]
    logs = DATA / "logs"
    logs.mkdir(parents=True, exist_ok=True)

    summary = {}
    for name in names:
        t0 = time.time()
        log = logs / f"{name}{'_quick' if args.quick else ''}.log"
        print(f"[{name}] ... (journal : {log})", flush=True)
        ok = True
        with open(log, "w", encoding="utf-8") as f:
            for cmd in plan[name]:
                if callable(cmd):
                    cmd()
                    continue
                ok = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT).returncode == 0
                if not ok:
                    break
        summary[name] = {"ok": ok, "minutes": round((time.time() - t0) / 60, 1)}
        print(f"[{name}] {'OK' if ok else 'ÉCHEC'} en {summary[name]['minutes']} min", flush=True)
    (logs / "generate_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    return 0 if all(s["ok"] for s in summary.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
