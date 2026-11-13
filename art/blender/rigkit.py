"""Articulated-enemy helpers on top of kit.py (rig version 2).

One *limb* = one Blender object = one Roblox MeshPart, origin at its pivot joint.
A limb may use several colours: every face is UV-mapped to the centre of a flat swatch in a tiny
per-faction palette texture (art/textures/<faction>_palette.png) and the limb uses ONE material (the
palette). Glow / weak-spot limbs stay single-colour (Neon) with no texture.

Geometry code is unchanged: colour "proxies" (`plates`, `dark`, ...) forward .box/.cyl/.ball/.hull/
.gear/.tube/.rivets to whichever limb is current (`rig.use("Leg_L_Upper")`).

Conventions: Blender Z up, facing -Y, feet at z=0. Roblox = (-x, z, y) (Y up, -Z forward, character
right = +X). Pivots in the manifest are in Roblox studs relative to the model origin (feet).
"""
import json
import math
import os
import struct
import zlib

import bpy
from mathutils import Matrix, Vector

import kit
from kit import Part

TEXTURES = os.path.normpath(os.path.join(kit.ROOT, "..", "textures"))
GRID, CELL = 4, 16   # 64x64 px image = 4x4 swatches of 16 px (survive mip-mapping down to 4x4)

# faction -> ordered [(name, rgb key used in the scripts, rgb baked into the swatch)]
PALETTES = {
    "cog": [
        ("GUNMETAL", (74, 85, 104), (96, 110, 132)),   # baked lighter: game lightens it so robots read in dim light
        ("DARK", (30, 34, 42), (30, 34, 42)),
        ("RUST", (217, 100, 43), (217, 100, 43)),
        ("YELLOW", (240, 190, 40), (240, 190, 40)),
    ],
    "brood": [
        ("CARAPACE", (88, 52, 120), (88, 52, 120)),
        ("CARAPACE_DK", (62, 36, 92), (62, 36, 92)),
        ("CARAPACE_LT", (112, 70, 150), (112, 70, 150)),
        ("LILAC", (170, 130, 200), (170, 130, 200)),
        ("BONE", (235, 220, 190), (235, 220, 190)),
        ("DARK_BROOD", (34, 20, 48), (34, 20, 48)),
    ],
}


def _png(path, w, h, rows):
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def cell_rc(i):
    return i // GRID, i % GRID   # (row from top of the PNG, col)


def cell_uv(i):
    """UV (Blender: origin bottom-left) of the centre of swatch i."""
    r, c = cell_rc(i)
    return ((c + 0.5) / GRID, 1.0 - (r + 0.5) / GRID)


def write_palette(faction):
    os.makedirs(TEXTURES, exist_ok=True)
    path = os.path.join(TEXTURES, faction + "_palette.png")
    size = GRID * CELL
    cols = {i: e[2] for i, e in enumerate(PALETTES[faction])}
    rows = []
    for y in range(size):
        r = y // CELL
        row = []
        for x in range(size):
            c = x // CELL
            row += list(cols.get(r * GRID + c, (128, 128, 128)))
        rows.append(row)
    _png(path, size, size, rows)
    return path


class Proxy:
    """Stands for one colour; forwards modelling calls to the rig's current limb."""

    def __init__(self, rig, name, rgb, kind, rough, fixed=None):
        self.rig, self.name, self.rgb, self.kind, self.rough, self.fixed = rig, name, rgb, kind, rough, fixed

    def _part(self):
        limb = self.fixed or self.rig.cur
        assert limb is not None, "rig.use(<limb>) first"
        return limb.part_for(self)

    def __getattr__(self, attr):
        if attr in ("box", "cyl", "ball", "hull", "gear", "tube", "rivets"):
            fn = getattr(self._part(), attr)

            def call(*a, **k):
                fn(*a, **k)
                return self
            return call
        raise AttributeError(attr)


class Limb:
    def __init__(self, name, role, parent, pivot, solid=False):
        self.name, self.role, self.parent, self.pivot, self.solid = name, role, parent, pivot, solid
        self.parts = {}     # (rgb, kind, rough) -> kit.Part
        self.obj = None
        self.rest = None
        self.material = None
        self.rgb = None

    def part_for(self, px):
        key = (px.rgb, px.kind, px.rough)
        if key not in self.parts:
            self.parts[key] = Part("_t_%s_%d" % (self.name, len(self.parts)), px.rgb, px.kind, self.role, px.rough)
            self.parts[key].proxy_name = px.name
        return self.parts[key]


