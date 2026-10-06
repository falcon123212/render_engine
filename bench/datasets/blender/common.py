"""Utilitaires partagés par les scripts de génération (Python de Blender 5.0)."""
import argparse
import json
import math
import sys
import time
from pathlib import Path

import bpy

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT / "data"


def parse_args(configure):
    """Analyse les arguments placés après « -- » sur la ligne de commande Blender."""
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--save-blend", action="store_true",
                        help="enregistre la scène à côté de la sortie")
    configure(parser)
    return parser.parse_args(argv)


def reset_scene(frames, fps):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = 1, frames
    scene.render.fps = fps
    scene.unit_settings.system = 'METRIC'
    return scene


def link(obj, scene=None):
    (scene or bpy.context.scene).collection.objects.link(obj)
    return obj


def add_effector(kind, name, location, rotation=(0.0, 0.0, 0.0)):
    """Champ de force (WIND, TURBULENCE...) : obj.field n'existe qu'ainsi."""
    bpy.ops.object.effector_add(type=kind, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    return obj


def grid_mesh(name, nx, ny, size_x, size_y):
    """Grille de nx * ny sommets dans le plan XY, centrée, faces en quads."""
    verts = [((i / (nx - 1) - 0.5) * size_x, (j / (ny - 1) - 0.5) * size_y, 0.0)
             for j in range(ny) for i in range(nx)]
    faces = [(j * nx + i, j * nx + i + 1, (j + 1) * nx + i + 1, (j + 1) * nx + i)
             for j in range(ny - 1) for i in range(nx - 1)]
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    return mesh


def call_op(op, **kwargs):
    """Appelle un opérateur en ignorant les options absentes de cette version."""
    names = set(op.get_rna_type().properties.keys())
    dropped = sorted(k for k in kwargs if k not in names)
    if dropped:
        print(f"  (options ignorées : {', '.join(dropped)})")
    return op(**{k: v for k, v in kwargs.items() if k in names})


def export_alembic(path, objects, frames):
    """Alembic « topologie + positions » : ni UV, ni normales, ni attributs."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action='DESELECT')
    for o in objects:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    t0 = time.time()
    call_op(bpy.ops.wm.alembic_export,
            filepath=str(path), start=1, end=frames, selected=True,
            visible_objects_only=False, flatten=True,
            uvs=False, normals=False, vcolors=False, orcos=False,
            # apply_subdiv : sinon la subdivision en fin de pile n'est pas exportée.
            face_sets=False, subdiv_schema=False, apply_subdiv=True,
            curves_as_mesh=False, use_instancing=False, triangulate=False,
            export_hair=False, export_particles=False,
            export_custom_properties=False, evaluation_mode='RENDER')
    print(f"  Alembic : {path.name}, {path.stat().st_size / 1e6:.1f} Mo "
          f"en {time.time() - t0:.1f} s")


def evaluated_stats(objects, frame):
    """Sommets, faces et boîte englobante évalués à une image donnée."""
    scene = bpy.context.scene
    scene.frame_set(frame)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    verts = faces = 0
    lo, hi = [math.inf] * 3, [-math.inf] * 3
    for o in objects:
        ev = o.evaluated_get(depsgraph)
        m = ev.to_mesh()
        verts += len(m.vertices)
        faces += len(m.polygons)
        for v in m.vertices:
            w = o.matrix_world @ v.co
            for a in range(3):
                lo[a] = min(lo[a], w[a])
                hi[a] = max(hi[a], w[a])
        ev.to_mesh_clear()
    return verts, faces, lo, hi


def world_points(objects, depsgraph):
    import numpy as np
    chunks = []
    for o in objects:
        ev = o.evaluated_get(depsgraph)
        m = ev.to_mesh()
        co = np.empty(len(m.vertices) * 3, dtype=np.float64)
        m.vertices.foreach_get("co", co)
        ev.to_mesh_clear()
        co = co.reshape(-1, 3)
        mw = np.array(o.matrix_world)
        chunks.append(co @ mw[:3, :3].T + mw[:3, 3])
    return np.concatenate(chunks)


def motion_stats(objects, frames):
    """Mouvement et difficulté de prédiction, en fraction de la diagonale.

    speed    : |x(t) - x(t-1)|
    residual : |x(t) - (2 x(t-1) - x(t-2))|, résidu de l'extrapolation linéaire
               que le codec stocke. C'est l'indicateur de difficulté du jeu.
    Calcul en flux (deux images en mémoire) : tient pour la foule.
    """
    import numpy as np
    scene = bpy.context.scene
    prev2 = prev = None
    lo, hi = np.full(3, np.inf), np.full(3, -np.inf)
    sums = {"speed": 0.0, "residual": 0.0, "residual_sq": 0.0}
    maxima = {"speed": 0.0, "residual": 0.0}
    n_speed = n_res = 0
    for f in range(1, frames + 1):
        scene.frame_set(f)
        x = world_points(objects, bpy.context.evaluated_depsgraph_get())
        lo, hi = np.minimum(lo, x.min(0)), np.maximum(hi, x.max(0))
        if prev is not None:
            v = np.linalg.norm(x - prev, axis=1)
            sums["speed"] += v.sum()
            maxima["speed"] = max(maxima["speed"], float(v.max()))
            n_speed += len(v)
        if prev2 is not None:
            r = np.linalg.norm(x - 2.0 * prev + prev2, axis=1)
            sums["residual"] += r.sum()
            sums["residual_sq"] += float((r * r).sum())
            maxima["residual"] = max(maxima["residual"], float(r.max()))
            n_res += len(r)
        prev2, prev = prev, x
    diag = float(np.linalg.norm(hi - lo))
    return {
        "bbox_min": lo.tolist(), "bbox_max": hi.tolist(), "bbox_diagonal": diag,
        "speed_mean_rel": sums["speed"] / max(n_speed, 1) / diag,
        "speed_max_rel": maxima["speed"] / diag,
        "linear_residual_mean_rel": sums["residual"] / max(n_res, 1) / diag,
        "linear_residual_rms_rel": (sums["residual_sq"] / max(n_res, 1)) ** 0.5 / diag,
        "linear_residual_max_rel": maxima["residual"] / diag,
    }


def print_motion(stats):
    print(f"  diagonale {stats['bbox_diagonal']:.3f} | vitesse moy {stats['speed_mean_rel']:.2e}"
          f" max {stats['speed_max_rel']:.2e} | résidu linéaire moy "
          f"{stats['linear_residual_mean_rel']:.2e} rms {stats['linear_residual_rms_rel']:.2e}"
          f" max {stats['linear_residual_max_rel']:.2e} (fractions de la diagonale)")


def write_manifest(path, **info):
    path = Path(path)
    info["blender"] = bpy.app.version_string
    path.write_text(json.dumps(info, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"  manifeste : {path.name}")


class Timer:
    def __init__(self, label):
        self.label = label

    def __enter__(self):
        self.t0 = time.time()
        print(f"[{self.label}] ...", flush=True)
        return self

    def __exit__(self, *exc):
        self.seconds = time.time() - self.t0
        print(f"[{self.label}] {self.seconds:.1f} s", flush=True)
