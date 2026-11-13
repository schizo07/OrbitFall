"""Halcyon Corps ("our side") asset helpers on top of kit.py / rigkit.py.

One palette PNG (art/textures/halcyon_palette.png, 64x64, 4x4 swatches) is shared by every Halcyon set piece,
the trooper armour kit and the weapons. Each Roblox object = one Blender object (a "limb" in rigkit terms) with
its origin at the point named in the brief; glow objects are separate, untextured, Neon.

Blender: Z up, facing -Y, 1 unit = 1 stud. Manifest pivots are Roblox (-x, z, y).
"""
import json
import math
import os
import sys

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
import rigkit

# ---- palette ---------------------------------------------------------------------------------------
WHITE = (232, 228, 218)        # off-white armour
NAVY = (44, 52, 70)            # slate navy
ORANGE = (240, 120, 40)        # safety orange
METAL = (40, 44, 52)           # dark gunmetal
WHITE_SH = (188, 184, 176)     # shaded / dirty off-white
NAVY_LT = (74, 88, 116)        # lighter slate
ORANGE_DK = (186, 84, 30)      # burnt orange
SCORCH = (26, 24, 26)          # soot / burn
STEEL = (128, 136, 150)        # bare steel
DIRT = (112, 94, 78)           # churned earth
SOOT = (146, 138, 126)         # scorched off-white
SAND = (196, 176, 138)         # canvas / cases
GLASS = (26, 58, 80)           # cockpit glass (unlit)
NAVY_DK = (26, 32, 46)         # deep navy
SLATE = (92, 100, 116)         # mid slate
ASH = (68, 66, 66)             # ash ground

# glow colours (untextured Neon objects)
CYAN = (80, 230, 220)
AMBER = (255, 150, 25)
ALIEN = (190, 110, 255)

rigkit.PALETTES["halcyon"] = [(n, c, c) for n, c in [
    ("WHITE", WHITE), ("NAVY", NAVY), ("ORANGE", ORANGE), ("METAL", METAL),
    ("WHITE_SH", WHITE_SH), ("NAVY_LT", NAVY_LT), ("ORANGE_DK", ORANGE_DK), ("SCORCH", SCORCH),
    ("STEEL", STEEL), ("DIRT", DIRT), ("SOOT", SOOT), ("SAND", SAND),
    ("GLASS", GLASS), ("NAVY_DK", NAVY_DK), ("SLATE", SLATE), ("ASH", ASH)]]

R = rigkit
EXPORTS = kit.EXPORTS


def rob(v):
    return [round(-v.x, 3), round(v.z, 3), round(v.y, 3)]


# ---- frame (rotated / translated modelling space) --------------------------------------------------
class Frame:
    """Model in a local frame (e.g. a pitched, rolled wreck). No mirroring: call twice with +-x."""

    def __init__(self, loc=(0, 0, 0), rot=(0, 0, 0)):
        e = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
        self.M = Matrix.Translation(loc) @ e
        self.Rm = self.M.to_3x3().to_4x4()

    def P(self, p):
        return tuple(self.M @ Vector(p))

    def sub(self, loc=(0, 0, 0), rot=(0, 0, 0)):
        """Child frame (e.g. a hinge) inside this one."""
        f = Frame.__new__(Frame)
        e = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
        f.M = self.M @ Matrix.Translation(loc) @ e
        f.Rm = f.M.to_3x3().to_4x4()
        return f

    def about(self, pivot, rot=(0, 0, 0), loc=(0, 0, 0)):
        """Same coordinates as this frame, but rotated about `pivot` (then shifted by loc)."""
        f = Frame.__new__(Frame)
        e = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
        f.M = self.M @ Matrix.Translation(loc) @ Matrix.Translation(pivot) @ e @ Matrix.Translation(-Vector(pivot))
        f.Rm = f.M.to_3x3().to_4x4()
        return f

    def Rot(self, rot=(0, 0, 0)):
        e = Euler([math.radians(a) for a in rot], "XYZ").to_matrix().to_4x4()
        return self.Rm @ e

    def box(self, px, size, loc, rot=(0, 0, 0), **k):
        return px.box(size, self.P(loc), self.Rot(rot), **k)

    def cyl(self, px, r, h, loc, rot=(0, 0, 0), **k):
        return px.cyl(r, h, self.P(loc), rot=self.Rot(rot), **k)

    def ball(self, px, r, loc, scale=(1, 1, 1), rot=(0, 0, 0), **k):
        return px.ball(r, self.P(loc), scale=scale, rot=self.Rot(rot), **k)

    def hull(self, px, pts, **k):
        return px.hull([self.P(p) for p in pts], **k)

    def tube(self, px, a, b, r, **k):
        return px.tube(self.P(a), self.P(b), r, **k)

    def loft(self, px, secs, **k):
        return loft(px, secs, frame=self, **k)

    def cutbox(self, px, size, loc, rot=(0, 0, 0)):
        return cut(px, size, self.P(loc), self.Rot(rot))


