"""Porte de la phase 0 : le plugin .rdc fonctionne dans Blender 5.0.1.

À lancer via run_blender_tests.ps1 (qui règle PXR_PLUGINPATH_NAME) :
  1. USD trouve le plugin et le format .rdc ;
  2. Usd.Stage.Open("hello.rdc") renvoie les bons points à chaque image ;
  3. shot.usda (qui référence hello.rdc) s'importe dans Blender et s'anime ;
  4. une image se rend en Cycles.
"""
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector
from pxr import Plug, Sdf, Usd, UsdGeom

HERE = os.path.dirname(os.path.abspath(__file__))
FRAMES, FPS = 48, 24.0

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
parser = argparse.ArgumentParser()
parser.add_argument("--out", required=True)
args = parser.parse_args(argv)
os.makedirs(args.out, exist_ok=True)

failures = []


def check(cond, msg):
    print(("PASS  " if cond else "FAIL  ") + msg)
    if not cond:
        failures.append(msg)
    return cond


def expected_points(frame):
    """Même formule que _CubePoints dans src/usd_plugin/fileFormat.cpp."""
    base = [(-1, -1, -1), (1, -1, -1), (1, 1, -1), (-1, 1, -1),
            (-1, -1, 1), (1, -1, 1), (1, 1, 1), (-1, 1, 1)]
    t = frame - 1
    s = 1.0 + 0.3 * math.sin(2.0 * math.pi * t / FPS)
    sxy = 1.0 / math.sqrt(s)
    return [(x * sxy + 0.05 * t, y * sxy, (z + 1.0) * s) for x, y, z in base]


def max_diff(a, b):
    return max(abs(p - q) for pa, pb in zip(a, b) for p, q in zip(pa, pb))


# 1. Découverte du plugin -----------------------------------------------------
check(Plug.Registry().GetPluginWithName("rdcUsd") is not None,
      "plugin rdcUsd enregistré")
check(Sdf.FileFormat.FindByExtension("rdc") is not None,
      "format .rdc trouvé par extension")

# 2. Lecture directe via USD --------------------------------------------------
stage = Usd.Stage.Open(os.path.join(HERE, "hello.rdc"))
if check(stage is not None, "Usd.Stage.Open(hello.rdc)"):
    mesh = UsdGeom.Mesh(stage.GetDefaultPrim())
    attr = mesh.GetPointsAttr()
    check(attr.GetNumTimeSamples() == FRAMES,
          f"{attr.GetNumTimeSamples()} time samples (attendu {FRAMES})")
    worst = max(max_diff(attr.Get(f), expected_points(f))
                for f in (1, 7, 13, 48))
    check(worst < 1e-5, f"points conformes (écart max {worst:.2e})")

# 3. Import dans Blender ------------------------------------------------------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
bpy.ops.wm.usd_import(filepath=os.path.join(HERE, "shot.usda"))
meshes = [o for o in scene.objects if o.type == 'MESH']
if check(len(meshes) == 1, f"import USD : {len(meshes)} maillage(s)"):
    obj = meshes[0]
    mods = [m.type for m in obj.modifiers]
    print(f"      objet '{obj.name}', modificateurs {mods}, "
          f"plage {scene.frame_start}-{scene.frame_end}")

    def evaluated_points(frame):
        scene.frame_set(frame)
        ev = obj.evaluated_get(bpy.context.evaluated_depsgraph_get())
        return [tuple(obj.matrix_world @ v.co) for v in ev.data.vertices]

    def top(points):
        return max(p[2] for p in points)

    p1, p7 = evaluated_points(1), evaluated_points(7)
    check(len(p1) == 8, f"{len(p1)} sommets évalués")
    check(abs(top(p7) - top(expected_points(7))) < 1e-4
          and abs(top(p1) - top(expected_points(1))) < 1e-4,
          f"animation lue par Blender (haut : {top(p1):.4f} -> {top(p7):.4f})")

# 4. Rendu Cycles -------------------------------------------------------------
    scene.frame_set(7)
    cam_data = bpy.data.cameras.new("Cam")
    cam = bpy.data.objects.new("Cam", cam_data)
    scene.collection.objects.link(cam)
    cam.location = (6.0, -7.0, 4.0)
    cam.rotation_euler = (Vector((0.3, 0.0, 1.2)) - cam.location) \
        .to_track_quat('-Z', 'Y').to_euler()
    scene.camera = cam
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN'))
    sun.rotation_euler = (0.6, 0.2, 0.8)
    scene.collection.objects.link(sun)

    scene.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = 'OPTIX'
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = d.type == 'OPTIX'
        scene.cycles.device = 'GPU'
    except TypeError:
        scene.cycles.device = 'CPU'
    scene.cycles.samples = 32
    scene.render.resolution_x, scene.render.resolution_y = 480, 270
    scene.render.filepath = os.path.join(args.out, "hello_f007.png")
    bpy.ops.render.render(write_still=True)

    img = bpy.data.images.load(scene.render.filepath)
    px = list(img.pixels)
    lum = [px[i] + px[i + 1] + px[i + 2] for i in range(0, len(px), 4)]
    check(os.path.getsize(scene.render.filepath) > 0
          and max(lum) - min(lum) > 0.1,
          f"rendu Cycles ({scene.cycles.device}) -> {scene.render.filepath}")

print(f"\nRESULTAT : {'ECHEC' if failures else 'OK'} "
      f"({len(failures)} échec(s))")
if failures:
    raise RuntimeError("; ".join(failures))