class Rig:
    def __init__(self, name, faction, S=1.0):
        self.name, self.faction, self.S = name, faction, S
        self.limbs = {}
        self.cur = None
        self.pal_mat = None
        self.palette_path = write_palette(faction)
        self.index = {e[1]: i for i, e in enumerate(PALETTES[faction])}

    # -- declaration -------------------------------------------------------------------
    def colour(self, name, rgb, kind="SmoothPlastic", rough=None):
        assert rgb in self.index, "colour %s not in the %s palette" % (rgb, self.faction)
        return Proxy(self, name, rgb, kind, rough)

    def limb(self, name, role="limb", parent=None, pivot=None):
        """Declare (and make current) a textured, multi-colour limb. pivot in Blender coords (pre-scale)."""
        assert name not in self.limbs, name
        L = Limb(name, role, parent, None if pivot is None else Vector(pivot))
        self.limbs[name] = L
        self.cur = L
        return L

    def solid(self, name, rgb, kind="Neon", role="weak", parent="Body", pivot=None, rough=None):
        """Single-colour glow / weak-spot limb. Returns its proxy (always routes to this limb)."""
        L = Limb(name, role, parent, None if pivot is None else Vector(pivot), solid=True)
        L.rgb = rgb
        self.limbs[name] = L
        return Proxy(self, name, rgb, kind, rough, fixed=L)

    def use(self, name):
        self.cur = self.limbs[name]
        return self.cur

    # -- build -----------------------------------------------------------------------------
    def _palette_material(self):
        img = bpy.data.images.load(self.palette_path)
        img.colorspace_settings.name = "sRGB"
        m = bpy.data.materials.new("M_%s_palette" % self.faction)
        m.use_nodes = True
        nt = m.node_tree
        b = nt.nodes["Principled BSDF"]
        tx = nt.nodes.new("ShaderNodeTexImage")
        tx.image = img
        tx.interpolation = "Closest"
        nt.links.new(tx.outputs["Color"], b.inputs["Base Color"])
        b.inputs["Roughness"].default_value = 0.42 if self.faction == "cog" else 0.28
        b.inputs["Metallic"].default_value = 0.0
        return m

    def build(self, ox=0.0, oy=0.0):
        self.pal_mat = self._palette_material()
        S = self.S
        Sv = (S, S, S) if not isinstance(S, (tuple, list)) else tuple(S)
        M = Matrix.Diagonal((Sv[0], Sv[1], Sv[2], 1.0))
        for L in self.limbs.values():
            if not L.parts:
                raise RuntimeError("limb %s has no geometry" % L.name)
            objs, mats = [], {}
            for key, p in L.parts.items():
                ob = p.build()
                me = ob.data
                if not L.solid:
                    uv = me.uv_layers.new(name="UVMap")
                    u, v = cell_uv(self.index[p.rgb])
                    uv.data.foreach_set("uv", [u, v] * len(me.loops))
                    me.materials.clear()
                    me.materials.append(self.pal_mat)
                objs.append(ob)
                mats[p.kind] = mats.get(p.kind, 0) + len(me.polygons)
            if len(objs) > 1:
                with bpy.context.temp_override(active_object=objs[0], selected_editable_objects=objs, selected_objects=objs):
                    bpy.ops.object.join()
            ob = objs[0]
            ob.name = L.name
            ob.data.name = L.name
            L.material = max(mats, key=mats.get)
            if L.solid:
                me0 = ob.data
                me0.materials[0].name = "M_%s_%d_%d_%d" % ((L.name,) + tuple(L.rgb))
            me = ob.data
            me.transform(M)
            pv = L.pivot * 1.0 if L.pivot is not None else None
            if pv is None:
                lo, hi = _bounds(me)
                pv = (lo + hi) / 2
            else:
                pv = Vector((pv.x * Sv[0], pv.y * Sv[1], pv.z * Sv[2]))
            me.transform(Matrix.Translation(-pv))
            ob.location = pv + Vector((ox, oy, 0))
            L.pivot_final = pv
            L.obj = ob
            L.rest = ob.location.copy()
        bpy.context.view_layer.update()
        return self

    # -- posing (render only) --------------------------------------------------------------
    def pose(self, angles):
        """angles: {limb: (rx, ry, rz) degrees}. Children follow their parent's rotation."""
        bpy.context.view_layer.update()
        for L in self.limbs.values():
            if L.parent and L.parent in self.limbs:
                p = self.limbs[L.parent].obj
                L.obj.parent = p
                L.obj.matrix_parent_inverse = p.matrix_world.inverted()
        for n, a in angles.items():
            self.limbs[n].obj.rotation_euler = [math.radians(v) for v in a]
        bpy.context.view_layer.update()

    def unpose(self):
        for L in self.limbs.values():
            L.obj.rotation_euler = (0, 0, 0)
            L.obj.parent = None
            L.obj.matrix_parent_inverse = Matrix.Identity(4)
            L.obj.location = L.rest
        bpy.context.view_layer.update()

    # -- reporting ---------------------------------------------------------------------------
    def tris(self):
        return kit.tri_counts()

    def bounds(self):
        lo = Vector((1e9,) * 3)
        hi = Vector((-1e9,) * 3)
        for L in self.limbs.values():
            for v in L.obj.data.vertices:
                w = L.obj.matrix_world @ v.co
                for i in range(3):
                    lo[i] = min(lo[i], w[i])
                    hi[i] = max(hi[i], w[i])
        return lo, hi

    def check_budget(self, per_obj=4000, total=10000):
        t = self.tris()
        bad = {k: v for k, v in t.items() if v > per_obj}
        tot = sum(t.values())
        print("TRIS", t, "TOTAL", tot)
        if bad:
            print("OVER_OBJECT_BUDGET", bad)
        if tot > total:
            print("OVER_TOTAL_BUDGET", tot, ">", total)
        return t

    def write_manifest(self, total_budget=10000):
        path = os.path.join(kit.EXPORTS, "manifest.json")
        data = json.load(open(path)) if os.path.exists(path) else {}
        old = data.get(self.name, {})
        lo, hi = self.bounds()
        t = self.tris()
        rob = lambda v: [round(-v.x, 3), round(v.z, 3), round(v.y, 3)]   # Blender -> Roblox (Y up, -Z fwd)
        parts = []
        for L in self.limbs.values():
            e = {"name": L.name, "role": L.role, "parent": L.parent, "pivot": rob(L.rest),
                 "material": L.material if not L.solid else next(iter(L.parts.values())).kind,
                 "textured": not L.solid, "triangles": t.get(L.name, 0)}
            if L.solid:
                e["rgb"] = list(L.rgb)
            parts.append(e)
        entry = {
            "rigVersion": 2,
            "fbx": "fbx/%s_rig.fbx" % self.name,
            "texture": "textures/%s_palette.png" % self.faction,
            "size_studs_roblox_xyz": [round(hi.x - lo.x, 2), round(hi.z - lo.z, 2), round(hi.y - lo.y, 2)],
            "bbox_center_roblox": rob((lo + hi) / 2),
            "weak_spots": [L.name for L in self.limbs.values() if L.role == "weak"],
            "triangles_total": sum(t.values()),
            "palette": [{"index": i, "name": e[0], "rgb": list(e[2]), "uv": [round(c, 4) for c in cell_uv(i)]}
                        for i, e in enumerate(PALETTES[self.faction])],
            "parts": parts,
        }
        if "assetId" in old:
            entry["assetId"] = old["assetId"]
        if "legacyParts" in old:
            entry["legacyParts"] = old["legacyParts"]
        elif "parts" in old and old.get("rigVersion") != 2:
            entry["legacyParts"] = old["parts"]
        data[self.name] = entry
        with open(path, "w") as f:
            json.dump(data, f, indent=2)
        print("MANIFEST", self.name, "SIZE", entry["size_studs_roblox_xyz"], "TOTAL", entry["triangles_total"])

    def export(self):
        out = os.path.join(kit.EXPORTS, self.name + "_rig.fbx")
        bpy.ops.object.select_all(action="DESELECT")
        for L in self.limbs.values():
            L.obj.select_set(True)
        bpy.ops.export_scene.fbx(filepath=out, use_selection=True, apply_unit_scale=True, global_scale=1.0,
                                 apply_scale_options="FBX_SCALE_ALL", axis_forward="-Z", axis_up="Y",
                                 use_mesh_modifiers=True, mesh_smooth_type="EDGE", add_leaf_bones=False,
                                 path_mode="COPY", embed_textures=True)
        print("EXPORTED", out)
        return out


