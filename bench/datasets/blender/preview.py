"""Aperçu rapide (Workbench) d'un .blend ou d'un .abc à quelques images.

  blender -b [scene.blend] --python preview.py -- --frames 24 48 72 --out dossier
          [--abc fichier.abc] [--res 480]

Assemble les images côte à côte dans <out>/<nom>_preview.png.
"""
import sys
from pathlib import Path

import bpy
from mathutils import Vector

sys.path.insert(0, str(Path(__file__).parent))
import common  # noqa: E402


def configure(p):
    p.add_argument("--abc")
    p.add_argument("--out", required=True)
    p.add_argument("--res", type=int, default=480)
    p.add_argument("--at", type=int, nargs="+", default=[24, 48, 72])


args = common.parse_args(configure)
scene = bpy.context.scene
if args.abc:
    common.reset_scene(max(args.at), 24)
    scene = bpy.context.scene
    bpy.ops.wm.alembic_import(filepath=args.abc)
name = Path(args.abc).stem if args.abc else Path(bpy.data.filepath).stem
meshes = [o for o in scene.objects if o.type == 'MESH']

# Caméra cadrée sur l'union des boîtes englobantes des images montrées.
lo, hi = [float("inf")] * 3, [float("-inf")] * 3
for f in args.at:
    _, _, flo, fhi = common.evaluated_stats(meshes, f)
    lo = [min(a, b) for a, b in zip(lo, flo)]
    hi = [max(a, b) for a, b in zip(hi, fhi)]
center = (Vector(lo) + Vector(hi)) / 2
radius = (Vector(hi) - Vector(lo)).length / 2
cam = common.link(bpy.data.objects.new("PreviewCam", bpy.data.cameras.new("PreviewCam")))
cam.location = center + Vector((0.9, -2.2, 0.9)).normalized() * radius * 2.6
cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
scene.camera = cam

scene.render.engine = 'BLENDER_WORKBENCH'
scene.display.shading.light = 'STUDIO'
scene.display.shading.color_type = 'SINGLE'
scene.render.resolution_x = args.res
scene.render.resolution_y = int(args.res * 0.75)
scene.render.image_settings.file_format = 'PNG'

out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
tiles = []
for f in args.at:
    scene.frame_set(f)
    scene.render.filepath = str(out / f"{name}_f{f:04d}.png")
    bpy.ops.render.render(write_still=True)
    tiles.append(bpy.data.images.load(scene.render.filepath))

# Planche : images côte à côte.
w, h = tiles[0].size
sheet = bpy.data.images.new("sheet", w * len(tiles), h)
pixels = [0.0] * (w * len(tiles) * h * 4)
for t, img in enumerate(tiles):
    px = img.pixels[:]
    for y in range(h):
        row = y * w * 4
        dst = (y * w * len(tiles) + t * w) * 4
        pixels[dst:dst + w * 4] = px[row:row + w * 4]
sheet.pixels = pixels
sheet.filepath_raw = str(out / f"{name}_preview.png")
sheet.file_format = 'PNG'
sheet.save()
for img in tiles:
    Path(img.filepath).unlink()
print(f"  aperçu : {sheet.filepath_raw}")
