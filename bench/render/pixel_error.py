"""Erreur géométrique projetée, en pixels, sans rendu (toutes les images).

  blender -b --factory-startup --python pixel_error.py -- --orig A.abc
          (--decoded B.abc | --noise SIGMA) --camera cam.json [--json sortie.json]

Projette chaque sommet de l'original et du décodé avec la caméra figée du
banc (celle de render_bench.py, 4K par défaut) et mesure leur écart à
l'écran. --noise SIGMA remplace le décodé par l'original + bruit gaussien de
SIGMA unités scène (autotest de l'outil).

Critère du plan : erreur maximale <= 0,5 px (arrêt si > 1 px).
"""
import json
import sys
from pathlib import Path

import bpy
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "datasets" / "blender"))
import common  # noqa: E402


def configure(p):
    p.add_argument("--orig", required=True)
    p.add_argument("--decoded")
    p.add_argument("--noise", type=float)
    p.add_argument("--camera", required=True)
    p.add_argument("--json")


def load(path, fps):
    before = set(bpy.data.objects)
    bpy.ops.wm.alembic_import(filepath=str(path), set_frame_range=True)
    return sorted((o for o in bpy.data.objects if o not in before and o.type == 'MESH'),
                  key=lambda o: o.name)


args = common.parse_args(configure)
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
manifest = Path(args.orig).with_suffix(".json")
info = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else {}
scene.render.fps, scene.render.fps_base = int(info.get("fps", 24)), 1.0
orig = load(args.orig, scene.render.fps)
dec = load(args.decoded, scene.render.fps) if args.decoded else None
frames = scene.frame_end - scene.frame_start + 1

spec = json.loads(Path(args.camera).read_text(encoding="utf-8"))
w, h = spec["resolution"]
cam = common.link(bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam")))
cam.location, cam.rotation_euler = spec["location"], spec["rotation_euler"]
cam.data.lens, cam.data.sensor_width = spec["lens"], spec["sensor_width"]
cam.data.sensor_fit = 'HORIZONTAL'
scene.render.resolution_x, scene.render.resolution_y = w, h
bpy.context.view_layer.update()
proj = np.array(cam.calc_matrix_camera(bpy.context.evaluated_depsgraph_get(), x=w, y=h))
view = np.array(cam.matrix_world.inverted())
mvp = proj @ view


def to_pixels(pts):
    hom = np.c_[pts, np.ones(len(pts))] @ mvp.T
    ndc = hom[:, :2] / hom[:, 3:4]
    return np.c_[(ndc[:, 0] + 1) * 0.5 * w, (ndc[:, 1] + 1) * 0.5 * h], hom[:, 3] > 0


rng = np.random.default_rng(1)
per_frame = []
for f in range(1, frames + 1):
    scene.frame_set(f)
    dg = bpy.context.evaluated_depsgraph_get()
    a = common.world_points(orig, dg)
    b = common.world_points(dec, dg) if dec else a + rng.normal(0, args.noise, a.shape)
    pa, front = to_pixels(a)
    pb, _ = to_pixels(b)
    d = np.linalg.norm(pb - pa, axis=1)[front]
    per_frame.append({"frame": f, "max_px": float(d.max()), "p999_px": float(np.quantile(d, 0.999)),
                      "mean_px": float(d.mean())})

worst = max(per_frame, key=lambda r: r["max_px"])
mean = float(np.mean([r["mean_px"] for r in per_frame]))
verdict = "OK" if worst["max_px"] <= 0.5 else ("ARRÊT" if worst["max_px"] > 1.0 else "LIMITE")
print(f"ERREUR PX : max {worst['max_px']:.3f} (image {worst['frame']}), moyenne {mean:.4f}, "
      f"{frames} images, {w}x{h} -> {verdict}")
if args.json:
    Path(args.json).write_text(json.dumps({
        "orig": args.orig, "decoded": args.decoded, "noise": args.noise, "resolution": [w, h],
        "max_px": worst["max_px"], "worst_frame": worst["frame"], "mean_px": mean,
        "verdict": verdict, "frames": per_frame}, indent=2), encoding="utf-8")
