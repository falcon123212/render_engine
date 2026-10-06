"""Foule (et personnage héros) : agents skinnés animés, exportés en Alembic.

  Foule :  blender -b --python gen_crowd.py -- --character perso.fbx
  Héros :  blender -b --python gen_crowd.py -- --character perso.fbx --agents 1
               --target-verts 100000 --out data/bench/geom/character.abc

--character : FBX/glTF/.blend avec une armature animée (ex. Mixamo, « with skin »).
Sans --character : agent de substitution procédural (tube sur 4 os qui se
balance), pour tester la chaîne avant d'avoir le vrai personnage.

Nombre de sommets par agent ramené à --target-verts : Decimate placé AVANT
l'armature (topologie fixe) si le maillage est trop dense, Subdivision APRÈS
l'armature si trop léger. Décalage d'animation aléatoire (NLA) par agent.
"""
import math
import random
import sys
from pathlib import Path

import bpy

sys.path.insert(0, str(Path(__file__).parent))
import common  # noqa: E402


def configure(p):
    p.add_argument("--character")
    p.add_argument("--agents", type=int, default=200)
    p.add_argument("--target-verts", type=int, default=10000)
    p.add_argument("--spacing", type=float, default=1.6)
    p.add_argument("--out", default=str(common.DATA / "bench" / "geom" / "crowd.abc"))


def import_character(path):
    path = Path(path)
    before = set(bpy.data.objects)
    ext = path.suffix.lower()
    if ext == ".fbx":
        if hasattr(bpy.ops.wm, "fbx_import"):
            bpy.ops.wm.fbx_import(filepath=str(path))
        else:
            bpy.ops.import_scene.fbx(filepath=str(path))
    elif ext in (".glb", ".gltf"):
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif ext == ".blend":
        with bpy.data.libraries.load(str(path)) as (src, dst):
            dst.objects = src.objects
        for o in dst.objects:
            if o is not None:
                common.link(o)
    else:
        raise SystemExit(f"format non géré : {ext}")
    new = [o for o in bpy.data.objects if o not in before]
    arms = [o for o in new if o.type == 'ARMATURE']
    skinned = [o for o in new if o.type == 'MESH'
               and any(m.type == 'ARMATURE' for m in o.modifiers)]
    if not arms or not skinned:
        raise SystemExit("il faut une armature et au moins un maillage skinné")
    arm = arms[0]
    action = arm.animation_data.action if arm.animation_data else None
    if action is None:
        raise SystemExit("l'armature n'a pas d'action (exporter Mixamo « with skin »)")
    for o in new:  # on ne garde que l'armature et ses maillages
        if o is not arm and o not in skinned:
            bpy.data.objects.remove(o)
    if len(skinned) > 1:
        with bpy.context.temp_override(active_object=skinned[0],
                                       selected_editable_objects=skinned):
            bpy.ops.object.join()
    mesh = skinned[0]
    for m in mesh.modifiers:
        if m.type == 'ARMATURE':
            m.object = arm
    return arm, mesh, action


def standin_character(target):
    """Tube ouvert de ~target sommets (rayon 0,25 m, hauteur 1,8 m) sur 4 os."""
    seg = max(8, int(math.sqrt(target / 2)))
    rings = max(4, target // seg)
    verts = [(0.25 * math.cos(2 * math.pi * i / seg), 0.25 * math.sin(2 * math.pi * i / seg),
              1.8 * j / (rings - 1)) for j in range(rings) for i in range(seg)]
    faces = [(j * seg + i, j * seg + (i + 1) % seg, (j + 1) * seg + (i + 1) % seg,
              (j + 1) * seg + i) for j in range(rings - 1) for i in range(seg)]
    me = bpy.data.meshes.new("Agent")
    me.from_pydata(verts, [], faces)
    mesh = common.link(bpy.data.objects.new("Agent", me))

    arm = common.link(bpy.data.objects.new("Rig", bpy.data.armatures.new("Rig")))
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode='EDIT')
    bones, parent = [], None
    for b in range(4):
        eb = arm.data.edit_bones.new(f"b{b}")
        eb.head, eb.tail = (0, 0, 0.45 * b), (0, 0, 0.45 * (b + 1))
        eb.parent = parent
        eb.use_connect = parent is not None
        parent = eb
        bones.append(eb.name)
    bpy.ops.object.mode_set(mode='OBJECT')

    # Poids : interpolation linéaire entre les os voisins selon la hauteur.
    groups = [mesh.vertex_groups.new(name=n) for n in bones]
    for v in me.vertices:
        t = min(v.co.z / 0.45, 3.999) - 0.5
        b0 = max(0, min(3, math.floor(t)))
        w1 = min(1.0, max(0.0, t - b0))
        groups[b0].add([v.index], 1.0 - w1, 'REPLACE')
        if b0 + 1 < 4 and w1 > 0:
            groups[b0 + 1].add([v.index], w1, 'REPLACE')
    mesh.parent = arm
    mesh.modifiers.new("Armature", 'ARMATURE').object = arm

    # Cycle de 48 images : balancement en X et Y déphasé le long de la chaîne.
    arm.animation_data_create()
    for f in range(1, 50, 4):
        ph = 2 * math.pi * (f - 1) / 48
        for b, name in enumerate(bones):
            pb = arm.pose.bones[name]
            pb.rotation_mode = 'XYZ'
            pb.rotation_euler = (0.35 * math.sin(ph + 0.8 * b), 0.2 * math.cos(ph + 0.5 * b), 0)
            pb.keyframe_insert("rotation_euler", frame=f)
    return arm, mesh, arm.animation_data.action


