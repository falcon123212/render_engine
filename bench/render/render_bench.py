"""Rendus Cycles de comparaison (protocole ꟻLIP du banc).

  blender -b --factory-startup --python render_bench.py -- (--abc X.abc | --vdb DOSSIER)
          --camera cam.json --label orig|decoded|seedB --out DOSSIER
          [--frames 1 11 21 ...] [--count 12] [--seed 1] [--samples 256]
          [--res 3840 2160] [--fps 24]

- Caméra figée : lue depuis --camera ; créée si le fichier n'existe pas
  (cadrage sur l'union des boîtes englobantes de toutes les images), puis
  réutilisée telle quelle pour les rendus décodés.
- Mêmes réglages pour tous : OptiX, échantillonnage fixe (non adaptatif),
  pas de débruitage, graine --seed (seedB : rendu de l'original avec une
  autre graine, pour mesurer le plancher de bruit).
- Géométrie : ombrage lissé (Set Shade Smooth), matériau gris neutre.
- Volumes : séquence VDB, Principled Volume (density, temperature).
- Sortie : PNG 8 bits (vue AgX) <out>/<label>/<NNNN>.png + timings.json.
"""
import json
import math
import sys
import time
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "datasets" / "blender"))
import common  # noqa: E402


def configure(p):
    p.add_argument("--abc")
    p.add_argument("--vdb")
    p.add_argument("--camera", required=True)
    p.add_argument("--label", default="orig")
    p.add_argument("--out", required=True)
    p.add_argument("--count", type=int, default=12)
    p.add_argument("--at", type=int, nargs="+", help="images à rendre (sinon --count réparties)")
    p.add_argument("--samples", type=int, default=256)
    p.add_argument("--res", type=int, nargs=2, default=[3840, 2160])
    p.add_argument("--max-frames", type=int, help="limite pour les tests")


def smooth_modifier(obj):
    ng = bpy.data.node_groups.get("RDC_Smooth")
    if ng is None:
        ng = bpy.data.node_groups.new("RDC_Smooth", 'GeometryNodeTree')
        ng.interface.new_socket("Geometry", in_out='INPUT', socket_type='NodeSocketGeometry')
        ng.interface.new_socket("Geometry", in_out='OUTPUT', socket_type='NodeSocketGeometry')
        gi = ng.nodes.new('NodeGroupInput')
        go = ng.nodes.new('NodeGroupOutput')
        sm = ng.nodes.new('GeometryNodeSetShadeSmooth')
        ng.links.new(gi.outputs[0], sm.inputs["Geometry"])
        ng.links.new(sm.outputs[0], go.inputs[0])
    obj.modifiers.new("Smooth", 'NODES').node_group = ng


