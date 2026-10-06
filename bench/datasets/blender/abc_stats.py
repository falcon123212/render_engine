"""Mesures de mouvement d'un ou plusieurs Alembic, ajoutées à leur manifeste.

  blender -b --python abc_stats.py -- fichier1.abc [fichier2.abc ...]

Pour chaque X.abc : importe, calcule common.motion_stats (vitesse et résidu
de l'extrapolation linéaire) et écrit la clé « motion » dans X.json.
"""
import json
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).parent))
import common  # noqa: E402

files = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
for f in map(Path, files):
    manifest = f.with_suffix(".json")
    info = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else {}
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    # Cadence de la scène = cadence du fichier, sinon Blender rééchantillonne
    # (et interpole) les positions : les mesures seraient fausses.
    scene.render.fps, scene.render.fps_base = int(info.get("fps", 24)), 1.0
    bpy.ops.wm.alembic_import(filepath=str(f), set_frame_range=True)
    meshes = [o for o in scene.objects if o.type == 'MESH']
    # L'import Alembic démarre à l'image 1 pour un échantillonnage commençant à 0.
    frames = scene.frame_end - scene.frame_start + 1
    scene.frame_start = 1
    motion = common.motion_stats(meshes, frames)
    print(f"{f.stem} ({frames} images)")
    common.print_motion(motion)
    if "frames" in info and info["frames"] != frames:
        print(f"  ATTENTION : {frames} images lues, {info['frames']} attendues")
    info["motion"] = motion
    manifest.write_text(json.dumps(info, indent=2, ensure_ascii=False), encoding="utf-8")