def _bounds(me):
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for v in me.vertices:
        for i in range(3):
            lo[i] = min(lo[i], v.co[i])
            hi[i] = max(hi[i], v.co[i])
    return lo, hi


# ---- debug view ---------------------------------------------------------------------------------
def debug_view(rig, explode=0.9, label_size=0.5):
    """Explode limbs away from Body, ghost them, and drop a labelled marker on every pivot."""
    body = rig.limbs["Body"]
    c0 = body.rest
    for L in rig.limbs.values():
        if L is body:
            continue
        off = (L.rest - c0)
        off.z = 0 if abs(off.z) < 1e-6 else off.z * 0.5
        L.obj.location = L.rest + off * explode
    for L in rig.limbs.values():
        for m in L.obj.data.materials:
            m.surface_render_method = "BLENDED"
            if m.use_nodes:
                m.node_tree.nodes["Principled BSDF"].inputs["Alpha"].default_value = 0.45
    cam = bpy.context.scene.camera
    rr = max(label_size * 0.35, 0.05)
    em = bpy.data.materials.new("_dbg")
    em.use_nodes = True
    n = em.node_tree.nodes
    n.remove(n["Principled BSDF"])
    e = n.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = (1, 0.1, 0.9, 1)
    e.inputs["Strength"].default_value = 6
    em.node_tree.links.new(e.outputs[0], n["Material Output"].inputs[0])
    tm = bpy.data.materials.new("_dbgt")
    tm.use_nodes = True
    n2 = tm.node_tree.nodes
    n2.remove(n2["Principled BSDF"])
    e2 = n2.new("ShaderNodeEmission")
    e2.inputs["Color"].default_value = (1, 1, 1, 1)
    e2.inputs["Strength"].default_value = 3
    tm.node_tree.links.new(e2.outputs[0], n2["Material Output"].inputs[0])
    for L in rig.limbs.values():
        p = L.obj.location
        bpy.ops.mesh.primitive_uv_sphere_add(radius=rr, location=p, segments=12, ring_count=8)
        s = bpy.context.object
        s.name = "_pivot_" + L.name
        s.data.materials.append(em)
        s.show_in_front = True
        bpy.ops.object.text_add(location=p + Vector((rr * 1.5, 0, rr * 1.5)))
        t = bpy.context.object
        t.name = "_lbl_" + L.name
        t.data.body = L.name
        t.data.size = label_size
        t.data.materials.append(tm)
        t.rotation_euler = cam.rotation_euler
        t.show_in_front = True


