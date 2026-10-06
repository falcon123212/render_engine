"""Exporte des Alembic en .usdc animé (time samples), référence « USD crate ».

  blender -b --factory-startup --python usdc_export.py -- in.abc out.usdc [fps]

Même contenu que l'Alembic de référence : topologie + positions, ni UV ni normales.
"""
import sys

import bpy

src, dst = sys.argv[sys.argv.index("--") + 1:][:2]
fps = int(sys.argv[sys.argv.index("--") + 3]) if len(sys.argv) > sys.argv.index("--") + 3 else 24
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.fps, scene.render.fps_base = fps, 1.0  # pas de rééchantillonnage
bpy.ops.wm.alembic_import(filepath=src, set_frame_range=True)
scene.frame_start = 1

op = bpy.ops.wm.usd_export
names = set(op.get_rna_type().properties.keys())
kwargs = dict(filepath=dst, selected_objects_only=False, export_animation=True,
              export_uvmaps=False, export_normals=False, export_materials=False,
              export_mesh_colors=False, export_textures=False, generate_preview_surface=False,
              export_subdivision='IGNORE', evaluation_mode='RENDER')
op(**{k: v for k, v in kwargs.items() if k in names})
print(f"usdc : {dst}")
