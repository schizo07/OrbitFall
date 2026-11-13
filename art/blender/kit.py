"""Shared Blender helpers for Orbitfall models (run: blender -b --python <model>.py).

Conventions
- 1 Blender unit = 1 Roblox stud. Z up in Blender, facing -Y, feet at z=0.
- One *Part* = one Blender object = one Roblox MeshPart = one flat colour/material.
  A Part is assembled from many bevelled primitives that are merged into a single mesh.
- Built directly in bmesh (no bpy.ops needed for modelling), so it is deterministic and quick.
"""
import bpy
import bmesh
import json
import math
import os
from mathutils import Euler, Matrix, Vector

ROOT = os.path.dirname(os.path.abspath(__file__))
PREVIEWS = os.path.normpath(os.path.join(ROOT, "..", "images"))
EXPORTS = os.path.normpath(os.path.join(ROOT, "..", "fbx"))

# ---- Cogwork Legion palette (sRGB 0-255) -------------------------------------------------
GUNMETAL = (74, 85, 104)
GUNMETAL_LT = (96, 110, 132)
DARK = (30, 34, 42)
RUST = (217, 100, 43)
YELLOW = (240, 190, 40)
AMBER = (255, 150, 25)
RED_EYE = (255, 60, 40)

_ROBLOX_MATERIALS = {"SmoothPlastic", "Metal", "Neon", "DiamondPlate", "Slate", "Granite", "Concrete", "Rock", "Glass", "Basalt", "Sandstone", "Plastic", "Foil"}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def _lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name, rgb, kind="SmoothPlastic", rough=None):
    """Flat Principled material. `kind` is the Roblox material this stands in for."""
    assert kind in _ROBLOX_MATERIALS, kind
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    col = (_lin(rgb[0]), _lin(rgb[1]), _lin(rgb[2]), 1.0)
    b.inputs["Base Color"].default_value = col
    b.inputs["Roughness"].default_value = rough if rough is not None else {"SmoothPlastic": 0.5, "Metal": 0.38, "Neon": 0.5, "DiamondPlate": 0.45}.get(kind, 0.7)
    b.inputs["Metallic"].default_value = {"Metal": 0.25}.get(kind, 0.0)
    if kind == "Neon":
        b.inputs["Emission Color"].default_value = col
        b.inputs["Emission Strength"].default_value = 0.75
    m["rgb"] = list(rgb)
    m["roblox_material"] = kind
    return m


# ---- primitive builders (return a bmesh in local space) ---------------------------------
def _bevel(bm, width, segments, angle=28.0):
    if width <= 0:
        return
    lim = math.radians(angle)
    edges = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > lim]
    if edges:
        bmesh.ops.bevel(bm, geom=edges, offset=width, segments=segments, profile=0.55, affect="EDGES")


def _box(size, bevel, seg, taper):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    sx, sy, sz = size
    tx, ty = taper
    for v in bm.verts:
        k = 1.0 if v.co.z < 0 else None
        fx = 1.0 if v.co.z < 0 else tx
        fy = 1.0 if v.co.z < 0 else ty
        v.co = Vector((v.co.x * sx * fx, v.co.y * sy * fy, v.co.z * sz))
    _bevel(bm, min(bevel, min(size) * 0.45), seg)
    return bm


def _cyl(r, h, r2, verts, bevel, seg, cap_bevel_only=True):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=verts,
                          radius1=r, radius2=r if r2 is None else r2, depth=h)
    _bevel(bm, min(bevel, r * 0.5, h * 0.45), seg, angle=40.0)
    return bm


