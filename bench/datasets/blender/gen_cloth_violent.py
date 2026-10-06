"""Tissu violent : drapeau fixé à un mât, dans un vent fort et turbulent.

Pire cas pour la prédiction temporelle linéaire (plis rapides, retournements).

  blender -b --python gen_cloth_violent.py -- [--nx 320 --ny 200] [--frames 120]
          [--out data/bench/geom/cloth_violent.abc] [--no-self-collision]

Par défaut : 320 x 200 = 64 000 sommets, 120 images à 24 i/s, autocollision,
rafales de force 24000, raideurs x0,25 (réglé à 64 k sommets : le drapeau
claque, résidu linéaire moyen 1,7e-3 de la diagonale, bake ~9 min).
"""
import math
import random
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).parent))
import common  # noqa: E402


def configure(p):
    p.add_argument("--nx", type=int, default=320)
    p.add_argument("--ny", type=int, default=200)
    p.add_argument("--quality", type=int, default=10)
    p.add_argument("--wind", type=float, default=24000.0,
                   help="force moyenne du vent (rafales de 0,4x à 1,4x)")
    p.add_argument("--stiffness-scale", type=float, default=0.25,
                   help="facteur sur les raideurs (Blender : raideur par ressort,"
                        " le tissu se raidit quand la résolution augmente)")
    p.add_argument("--total-mass", type=float, default=600.0,
                   help="masse totale (Blender : masse par sommet = total / sommets,"
                        " pour un comportement indépendant de la résolution)")
    p.add_argument("--no-self-collision", action="store_true")
    p.add_argument("--out", default=str(common.DATA / "bench" / "geom" / "cloth_violent.abc"))


args = common.parse_args(configure)
scene = common.reset_scene(args.frames, args.fps)

# Drapeau 3 m x 2 m dressé verticalement (plan XZ), bord gauche fixé.
mesh = common.grid_mesh("Flag", args.nx, args.ny, 3.0, 2.0)
flag = common.link(bpy.data.objects.new("Flag", mesh))
flag.rotation_euler = (1.5708, 0.0, 0.0)
flag.location = (1.5, 0.0, 3.0)
pin = flag.vertex_groups.new(name="pin")
pin.add([j * args.nx for j in range(args.ny)], 1.0, 'REPLACE')

cloth = flag.modifiers.new("Cloth", 'CLOTH')
s = cloth.settings
s.quality = args.quality
s.mass = args.total_mass / (args.nx * args.ny)
s.air_damping = 1.0
s.tension_stiffness = s.compression_stiffness = 15.0 * args.stiffness_scale
s.shear_stiffness = 5.0 * args.stiffness_scale
s.bending_stiffness = 0.05 * args.stiffness_scale
s.vertex_group_mass = "pin"
c = cloth.collision_settings
c.collision_quality = 2
c.use_self_collision = not args.no_self_collision
c.self_distance_min = 0.004
cloth.point_cache.frame_start, cloth.point_cache.frame_end = 1, args.frames

# Vent fort selon +X, bruité, et turbulence pour les retournements.
# Vent en rafales : direction qui balaie ±40° autour de +X (composante
# normale au drapeau, sinon il pend) et force variable, clés aléatoires
# reproductibles. L'axe Z de l'émetteur est tourné vers +X.
rng = random.Random(args.seed)
wind = common.add_effector('WIND', "Wind", (-2.0, 0.0, 3.0), (0.0, math.pi / 2, 0.0))
wind.field.noise = 3.0
wind.field.seed = args.seed
wind.rotation_mode = 'ZYX'
for f in range(1, args.frames + 1, 8):
    wind.rotation_euler = (0.0, math.pi / 2, math.radians(rng.uniform(-40.0, 40.0)))
    wind.keyframe_insert("rotation_euler", frame=f)
    wind.field.strength = rng.uniform(args.wind * 0.4, args.wind * 1.4)
    wind.field.keyframe_insert("strength", frame=f)

turb = common.add_effector('TURBULENCE', "Turbulence", (1.5, 0.0, 3.0))
turb.field.strength = args.wind * 0.3
turb.field.size = 0.6
turb.field.flow = 1.0
turb.field.seed = args.seed + 1

with common.Timer("simulation tissu") as sim:
    bpy.ops.ptcache.bake_all(bake=True)

verts, faces, _, _ = common.evaluated_stats([flag], 1)
motion = common.motion_stats([flag], args.frames)
print(f"  {verts} sommets, {faces} faces")
common.print_motion(motion)
common.export_alembic(args.out, [flag], args.frames)
common.write_manifest(Path(args.out).with_suffix(".json"),
                      dataset="cloth_violent", frames=args.frames, fps=args.fps,
                      vertices=verts, faces=faces,
                      self_collision=not args.no_self_collision,
                      quality=args.quality, bake_seconds=round(sim.seconds, 1),
                      motion=motion)
if args.save_blend:
    bpy.ops.wm.save_as_mainfile(filepath=str(Path(args.out).with_suffix(".blend")))
