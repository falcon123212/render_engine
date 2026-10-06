"""Vérifie la machine de rendu avant de lancer quoi que ce soit.

  python bench/render/check_setup.py [--blender CHEMIN]

Contrôles : version de Python, Blender 5.0.x, carte NVIDIA vue par Cycles en
OptiX (et pilote), données présentes, caméras figées, espace disque.
Termine par « PRÊT » ou par la liste de ce qui manque.
"""
import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from run_renders import CAMERAS, DATA, DATASETS, DEFAULT_BLENDER  # noqa: E402

problems = []


def check(ok, label, detail="", fatal=True):
    print(f"  [{'OK' if ok else ('KO' if fatal else '--')}] {label}{(' : ' + detail) if detail else ''}")
    if not ok and fatal:
        problems.append(label)
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--blender", default=DEFAULT_BLENDER)
    args = ap.parse_args()

    print("Système")
    check(sys.version_info >= (3, 10), "Python 3.10 ou plus", sys.version.split()[0])
    check(platform.system() in ("Windows", "Linux"), "Système Windows ou Linux", platform.system())
    free = shutil.disk_usage(DATA.parent).free / 1e9
    check(free > 5, "Espace disque libre > 5 Go", f"{free:.0f} Go")
    try:
        smi = subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version",
                              "--format=csv,noheader"], capture_output=True, text=True, timeout=30)
        check(smi.returncode == 0, "Pilote NVIDIA (nvidia-smi)", smi.stdout.strip())
    except FileNotFoundError:
        check(False, "Pilote NVIDIA (nvidia-smi)", "introuvable")

    print("Blender")
    blender = Path(args.blender)
    if check(blender.exists(), "Blender trouvé", f"{blender} (sinon --blender CHEMIN)"):
        out = subprocess.run([str(blender), "--version"], capture_output=True, text=True,
                             timeout=120).stdout
        m = re.search(r"Blender (\d+\.\d+\.\d+)", out)
        version = m.group(1) if m else "?"
        check(version.startswith("5.0."), "Version 5.0.x", version)
        expr = ("import bpy; p=bpy.context.preferences.addons['cycles'].preferences; "
                "p.compute_device_type='OPTIX'; p.refresh_devices(); "
                "print('RDC_GPU=' + '|'.join(d.name for d in p.devices if d.type=='OPTIX'))")
        out = subprocess.run([str(blender), "-b", "--factory-startup", "--python-expr", expr],
                             capture_output=True, text=True, timeout=300).stdout
        gpus = next((l.split("=", 1)[1] for l in out.splitlines() if l.startswith("RDC_GPU=")), "")
        check(bool(gpus), "Carte vue par Cycles en OptiX", gpus or "aucune (mettre à jour le pilote)")

    print("Données et caméras")
    present = 0
    for name, (rel, kind, _) in DATASETS.items():
        src = DATA / rel
        cam = CAMERAS / f"{name}.json"
        if src.exists():
            present += 1
            check(cam.exists(), f"{name}", "données + caméra" if cam.exists() else "caméra manquante")
        else:
            check(False, name, "pas encore fourni (normal s'il n'est pas dans l'archive)", fatal=False)
    check(present > 0, "Au moins un jeu présent",
          f"{present} jeu(x)" if present else "décompresser render_inputs.zip à la racine du dépôt")

    print()
    if problems:
        print("À CORRIGER : " + " ; ".join(problems))
        return 1
    print(f"PRÊT : {present} jeu(x) à rendre. Étape suivante : python bench/render/run_renders.py --quick")
    return 0


if __name__ == "__main__":
    sys.exit(main())