def grey_material():
    mat = bpy.data.materials.new("RDC_Grey")
    mat.use_nodes = True
    bsdf = next(n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    bsdf.inputs["Base Color"].default_value = (0.6, 0.6, 0.6, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.45
    return mat


def volume_material():
    mat = bpy.data.materials.new("RDC_Volume")
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        if n.type != 'OUTPUT_MATERIAL':
            nt.nodes.remove(n)
    out = next(n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL')
    vol = nt.nodes.new('ShaderNodeVolumePrincipled')
    vol.inputs["Density"].default_value = 4.0
    nt.links.new(vol.outputs[0], out.inputs["Volume"])
    return mat


def load_geometry(path, fps):
    scene = bpy.context.scene
    scene.render.fps, scene.render.fps_base = fps, 1.0
    bpy.ops.wm.alembic_import(filepath=str(path), set_frame_range=True)
    scene.frame_start = 1
    objs = [o for o in scene.objects if o.type == 'MESH']
    mat = grey_material()
    for o in objs:
        smooth_modifier(o)
        o.data.materials.clear()
        o.data.materials.append(mat)
    return objs, scene.frame_end


def load_volume(folder):
    files = sorted(Path(folder).glob("*.vdb"))
    vol = bpy.data.volumes.new("Volume")
    vol.filepath = str(files[0])
    vol.is_sequence = len(files) > 1
    if vol.is_sequence:
        vol.frame_start, vol.frame_duration = 1, len(files)
    obj = common.link(bpy.data.objects.new("Volume", vol))
    vol.materials.append(volume_material())
    bpy.context.scene.frame_end = len(files)
    return [obj], len(files)


def bbox_all_frames(objs, frames):
    scene = bpy.context.scene
    lo, hi = Vector((math.inf,) * 3), Vector((-math.inf,) * 3)
    for f in frames:
        scene.frame_set(f)
        for o in objs:
            ev = o.evaluated_get(bpy.context.evaluated_depsgraph_get())
            for c in ev.bound_box:
                w = o.matrix_world @ Vector(c)
                lo = Vector(map(min, lo, w))
                hi = Vector(map(max, hi, w))
    return lo, hi


def make_camera(cam_path, objs, all_frames, res):
    scene = bpy.context.scene
    cam = common.link(bpy.data.objects.new("BenchCam", bpy.data.cameras.new("BenchCam")))
    cam.data.sensor_fit = 'HORIZONTAL'
    if cam_path.exists():
        spec = json.loads(cam_path.read_text(encoding="utf-8"))
    else:
        lo, hi = bbox_all_frames(objs, all_frames)
        center, radius = (lo + hi) / 2, (hi - lo).length / 2
        lens = 50.0
        # Distance pour que la sphère englobante tienne en hauteur (16:9).
        fov_v = 2 * math.atan(36.0 * res[1] / res[0] / 2 / lens)
        dist = radius / math.sin(fov_v / 2) * 1.05
        loc = center + Vector((0.9, -2.2, 0.9)).normalized() * dist
        rot = (center - loc).to_track_quat('-Z', 'Y').to_euler()
        spec = {"location": list(loc), "rotation_euler": list(rot), "lens": lens,
                "sensor_width": 36.0, "resolution": list(res),
                "bbox_min": list(lo), "bbox_max": list(hi)}
        cam_path.parent.mkdir(parents=True, exist_ok=True)
        cam_path.write_text(json.dumps(spec, indent=2), encoding="utf-8")
        print(f"  caméra créée : {cam_path}")
    cam.location, cam.rotation_euler = spec["location"], spec["rotation_euler"]
    cam.data.lens, cam.data.sensor_width = spec["lens"], spec["sensor_width"]
    scene.camera = cam
    return spec


def setup_render(args):
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = 'OPTIX'
    prefs.refresh_devices()
    for d in prefs.devices:
        d.use = d.type == 'OPTIX'
    scene.cycles.device = 'GPU'
    scene.cycles.samples = args.samples
    scene.cycles.use_adaptive_sampling = False
    scene.cycles.use_denoising = False
    scene.cycles.seed = args.seed + (1000 if args.label == "seedB" else 0)
    scene.render.resolution_x, scene.render.resolution_y = args.res
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.render.image_settings.color_depth = '8'
    try:
        scene.view_settings.view_transform = 'AgX'
    except TypeError:
        pass
    world = bpy.data.worlds.new("World")
    scene.world = world
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == 'BACKGROUND')
    bg.inputs["Strength"].default_value = 0.4
    sun = common.link(bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", 'SUN')))
    sun.data.energy = 3.0
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(35))


args = common.parse_args(configure)
if bool(args.abc) == bool(args.vdb):
    sys.exit("--abc ou --vdb (un seul)")
bpy.ops.wm.read_factory_settings(use_empty=True)
if args.abc:
    manifest = Path(args.abc).with_suffix(".json")
    fps = json.loads(manifest.read_text(encoding="utf-8")).get("fps", args.fps) \
        if manifest.exists() else args.fps
    objs, nframes = load_geometry(args.abc, fps)
else:
    objs, nframes = load_volume(args.vdb)
if args.max_frames:
    nframes = min(nframes, args.max_frames)

frames = args.at or sorted({1 + round(i * (nframes - 1) / max(1, args.count - 1))
                            for i in range(min(args.count, nframes))})
setup_render(args)
make_camera(Path(args.camera), objs, range(1, nframes + 1), args.res)

out = Path(args.out) / args.label
out.mkdir(parents=True, exist_ok=True)
timings = {}
scene = bpy.context.scene
for f in frames:
    scene.frame_set(f)
    scene.render.filepath = str(out / f"{f:04d}.png")
    t0 = time.time()
    bpy.ops.render.render(write_still=True)
    timings[f] = round(time.time() - t0, 2)
    print(f"  image {f} : {timings[f]} s", flush=True)
(out / "timings.json").write_text(json.dumps({"frames": frames, "seconds": timings,
                                              "seed": scene.cycles.seed,
                                              "samples": args.samples}, indent=2),
                                  encoding="utf-8")
print(f"RENDU {args.label} : {len(frames)} images, {sum(timings.values()):.0f} s")
