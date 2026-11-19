"""Look-pass preview: the crashed drone with the desert rock kit around it, one render (not part of the game)."""
import os
import sys
import math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
from mathutils import Vector, Euler
import cog_drone_wreck as D
import env_desert as E

a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
out = a[a.index("--out") + 1] if "--out" in a else os.path.join(HERE, "_out")
shot = a[a.index("--shot") + 1] if "--shot" in a else "wide"
os.makedirs(out, exist_ok=True)

k = D.build()
k.report()
objs, _ = E.build(list(E.ROCKS), fresh=False)


def put(key, x, y, rotz=0.0, s=1.0):
    ob = objs[key][0]
    ob.location = (x, y, -0.15 * s)
    ob.rotation_euler = (0, 0, rotz)
    ob.scale = (s, s, s)


# drone in the middle, cliffs and a butte behind, boulders and pebbles around
put("desert_cliff", 6, 48, 0.08, 1.0)
put("desert_butte", -34, 30, 0.6, 1.3)
put("desert_boulder_a", -20, 4, 0.9, 1.0)
put("desert_boulder_b", 24, -6, 2.1, 1.0)
put("desert_pebbles", -10, -16, 0.4, 1.0)
bpy.context.view_layer.update()

sc = bpy.context.scene
col = bpy.data.collections.new("_stage")
sc.collection.children.link(col)
import bmesh
me = bpy.data.meshes.new("_ground")
bm = bmesh.new()
bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=800)
bm.to_mesh(me)
bm.free()
gnd = bpy.data.objects.new("_ground", me)
gm = bpy.data.materials.new("_ground")
gm.use_nodes = True
gb = gm.node_tree.nodes.get("Principled BSDF")
gb.inputs["Base Color"].default_value = (*(E._lin(c) for c in (0xC9, 0xA6, 0x7C)), 1)
gb.inputs["Roughness"].default_value = 1.0
me.materials.append(gm)
col.objects.link(gnd)
for name, rot, energy, ang, colr in (("_sun", (math.radians(48), 0, math.radians(-30)), 4.5, 2.0, (1.0, 0.94, 0.84)),
                                     ("_fill", (math.radians(70), 0, math.radians(150)), 1.0, 25.0, (0.75, 0.82, 1.0))):
    ld = bpy.data.lights.new(name, "SUN")
    ld.energy, ld.angle, ld.color = energy, math.radians(ang), colr
    o = bpy.data.objects.new(name, ld)
    o.rotation_euler = rot
    col.objects.link(o)
world = sc.world or bpy.data.worlds.new("World")
sc.world = world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
bg.inputs[0].default_value = (E._lin(0xD8), E._lin(0xBE), E._lin(0x9C), 1)
bg.inputs[1].default_value = 0.8
camd = bpy.data.cameras.new("_cam")
camd.lens = 32
cam = bpy.data.objects.new("_cam", camd)
col.objects.link(cam)
sc.camera = cam
if shot == "close":
    target, eye = Vector((0, 0, 4)), Vector((-26, -30, 12))
else:
    target, eye = Vector((0, 14, 5)), Vector((-30, -52, 22))
cam.location = eye
cam.rotation_euler = (target - eye).to_track_quat("-Z", "Y").to_euler()
camd.clip_start, camd.clip_end = 0.1, 2000
r = sc.render
r.resolution_x, r.resolution_y = 1800, 1000
r.image_settings.file_format = "PNG"
sc.view_settings.view_transform = "Standard"
for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
    try:
        r.engine = eng
        break
    except Exception:
        pass
r.filepath = os.path.join(out, f"look_{shot}.png")
bpy.ops.render.render(write_still=True)
print("RENDERED", r.filepath)