IDENT = Frame()


def _sg(v):
    return 1.0 if v >= 0 else -1.0


def loft(px, secs, n=20, frame=None, cap0=True, cap1=True):
    """Bridge superellipse rings along Y. secs: (y, half_w, half_h, z_centre, exponent[, x_centre]).
    exponent 2 = ellipse, 4+ = rounded box."""
    F = frame or IDENT
    part = px._part()
    bm = part.bm
    rings = []
    for s in secs:
        y, hw, hh, zc, ex = s[:5]
        xc = s[5] if len(s) > 5 else 0.0
        ring = []
        for i in range(n):
            t = 2 * math.pi * (i + 0.5) / n
            c, sn = math.cos(t), math.sin(t)
            x = xc + max(hw, 0.015) * _sg(c) * abs(c) ** (2.0 / ex)
            z = zc + max(hh, 0.015) * _sg(sn) * abs(sn) ** (2.0 / ex)
            ring.append(bm.verts.new(F.P((x, y, z))))
        rings.append(ring)
    for a, b in zip(rings[:-1], rings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap0:
        bm.faces.new(rings[0])
    if cap1:
        bm.faces.new(list(reversed(rings[-1])))
    return px


def cut(px, size, loc, rot=(0, 0, 0)):
    """Boolean-subtract a box from the (closed) mesh of this colour group."""
    part = px._part()
    bm = part.bm
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new("_cutme")
    bm.to_mesh(me)
    ob = bpy.data.objects.new("_cutob", me)
    bpy.context.scene.collection.objects.link(ob)
    cb = bmesh.new()
    bmesh.ops.create_cube(cb, size=1.0)
    cm = bpy.data.meshes.new("_cutter")
    cb.to_mesh(cm)
    cb.free()
    co = bpy.data.objects.new("_cutter", cm)
    bpy.context.scene.collection.objects.link(co)
    co.scale = size
    if isinstance(rot, Matrix):
        co.rotation_euler = rot.to_euler("XYZ")
    else:
        co.rotation_euler = [math.radians(a) for a in rot]
    co.location = loc
    md = ob.modifiers.new("b", "BOOLEAN")
    md.operation = "DIFFERENCE"
    md.object = co
    md.solver = "EXACT"
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    em = bpy.data.meshes.new_from_object(ev)
    nb = bmesh.new()
    nb.from_mesh(em)
    part.bm = nb
    bm.free()
    for o in (ob, co):
        bpy.data.objects.remove(o)
    for m in (me, cm, em):
        bpy.data.meshes.remove(m)
    return px


def ring_pts(cx, cz, rx, rz, n, y=0.0, a0=0.0):
    return [(cx + rx * math.cos(a0 + 2 * math.pi * i / n), y, cz + rz * math.sin(a0 + 2 * math.pi * i / n)) for i in range(n)]


# ---- asset -----------------------------------------------------------------------------------------
class Asset(rigkit.Rig):
    def __init__(self, key, fbx=None, kind="setpiece", S=1.0, faction="halcyon"):
        super().__init__(key, faction, S)
        self.key = key
        self.fbx_name = fbx or key
        self.kind = kind
        self.attach = {}
        self.notes = {}
        c = lambda n, rgb, k="SmoothPlastic", rough=None: self.colour(n, rgb, k, rough)
        if faction != "halcyon":
            return
        self.white = c("white", WHITE)
        self.navy = c("navy", NAVY)
        self.orange = c("orange", ORANGE)
        self.metal = c("metal", METAL)
        self.white_sh = c("white_sh", WHITE_SH)
        self.navy_lt = c("navy_lt", NAVY_LT)
        self.orange_dk = c("orange_dk", ORANGE_DK)
        self.scorch = c("scorch", SCORCH)
        self.steel = c("steel", STEEL)
        self.dirt = c("dirt", DIRT)
        self.soot = c("soot", SOOT)
        self.sand = c("sand", SAND)
        self.glass = c("glass", GLASS)
        self.navy_dk = c("navy_dk", NAVY_DK)
        self.slate = c("slate", SLATE)
        self.ash = c("ash", ASH)

    def glow(self, name, rgb=CYAN, role="glow", parent=None, pivot=None):
        return self.solid(name, rgb, "Neon", role, parent=parent, pivot=pivot)

    def _palette_material(self):
        m = super()._palette_material()
        b = m.node_tree.nodes["Principled BSDF"]
        b.inputs["Roughness"].default_value = 0.5
        return m

    def build(self, ox=0.0, oy=0.0):
        if os.environ.get("TRISDBG"):
            for L in self.limbs.values():
                print("PARTS", L.name, {getattr(p, "proxy_name", "?"): sum(len(f.verts) - 2 for f in p.bm.faces) for p in L.parts.values()})
        super().build(ox, oy)
        for L in self.limbs.values():
            if L.solid:
                for m in L.obj.data.materials:
                    if m.get("roblox_material") != "Neon":
                        continue
                    m.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 2.5
        return self

    # -- posing: rotation about the origin + translation, render only
    def pose(self, angles=None, offsets=None):
        for n, a in (angles or {}).items():
            self.limbs[n].obj.rotation_euler = [math.radians(v) for v in a]
        for n, o in (offsets or {}).items():
            self.limbs[n].obj.location = self.limbs[n].rest + Vector(o)
        bpy.context.view_layer.update()

    def unpose(self):
        for L in self.limbs.values():
            L.obj.rotation_euler = (0, 0, 0)
            L.obj.location = L.rest
        bpy.context.view_layer.update()

    def over(self, per_obj=6000, total=6000):
        t = kit.tri_counts()
        tot = sum(t.values())
        print("TRIS", t, "TOTAL", tot)
        if tot > total:
            print("OVER_BUDGET", tot, ">", total)
        return tot

    def export(self):
        out = os.path.join(EXPORTS, self.fbx_name + ".fbx")
        bpy.ops.object.select_all(action="DESELECT")
        for L in self.limbs.values():
            L.obj.select_set(True)
        bpy.ops.export_scene.fbx(filepath=out, use_selection=True, apply_unit_scale=True, global_scale=1.0,
                                 apply_scale_options="FBX_SCALE_ALL", axis_forward="-Z", axis_up="Y",
                                 use_mesh_modifiers=True, mesh_smooth_type="EDGE", add_leaf_bones=False,
                                 path_mode="COPY", embed_textures=True)
        print("EXPORTED", out)

    def write_manifest(self, key=None, **extra):
        key = key or self.key
        path = os.path.join(EXPORTS, "manifest.json")
        data = json.load(open(path)) if os.path.exists(path) else {}
        lo, hi = self.bounds()
        t = kit.tri_counts()
        parts = []
        for L in self.limbs.values():
            e = {"name": L.name, "role": L.role, "parent": L.parent, "pivot": rob(L.rest),
                 "material": L.material if not L.solid else next(iter(L.parts.values())).kind,
                 "textured": not L.solid, "triangles": t.get(L.name, 0)}
            if L.solid:
                e["rgb"] = list(L.rgb)
            if L.name in self.attach:
                e["attach"] = self.attach[L.name]
            if L.name in self.notes:
                e["note"] = self.notes[L.name]
            parts.append(e)
        entry = {
            "rigVersion": 2,
            "kind": self.kind,
            "fbx": "fbx/%s.fbx" % self.fbx_name,
            "texture": "textures/%s_palette.png" % self.faction,
            "size_studs_roblox_xyz": [round(hi.x - lo.x, 2), round(hi.z - lo.z, 2), round(hi.y - lo.y, 2)],
            "bbox_center_roblox": rob((lo + hi) / 2),
            "weak_spots": [L.name for L in self.limbs.values() if L.role == "weak"],
            "triangles_total": sum(t.values()),
            "palette": [{"index": i, "name": e[0], "rgb": list(e[2]), "uv": [round(c, 4) for c in R.cell_uv(i)]}
                        for i, e in enumerate(R.PALETTES[self.faction])],
            "parts": parts,
        }
        entry.update(extra)
        old = data.get(key, {})
        for k in ("assetId", "rigAssetId"):
            if k in old:
                entry[k] = old[k]
        data[key] = entry
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        print("MANIFEST", key, entry["size_studs_roblox_xyz"], "TOTAL", entry["triangles_total"])


def build_dummy(ox=0.0, oy=0.0, name="_dummy"):
    """Standard R15-proportioned fitting dummy (never exported). Returns dict of part centres (Blender coords)."""
    skin = (222, 178, 138)
    top = (96, 104, 120)
    cen = {}
    specs = [  # name, size(x,y,z), centre(x,y,z)
        ("Head", (1.2, 1.2, 1.2), (0, 0, 5.18)),
        ("UpperTorso", (2.0, 1.0, 1.6), (0, 0, 3.7)),
        ("LowerTorso", (2.0, 1.0, 0.4), (0, 0, 2.7)),
        ("LeftUpperArm", (1.0, 1.0, 1.17), (1.5, 0, 3.9)),
        ("LeftLowerArm", (1.0, 1.0, 1.05), (1.5, 0, 2.8)),
        ("LeftHand", (1.0, 1.0, 0.3), (1.5, 0, 2.1)),
        ("RightUpperArm", (1.0, 1.0, 1.17), (-1.5, 0, 3.9)),
        ("RightLowerArm", (1.0, 1.0, 1.05), (-1.5, 0, 2.8)),
        ("RightHand", (1.0, 1.0, 0.3), (-1.5, 0, 2.1)),
        ("LeftUpperLeg", (1.0, 1.0, 1.22), (0.5, 0, 1.9)),
        ("LeftLowerLeg", (1.0, 1.0, 1.19), (0.5, 0, 0.85)),
        ("LeftFoot", (1.0, 1.0, 0.3), (0.5, 0, 0.15)),
        ("RightUpperLeg", (1.0, 1.0, 1.22), (-0.5, 0, 1.9)),
        ("RightLowerLeg", (1.0, 1.0, 1.19), (-0.5, 0, 0.85)),
        ("RightFoot", (1.0, 1.0, 0.3), (-0.5, 0, 0.15)),
    ]
    for n, size, c in specs:
        col = skin if n in ("Head",) or "Hand" in n else (top if "Torso" in n or "Arm" in n else (70, 78, 92))
        p = kit.Part("_%s_%s" % (name, n), col)
        p.box(size, (c[0] + ox, c[1] + oy, c[2]), bevel=0.12 if n != "Head" else 0.25, seg=2)
        p.build()
        cen[n] = Vector(c)
    return cen


def show(files=None):
    pass