def _ball(r, scale, segs):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=max(6, segs // 2), radius=r)
    for v in bm.verts:
        v.co = Vector((v.co.x * scale[0], v.co.y * scale[1], v.co.z * scale[2]))
    return bm


def _hull(points, bevel, seg):
    bm = bmesh.new()
    for p in points:
        bm.verts.new(p)
    res = bmesh.ops.convex_hull(bm, input=list(bm.verts))
    # drop interior/unused geometry
    junk = [g for g in set(res["geom_interior"] + res["geom_unused"]) if isinstance(g, bmesh.types.BMVert)]
    junk += [g for g in res["geom_interior"] if isinstance(g, bmesh.types.BMVert) and g not in junk]
    junk = list(set(junk))
    if junk:
        bmesh.ops.delete(bm, geom=junk, context="VERTS")
    bmesh.ops.dissolve_limit(bm, angle_limit=math.radians(1.0), verts=bm.verts, edges=bm.edges)
    _bevel(bm, bevel, seg)
    return bm


def _gear(r_out, r_in, teeth, h, bevel):
    """Toothed cog, axis Z, centred."""
    bm = bmesh.new()
    pts = []
    for i in range(teeth):
        a = 2 * math.pi * i / teeth
        step = 2 * math.pi / teeth
        for frac, rad in ((0.0, r_in), (0.18, r_out), (0.5 - 0.18, r_out), (0.5, r_in)):
            ang = a + frac * step
            pts.append((math.cos(ang) * rad, math.sin(ang) * rad))
    top = [bm.verts.new((x, y, h / 2)) for x, y in pts]
    bot = [bm.verts.new((x, y, -h / 2)) for x, y in pts]
    bm.faces.new(top)
    bm.faces.new(list(reversed(bot)))
    n = len(pts)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((top[i], bot[i], bot[j], top[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    _bevel(bm, bevel, 1, angle=50.0)
    return bm


def _look_rot(a, b):
    """Rotation matrix taking local +Z to direction a->b."""
    d = (Vector(b) - Vector(a))
    return d.to_track_quat("Z", "Y").to_matrix().to_4x4(), d.length


# ---- Part ---------------------------------------------------------------------------------
class Part:
    """Accumulates primitives into one mesh/object with one material."""

    def __init__(self, name, rgb, kind="SmoothPlastic", role="body", rough=None):
        self.name, self.rgb, self.kind, self.role = name, rgb, kind, role
        self.material = mat("M_%s_%d_%d_%d_%s_%s" % (name, rgb[0], rgb[1], rgb[2], kind, rough), rgb, kind, rough)
        self.bm = bmesh.new()
        self.obj = None

    # -- merge a local-space bmesh with a transform (optionally mirrored across X)
    def _add(self, bm, loc, rot, mirror=False, pivot=None):
        if isinstance(rot, Matrix):
            rm = rot.to_4x4()
        else:
            rm = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
        m = Matrix.Translation(loc) @ rm
        for flip in ((False, True) if mirror else (False,)):
            mm = m
            if flip:
                mm = Matrix.Scale(-1, 4, (1, 0, 0)) @ m
            vmap = {}
            for v in bm.verts:
                vmap[v] = self.bm.verts.new(mm @ v.co)
            for f in bm.faces:
                try:
                    nf = self.bm.faces.new([vmap[v] for v in f.verts])
                    if flip:
                        nf.normal_flip()
                except ValueError:
                    pass
        bm.free()
        return self

    def box(self, size, loc, rot=(0, 0, 0), bevel=0.1, seg=2, taper=(1, 1), mirror=False):
        return self._add(_box(size, bevel, seg, taper), loc, rot, mirror)

    def cyl(self, r, h, loc, rot=(0, 0, 0), r2=None, verts=20, bevel=0.05, seg=2, mirror=False):
        return self._add(_cyl(r, h, r2, verts, bevel, seg), loc, rot, mirror)

    def ball(self, r, loc, scale=(1, 1, 1), segs=20, rot=(0, 0, 0), mirror=False):
        return self._add(_ball(r, scale, segs), loc, rot, mirror)

    def hull(self, points, bevel=0.06, seg=2, mirror=False):
        return self._add(_hull(points, bevel, seg), (0, 0, 0), (0, 0, 0), mirror)

    def gear(self, r_out, r_in, teeth, h, loc, rot=(0, 0, 0), bevel=0.04, mirror=False):
        return self._add(_gear(r_out, r_in, teeth, h, bevel), loc, rot, mirror)

    def tube(self, a, b, r, r2=None, verts=16, bevel=0.04, mirror=False):
        """Cylinder running from point a to point b."""
        rotm, length = _look_rot(a, b)
        bm = _cyl(r, length, r2, verts, bevel, 2)
        mid = (Vector(a) + Vector(b)) / 2
        e = rotm.to_euler("XYZ")
        return self._add(bm, mid, [math.degrees(x) for x in e], mirror)

    def rivets(self, points, r=0.1, normal=(0, -1, 0), mirror=False):
        """Little domed rivets sitting on a surface with outward `normal`."""
        n = Vector(normal).normalized()
        rotm = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
        e = [math.degrees(x) for x in rotm.to_euler("XYZ")]
        for p in points:
            bm = _cyl(r, r * 0.7, r * 0.72, 8, 0, 1)
            self._add(bm, Vector(p) + n * (r * 0.25), e, mirror)
        return self

    # -- turn into an object
    def build(self, smooth_angle=35.0):
        bm = self.bm
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        me = bpy.data.meshes.new(self.name)
        bm.to_mesh(me)
        bm.free()
        me.materials.append(self.material)
        for p in me.polygons:
            p.use_smooth = True
        me.set_sharp_from_angle(angle=math.radians(smooth_angle))
        ob = bpy.data.objects.new(self.name, me)
        bpy.context.scene.collection.objects.link(ob)
        # weighted normals: big flat faces stay flat, bevels shade smoothly
        bpy.context.view_layer.objects.active = ob
        md = ob.modifiers.new("wn", "WEIGHTED_NORMAL")
        md.keep_sharp = True
        md.weight = 50
        bpy.ops.object.modifier_apply(modifier=md.name)
        self.obj = ob
        return ob


def tri_counts():
    dg = bpy.context.evaluated_depsgraph_get()
    out = {}
    for o in bpy.data.objects:
        if o.type == "MESH" and not o.name.startswith("_"):
            m = o.evaluated_get(dg).to_mesh()
            m.calc_loop_triangles()
            out[o.name] = len(m.loop_triangles)
            o.evaluated_get(dg).to_mesh_clear()
    return out


def bbox(parts):
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for p in parts:
        for v in p.obj.data.vertices:
            for i in range(3):
                lo[i] = min(lo[i], v.co[i])
                hi[i] = max(hi[i], v.co[i])
    return lo, hi


# ---- stage / render ----------------------------------------------------------------------
def stage(target=(0, 0, 2.5), dist=12, height=3.0, yaw=-35, lens=50, size=(900, 900), floor=11, ortho=None, boost=1.0, bg_rgb=None, floor_rgb=None):
    scn = bpy.context.scene
    scn.render.engine = "BLENDER_EEVEE"
    scn.render.resolution_x, scn.render.resolution_y = size
    scn.render.film_transparent = False
    scn.view_settings.view_transform = "Standard"
    scn.eevee.taa_render_samples = 48
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes["Background"]
    bg.inputs[0].default_value = bg_rgb or (0.07, 0.085, 0.11, 1)
    bg.inputs[1].default_value = 1.0
    scn.world = world
    # display plinth (top face at z=0)
    fw, fd = (floor, floor) if not isinstance(floor, (tuple, list)) else floor
    fb = _box((fw, fd, 0.6), 0.25, 3, (1, 1))
    fm = bpy.data.meshes.new("_Floor")
    for v in fb.verts:
        v.co.z -= 0.3
    fb.to_mesh(fm)
    fb.free()
    for p in fm.polygons:
        p.use_smooth = True
    fl = bpy.data.objects.new("_Floor", fm)
    bpy.context.scene.collection.objects.link(fl)
    fm.materials.append(mat("_floor", floor_rgb or (62, 68, 80)))
    # camera
    a = math.radians(yaw)
    tg = Vector(target)
    loc = tg + Vector((math.sin(a) * dist, -math.cos(a) * dist, height))
    cd = bpy.data.cameras.new("Cam")
    cd.lens = lens
    cd.clip_end = 400
    if ortho:
        cd.type = "ORTHO"
        cd.ortho_scale = ortho
    cam = bpy.data.objects.new("_Cam", cd)
    bpy.context.scene.collection.objects.link(cam)
    cam.location = loc
    cam.rotation_euler = (tg - loc).to_track_quat("-Z", "Y").to_euler()
    scn.camera = cam

    def light(kind, off, energy, color, sz):
        ld = bpy.data.lights.new("L", kind)
        ld.energy = energy
        ld.color = color
        if kind == "AREA":
            ld.size = sz
        lo = bpy.data.objects.new("_L", ld)
        bpy.context.scene.collection.objects.link(lo)
        lo.location = tg + Vector(off)
        lo.rotation_euler = (-Vector(off)).to_track_quat("-Z", "Y").to_euler()

    s = max(1.0, dist / 12.0)
    light("AREA", (-8 * s, -9 * s, 12 * s), 2600 * s * s * boost, (1.0, 0.95, 0.88), 8 * s)   # key
    light("AREA", (11 * s, -5 * s, 5 * s), 600 * s * s * boost, (0.6, 0.75, 1.0), 7 * s)      # cool fill
    light("AREA", (3 * s, 11 * s, 8 * s), 1300 * s * s * boost, (1.0, 0.72, 0.5), 5 * s)      # warm rim


def render(name):
    os.makedirs(PREVIEWS, exist_ok=True)
    out = os.path.join(PREVIEWS, name + ".png")
    bpy.context.scene.render.filepath = out
    bpy.ops.render.render(write_still=True)
    print("RENDERED", out)
    return out


def export_fbx(name):
    os.makedirs(EXPORTS, exist_ok=True)
    out = os.path.join(EXPORTS, name + ".fbx")
    bpy.ops.object.select_all(action="DESELECT")
    for o in bpy.data.objects:
        if o.type == "MESH" and not o.name.startswith("_"):
            o.select_set(True)
    bpy.ops.export_scene.fbx(filepath=out, use_selection=True, apply_unit_scale=True, global_scale=1.0,
                             apply_scale_options="FBX_SCALE_ALL", axis_forward="-Z", axis_up="Y",
                             use_mesh_modifiers=True, mesh_smooth_type="EDGE", add_leaf_bones=False)
    print("EXPORTED", out)
    return out


def write_manifest(name, parts):
    """Merge this enemy's entry into art/fbx/manifest.json."""
    os.makedirs(EXPORTS, exist_ok=True)
    path = os.path.join(EXPORTS, "manifest.json")
    data = {}
    if os.path.exists(path):
        with open(path) as f:
            data = json.load(f)
    lo, hi = bbox(parts)
    tris = tri_counts()
    data[name] = {
        "size_studs_roblox_xyz": [round(hi.x - lo.x, 2), round(hi.z - lo.z, 2), round(hi.y - lo.y, 2)],
        "weak_spots": [p.name for p in parts if p.role == "weak"],
        "triangles_total": sum(tris.values()),
        "parts": [{"name": p.name, "rgb": list(p.rgb), "material": p.kind, "role": p.role,
                   "triangles": tris.get(p.name, 0)} for p in parts],
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print("TRIS", tris, "TOTAL", sum(tris.values()), "SIZE", data[name]["size_studs_roblox_xyz"])
