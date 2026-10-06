"""Fumée Mantaflow : panache chaud qui monte dans un domaine 4 x 4 x 6 m.

  blender -b --python gen_smoke.py -- [--res 256] [--frames 120]
          [--cache data/work/smoke_cache]

Cache OpenVDB pleine précision (float32 ; compression Zip, Blender 5.0 n'offrant
plus Blosc pour Mantaflow) avec densité, chaleur et vitesse. À normaliser ensuite avec vdbnorm (bench/datasets/convert.py smoke).
Domaine non adaptatif : grille de taille fixe, comparable d'une image à l'autre.
"""
import sys
import time
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).parent))
import common  # noqa: E402


def configure(p):
    p.add_argument("--res", type=int, default=256)
    p.add_argument("--vorticity", type=float, default=0.3)
    p.add_argument("--cache", default=str(common.DATA / "work" / "smoke_cache"))


def set_enum(owner, prop, *wanted):
    """Affecte la première valeur acceptée parmi `wanted`.

    Essai direct plutôt qu'inspection : certaines énumérations sont dynamiques
    (openvdb_data_depth ne liste que NONE hors contexte).
    """
    for w in wanted:
        try:
            setattr(owner, prop, w)
            return w
        except TypeError as err:
            last = err
    raise SystemExit(f"{prop} : aucune de {wanted} acceptée ({last})")


args = common.parse_args(configure)
scene = common.reset_scene(args.frames, args.fps)
cache = Path(args.cache)
cache.mkdir(parents=True, exist_ok=True)

bpy.ops.mesh.primitive_cube_add(size=1.0, location=(0.0, 0.0, 3.0))
domain = bpy.context.active_object
domain.name = "Domain"
domain.scale = (4.0, 4.0, 6.0)
mod = domain.modifiers.new("Fluid", 'FLUID')
mod.fluid_type = 'DOMAIN'
ds = mod.domain_settings
ds.domain_type = 'GAS'
ds.resolution_max = args.res
ds.use_adaptive_domain = False
ds.vorticity = args.vorticity
ds.use_noise = False
ds.cache_directory = str(cache)
ds.cache_frame_start, ds.cache_frame_end = 1, args.frames
set_enum(ds, "cache_type", "ALL")
set_enum(ds, "cache_data_format", "OPENVDB")
# Blender 5.0 ne propose que ZIP ou NONE ; la référence Blosc est réécrite par vdbnorm.
set_enum(ds, "openvdb_cache_compress_type", "BLOSC", "ZIP")
depth = set_enum(ds, "openvdb_data_depth", "32", "FLOAT", "FULL")

bpy.ops.mesh.primitive_uv_sphere_add(radius=0.45, location=(0.0, 0.0, 0.7))
emitter = bpy.context.active_object
emitter.name = "Emitter"
emod = emitter.modifiers.new("Fluid", 'FLUID')
emod.fluid_type = 'FLOW'
fs = emod.flow_settings
fs.flow_type = 'SMOKE'
fs.flow_behavior = 'INFLOW'
fs.flow_source = 'MESH'
fs.surface_distance = 0.2
fs.density = 1.0
fs.temperature = 2.0
fs.use_initial_velocity = True
fs.velocity_coord = (0.0, 0.0, 1.5)
emitter.hide_render = True

# Un peu de turbulence pour un panache plus riche (et une prédiction moins facile).
turb = common.add_effector('TURBULENCE', "Turbulence", (0.0, 0.0, 3.0))
turb.field.strength = 3.0
turb.field.size = 1.0
turb.field.seed = args.seed

print(f"  domaine {args.res} (axe le plus long), {args.frames} images, VDB {depth} "
      f"{ds.openvdb_cache_compress_type}")
with common.Timer("simulation fumée") as sim:
    with bpy.context.temp_override(object=domain, active_object=domain):
        bpy.ops.fluid.bake_all()

vdbs = sorted(cache.rglob("*.vdb"))
size = sum(p.stat().st_size for p in vdbs)
print(f"  cache : {len(vdbs)} fichiers VDB, {size / 1e9:.2f} Go dans {cache}")
common.write_manifest(cache / "manifest.json", dataset="smoke", frames=args.frames,
                      fps=args.fps, resolution_max=args.res, vorticity=args.vorticity,
                      vdb_files=len(vdbs), cache_bytes=size,
                      bake_seconds=round(sim.seconds, 1), cache=str(cache))
if args.save_blend:
    bpy.ops.wm.save_as_mainfile(filepath=str(cache / "smoke.blend"))