def fit_vertex_count(mesh, target):
    n = len(mesh.data.vertices)
    if n > target * 1.2:
        dec = mesh.modifiers.new("Decimate", 'DECIMATE')
        dec.ratio = target / n
        mesh.modifiers.move(len(mesh.modifiers) - 1, 0)  # avant l'armature
    elif n < target / 1.5:
        sub = mesh.modifiers.new("Subdivision", 'SUBSURF')
        sub.levels = sub.render_levels = max(1, round(math.log(target / n, 4)))
    return n


args = common.parse_args(configure)
scene = common.reset_scene(args.frames, args.fps)
rng = random.Random(args.seed)

if args.character:
    arm, mesh, action = import_character(args.character)
    source = Path(args.character).name
else:
    print("  pas de --character : agent de substitution procédural")
    arm, mesh, action = standin_character(args.target_verts)
    source = "procedural-standin"
base_verts = fit_vertex_count(mesh, args.target_verts)
cycle = max(1, int(action.frame_range[1] - action.frame_range[0]))

# Agents : armature et maillage copiés (données partagées), action rejouée
# en boucle par une piste NLA décalée.
arm.animation_data.action = None
cols = math.ceil(math.sqrt(args.agents))
agents = []
for k in range(args.agents):
    a = arm if k == 0 else common.link(arm.copy())
    m = mesh if k == 0 else common.link(mesh.copy())
    if k:
        m.parent = a
        for mod in m.modifiers:
            if mod.type == 'ARMATURE':
                mod.object = a
    if args.agents > 1:
        a.location = ((k % cols - cols / 2) * args.spacing + rng.uniform(-0.3, 0.3),
                      (k // cols - cols / 2) * args.spacing + rng.uniform(-0.3, 0.3), 0.0)
        a.rotation_euler = (0.0, 0.0, rng.uniform(0, 2 * math.pi)) if a.rotation_mode == 'XYZ' \
            else a.rotation_euler
    a.animation_data_create()
    offset = rng.randrange(cycle) if args.agents > 1 else 0
    track = a.animation_data.nla_tracks.new()
    strip = track.strips.new("cycle", int(action.frame_range[0]) - offset, action)
    strip.repeat = math.ceil((args.frames + offset) / cycle) + 1
    agents.append(m)

verts, faces, _, _ = common.evaluated_stats(agents, 1)
print(f"  {args.agents} agent(s), source {source} ({base_verts} sommets d'origine), "
      f"{verts} sommets évalués au total, cycle {cycle} images")
with common.Timer("statistiques de mouvement"):
    motion = common.motion_stats(agents, args.frames)
common.print_motion(motion)
common.export_alembic(args.out, agents, args.frames)
common.write_manifest(Path(args.out).with_suffix(".json"),
                      dataset="crowd" if args.agents > 1 else "character",
                      source=source, agents=args.agents, frames=args.frames, fps=args.fps,
                      vertices=verts, faces=faces, vertices_per_agent=verts // args.agents,
                      motion=motion)
if args.save_blend:
    bpy.ops.wm.save_as_mainfile(filepath=str(Path(args.out).with_suffix(".blend")))