# ---- standard script tail -----------------------------------------------------------------------
def finish(rig, stage_kw, pose, debug_stage_kw=None, debug_name=None, export=True, budget=(4000, 10000)):
    """Render mid-stride preview, (optionally) exploded debug view, then un-pose, manifest and export.
    env DEBUG=1 additionally renders the exploded/labelled view (and skips manifest/export)."""
    yaw = float(os.environ.get("YAW", stage_kw.get("yaw", -35)))
    kw = dict(debug_stage_kw if (os.environ.get("DEBUG") and debug_stage_kw) else stage_kw)
    kw["yaw"] = yaw if "YAW" in os.environ or not os.environ.get("DEBUG") else kw.get("yaw", yaw)
    kit.stage(**kw)
    rig.check_budget(*budget)
    if os.environ.get("DEBUG"):
        debug_view(rig, **(debug_name or {}))
        kit.render(rig.name + "_rig_pivots")
        return
    rig.pose(pose)
    kit.render(rig.name + "_rig")
    rig.unpose()
    if os.environ.get("NOEXPORT"):
        return
    rig.write_manifest()
    rig.export()


def gait_pose(legs, groups, amp=22.0, lift=16.0, plant=0.8):
    """Alternating-group walk pose for legs radiating sideways from the body.
    legs: [(name, side)] side=+1 left (+X) / -1 right; groups: leg names that swing forward & lift (rest push back)."""
    out = {}
    for name, s in legs:
        if name in groups:
            out[name] = (0, -s * lift, -s * amp)
        else:
            out[name] = (0, 0, s * amp * plant)
    return out
