"""Re-export the friend's call-in / vehicle models at the correct Roblox scale.

The friend's parts_lib exports with apply_scale_options='FBX_SCALE_NONE', which
imports into Roblox 100x too big. This uses the same FBX_SETTINGS but with
'FBX_SCALE_ALL'. Geometry is not touched.

Run once per model, headless (never against a live Blender session):
  Blender -b new-art/art/blend/<file>.blend --python art/tools/export_callins.py -- \
      <key> <out_dir> <friend_manifest.json>

Selects exactly the mesh objects named as parts in the friend's manifest
(ignores cameras, lights and the preview collection) and writes <out_dir>/<key>.fbx.
"""
import json
import os
import sys

import bpy

key, out_dir, manifest_path = sys.argv[sys.argv.index("--") + 1:][:3]

FBX_SETTINGS = dict(
    axis_forward='Z', axis_up='Y', bake_space_transform=True,
    global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_ALL',
    mesh_smooth_type='FACE', use_mesh_modifiers=True, use_custom_props=True,
    path_mode='COPY', embed_textures=True, add_leaf_bones=False, bake_anim=False,
)

parts = [p["name"] for p in json.load(open(manifest_path))[key]["parts"]]
objs = {o.name: o for o in bpy.data.objects}
missing = [n for n in parts if n not in objs or objs[n].type != 'MESH']
if missing:
    raise SystemExit(f"[export_callins] {key}: manifest parts not found as meshes: {missing}")

# only the parts: hide everything else from selection, deselect all, select parts
bpy.ops.object.select_all(action='DESELECT')
for n in parts:
    objs[n].select_set(True)
bpy.context.view_layer.objects.active = objs[parts[0]]

os.makedirs(out_dir, exist_ok=True)
path = os.path.join(out_dir, f"{key}.fbx")
bpy.ops.export_scene.fbx(filepath=path, use_selection=True, object_types={'MESH'}, **FBX_SETTINGS)
print(f"[export_callins] {key}: {len(parts)} parts -> {path}")
