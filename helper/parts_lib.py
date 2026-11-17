"""
Orbitfall - parts_lib.py  (shared kitbash library, Blender 4.x)
=================================================================

One module that every model script imports, so all factions share the same
palette atlas, bevel scale, bolt size, export settings and manifest format.
A model script then only spends code on what is unique to that model.

PIPELINE RULES BAKED IN (from the Orbitfall asset brief)
  * 1 Blender unit = 1 stud.  Z up, model faces -Y, base at z = 0, centred X/Y.
    Roblox coords = (-x, z, y)  ->  see to_roblox().
  * One Kit.part() = one Blender object = one Roblox MeshPart (name = code name).
  * Colour = 64x64 palette atlas (4x4 swatches of 16 px). Every face is UV'd to
    the centre of its swatch. One material per textured part.
  * Glow / weak-spot parts: single colour, no texture, Roblox material Neon.
  * Every material is tagged with its Roblox material (custom prop + manifest).
  * Triangle and part-count budgets are checked in Kit.report().

MODEL SCRIPT TEMPLATE
    import sys, os, importlib
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import parts_lib as pl; importlib.reload(pl)

    kit  = pl.Kit("mine", palette="human", category="small_prop")
    body = kit.part("Body", material="Metal", color="Charcoal")
    light = kit.glow("Light", rgb=pl.GLOW["human"])
    pl.cyl(body, 0.6, 0.25, (0, 0, 0.125), segs=12)
    pl.lamp(body, light, (0, 0, 0.26), (0, 0, 1), r=0.12)
    kit.finish()

RUN
    GUI      : Scripting tab -> open the model script -> Run Script
               (builds + prints the report; nothing is written to disk)
    Headless : blender -b --python model.py -- --all
               flags: --fbx --preview --manifest --blend --all  --out <root>
    Outputs  : <root>/art/fbx/<key>.fbx, <root>/art/previews/<key>.png,
               <root>/art/fbx/manifest.json, <root>/art/fbx/palette_<name>.png
               (<root> defaults to the folder holding this file, or $ORBITFALL_ROOT)

CONVENTIONS FOR ALL BUILDER FUNCTIONS
    fn(part, ..., loc, color=None, rot=(0,0,0), ...)
      part  : a Part from kit.part()/kit.glow()
      color : swatch name from the part's palette (None = part default;
              ignored on glow parts)
      rot   : Euler tuple, Euler, Matrix or Quaternion. Helpers: orient(dir),
              basis(x_dir, z_dir), AX_X, AX_Y
      Cylinder-like shapes run along their local +Z.
"""

import bpy
import bmesh
import json
import os
import random
import sys
from contextlib import contextmanager
from math import pi, sin, cos, radians, sqrt, tan
from mathutils import Vector, Matrix, Euler, Quaternion, noise

LIB_VERSION = "1.0"

# =====================================================================
# CONFIG
# =====================================================================
ATLAS_PX, ATLAS_GRID = 64, 4             # 64x64 atlas, 4x4 swatches of 16 px
ROBLOX_MATERIALS = {"SmoothPlastic", "Metal", "DiamondPlate", "Slate", "Concrete",
                    "Rock", "Basalt", "Glass", "Neon", "Foil"}
METALLIC = {"Metal", "DiamondPlate", "Foil"}

# FBX axis settings. With axis_forward='Z', axis_up='Y' Blender (x,y,z) is
# written as (-x, z, y), the mapping the brief gives for Roblox.
# !! Not yet checked against art/blender/kit.py: confirm on the first import.
FBX_SETTINGS = dict(
    axis_forward='Z', axis_up='Y', bake_space_transform=True,
    global_scale=1.0, apply_unit_scale=True, apply_scale_options='FBX_SCALE_NONE',
    mesh_smooth_type='FACE', use_mesh_modifiers=True, use_custom_props=True,
    path_mode='COPY', embed_textures=True, add_leaf_bones=False, bake_anim=False,
)

# (max triangles, max parts). None = no limit given in the brief.
BUDGETS = {
    "small_prop": (800, 5),     "prop": (3000, 5),       "set_piece": (6000, None),
    "regular":    (6000, 8),    "medium": (6000, 12),    # brief gives no medium tri cap
    "heavy":      (10000, 18),  "behemoth": (15000, 40), "landmark": (15000, None),
    "rubble":     (120, 1),     "debris": (300, 1),      "plant": (400, 3),
    "cosmetic":   (3000, 18),
}
PART_TRI_LIMIT = 10000

# ---------------------------------------------------------------------
# PALETTES (sRGB hex, max 16 swatches each; index = position in the atlas,
# row-major from the top-left)
# ---------------------------------------------------------------------
PALETTES = {
    "cogwork": [   # Cogwork Legion: gunmetal + rust, brass/copper fittings
        ("Gunmetal", "3a3f45"), ("GunmetalDark", "23272b"), ("Steel", "6b7178"), ("Rust", "7a3b1e"),
        ("RustDark", "4a2414"), ("Brass", "a8782f"), ("Copper", "8a4a2a"), ("Tread", "161718"),
        ("Soot", "2b2622"), ("CogRed", "8c1f17"), ("Ivory", "c9bf9a"), ("Hazard", "c9a227"),
        ("Oil", "0f0f10"), ("Bolt", "8d939a"), ("Lens", "3a0d08"), ("Grime", "4d4a40"),
    ],
    "brood": [     # Skitter Brood: chitin, bone, flesh, goo
        ("Chitin", "2e2a24"), ("ChitinMid", "4a3f30"), ("ChitinLight", "7a6a4c"), ("Carapace", "3b2d3a"),
        ("CarapaceLight", "5e4a5c"), ("Bone", "cbbf9e"), ("BoneDark", "8f8468"), ("Claw", "141210"),
        ("Flesh", "6e3b36"), ("FleshDark", "43221f"), ("Goo", "4f8a2a"), ("GooDark", "2c4d18"),
        ("Membrane", "8a7a52"), ("Mud", "3d3326"), ("Spot", "a39a72"), ("Black", "0d0c0b"),
    ],
    "lumen": [     # Lumen Concord: pearl/ivory ceramic, gold trim, violet
        ("Pearl", "e6e1d6"), ("Ivory", "cfc6b0"), ("Ceramic", "b3ab98"), ("Shadow", "7e7769"),
        ("Gold", "b8954a"), ("GoldDark", "7d6230"), ("Violet", "4b2a6e"), ("VioletDark", "2a173f"),
        ("Slate", "3a3a48"), ("Obsidian", "1c1b24"), ("Crystal", "9f8fd0"), ("CrystalDark", "5d4e8c"),
        ("Seam", "2f2c35"), ("Silver", "9ea3ad"), ("Lilac", "c8b8e6"), ("Black", "0e0d12"),
    ],
    "human": [     # squad, ORV Halcyon, call-ins, camp props
        ("Charcoal", "34383c"), ("CharcoalDark", "1f2225"), ("Tan", "9a8a68"), ("TanDark", "6b5f47"),
        ("Olive", "4f5236"), ("Steel", "767c83"), ("Visor", "121518"), ("Orange", "d0661c"),
        ("Hazard", "d1a62a"), ("Black", "111213"), ("Canvas", "7d7458"), ("Sandbag", "8f7f5c"),
        ("Concrete", "8a8780"), ("ConcreteDark", "5c5a55"), ("Rebar", "6a3a22"), ("Stencil", "d9d4c4"),
    ],
    "terrain": [   # rocks, flora, wrecks
        ("Rock", "5b544b"), ("RockDark", "3c3832"), ("RockLight", "857a6a"), ("Sand", "b39b72"),
        ("SandDark", "8a7454"), ("Ash", "4a4846"), ("AshLight", "6e6b66"), ("Basalt", "2a2826"),
        ("Ice", "a9c1cc"), ("IceDark", "6f8d9a"), ("Moss", "4b5a32"), ("Swamp", "3b4030"),
        ("Bark", "3a2a1e"), ("Charred", "1b1816"), ("Bone", "c4b896"), ("Strata", "9a6e4a"),
    ],
}
GLOW = {           # default Neon colours (sRGB hex)
    "cogwork": "ff4a1a",   # red-orange eyes / furnaces
    "brood":   "7dff3a",   # goo green
    "lumen":   "a35cff",   # violet cores
    "human":   "ffb347",   # warm lamps
    "cyan":    "4fd8ff",   # holo / UI
    "red":     "ff2a2a",   # blinking warning lamps
    "white":   "fff4e0",
}

# handy rotations: cylinder axis (local Z) onto world X / Y
AX_X = (0, pi / 2, 0)
AX_Y = (pi / 2, 0, 0)


# =====================================================================
# SMALL HELPERS
# =====================================================================
def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


def srgb_to_linear(c):
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def to_roblox(v):
    """Blender (x, y, z) -> Roblox (x, y, z), rounded."""
    return [round(-v[0], 3) + 0.0, round(v[2], 3) + 0.0, round(v[1], 3) + 0.0]


def _rot(rot):
    if isinstance(rot, Euler):
        return rot
    if isinstance(rot, (Matrix, Quaternion)):
        return rot.to_euler()
    return Euler(rot)


def orient(direction):
    """Euler that turns local +Z onto `direction`."""
    return Vector((0, 0, 1)).rotation_difference(Vector(direction).normalized()).to_euler()


def basis(x_dir=None, z_dir=(0, 0, 1)):
    """Euler for a frame whose local Z = z_dir and local X ~ x_dir."""
    z = Vector(z_dir).normalized()
    x = Vector(x_dir) if x_dir is not None else z.orthogonal()
    x = (x - z * x.dot(z)).normalized()
    return Matrix((x, z.cross(x), z)).transposed().to_euler()


def frame(loc, rot=(0, 0, 0)):
    """Return f(local_xyz) -> world Vector for a placed local frame."""
    m, o = _rot(rot).to_matrix(), Vector(loc)
    return lambda p: o + m @ Vector(p)


def chamfer_rect(hx, hy, c, z=None):
    """Rectangle with 45-degree corners, CCW from the front (-Y) edge.
    Returns 2D points, or 3D points at height z (for loft rings)."""
    pts = [(-hx + c, -hy), (hx - c, -hy), (hx, -hy + c), (hx, hy - c),
           (hx - c, hy), (-hx + c, hy), (-hx, hy - c), (-hx, -hy + c)]
    return pts if z is None else [(x, y, z) for x, y in pts]


def _auto_bevel(*dims, k=0.12, cap=0.06, skip_below=0.1):
    """Size-relative bevel; 0 for pieces too small for a bevel to read in game."""
    m = min(abs(d) for d in dims)
    return 0.0 if m < skip_below else min(cap, k * m)


# =====================================================================
# KIT  (one model)
# =====================================================================
class Part:
    def __init__(self, kit, name, role, material, pivot, parent, rgb, color, mirror_x):
        if material not in ROBLOX_MATERIALS:
            raise ValueError(f"{name}: unknown Roblox material '{material}'")
        self.kit, self.name, self.role, self.material = kit, name, role, material
        self.pivot = Vector(pivot) if pivot is not None else Vector((0, 0, 0))
        self.parent = parent
        self.rgb = rgb                       # hex string for untextured parts
        self.textured = rgb is None
        self.color = color or kit.palette[0][0]
        self.mirror_x = mirror_x
        self.pieces = []
        self.obj = None
        self.tris = 0
        self._mirror_now = False

    def __repr__(self):
        return f"<Part {self.name}>"


class Kit:
    def __init__(self, key, palette="cogwork", category="prop", seed=1,
                 tri_budget=None, part_budget=None, reset=True):
        if palette not in PALETTES:
            raise ValueError(f"palette must be one of {list(PALETTES)}")
        self.key, self.palette_name, self.category = key, palette, category
        self.palette = PALETTES[palette]
        self.swatches = {n: i for i, (n, _) in enumerate(self.palette)}
        b = BUDGETS.get(category, (None, None))
        self.tri_budget = tri_budget or b[0]
        self.part_budget = part_budget or b[1]
        self.rng = random.Random(seed)
        self.seed = seed
        self.parts = []
        self.attachments = []
        if reset:
            reset_scene()
        sc = bpy.context.scene
        self.out = bpy.data.collections.new(key)
        sc.collection.children.link(self.out)
        self._tmp = bpy.data.collections.new("_build_tmp")
        sc.collection.children.link(self._tmp)
        self.image = _palette_image(palette)
        self.built = False

    # ---------------------------------------------------------------- parts
    def part(self, name, role="body", material="Metal", pivot=None, parent=None,
             color=None, mirror_x=False):
        """Textured MeshPart. role: body | limb. pivot = joint (Blender coords)."""
        return self._add_part(Part(self, name, role, material, pivot, parent,
                                   None, color, mirror_x))

    def glow(self, name, rgb=None, role="glow", pivot=None, parent=None, mirror_x=False):
        """Untextured Neon MeshPart. role: glow | weak."""
        rgb = rgb or GLOW.get(self.palette_name, "ffffff")
        return self._add_part(Part(self, name, role, "Neon", pivot, parent,
                                   rgb, None, mirror_x))

    def attachment(self, name, pos, part="Body"):
        """Named point for code (item mounts, effects). pos = Blender coords
        relative to the model origin; written to the manifest in Roblox coords."""
        self.attachments.append((name, part, Vector(pos)))

    def shift(self, v):
        """Move every piece, pivot and attachment by v (before build)."""
        v = Vector(v)
        for p in self.parts:
            p.pivot = p.pivot + v
            for ob in p.pieces:
                ob.location = ob.location + v
        self.attachments = [(n, pt, pos + v) for n, pt, pos in self.attachments]

    def ground(self):
        """Shift the model so its lowest point sits at z = 0 (call before build)."""
        bpy.context.view_layer.update()
        lo = min((ob.matrix_world @ Vector(c)).z for p in self.parts for ob in p.pieces
                 for c in ob.bound_box)
        self.shift((0, 0, -lo))
        return -lo

    def center(self):
        """Shift the model so its X/Y bounding-box centre is the origin (before build)."""
        bpy.context.view_layer.update()
        pts = [ob.matrix_world @ Vector(c) for p in self.parts for ob in p.pieces
               for c in ob.bound_box]
        cx = (min(q.x for q in pts) + max(q.x for q in pts)) / 2
        cy = (min(q.y for q in pts) + max(q.y for q in pts)) / 2
        self.shift((-cx, -cy, 0))
        return Vector((-cx, -cy, 0))

    def _add_part(self, p):
        if any(q.name == p.name for q in self.parts):
            raise ValueError(f"duplicate part name {p.name}")
        self.parts.append(p)
        return p

    def swatch(self, name):
        try:
            return self.swatches[name]
        except KeyError:
            raise KeyError(f"'{name}' not in palette '{self.palette_name}': "
                           f"{list(self.swatches)}") from None

    # ---------------------------------------------------------------- build
    def build(self):
        """Merge pieces into one object per part, UV to palette, set pivots."""
        if self.built:
            return
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        flip = Matrix.Scale(-1, 4, (1, 0, 0))
        for p in self.parts:
            if not p.pieces:
                raise RuntimeError(f"part {p.name} has no geometry")
            bm = bmesh.new()
            for ob in p.pieces:
                me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
                me.transform(ob.matrix_world)
                bm.from_mesh(me)
                if p.mirror_x or ob.get("_mirror"):
                    tmp = bmesh.new()
                    tmp.from_mesh(me)
                    bmesh.ops.transform(tmp, matrix=flip, verts=tmp.verts)
                    bmesh.ops.reverse_faces(tmp, faces=tmp.faces)
                    tmp.to_mesh(me)
                    tmp.free()
                    bm.from_mesh(me)
                bpy.data.meshes.remove(me)
            # No cross-piece weld: every piece is a closed shell, and welding
            # touching shells creates non-manifold edges.
            ngons = [f for f in bm.faces if len(f.verts) > 4]
            if ngons:   # concave caps would break in Roblox's triangulator
                bmesh.ops.triangulate(bm, faces=ngons, quad_method='BEAUTY',
                                      ngon_method='EAR_CLIP')
            uv = bm.loops.layers.uv.new("UVMap")
            for f in bm.faces:
                i = f.material_index if p.textured else 0
                col, row = i % ATLAS_GRID, i // ATLAS_GRID
                c = ((col + 0.5) / ATLAS_GRID, 1 - (row + 0.5) / ATLAS_GRID)
                for lp in f.loops:
                    lp[uv].uv = c
                f.material_index = 0
                f.smooth = False
            bmesh.ops.translate(bm, vec=-p.pivot, verts=bm.verts)
            p.tris = sum(len(f.verts) - 2 for f in bm.faces)
            me = bpy.data.meshes.new(p.name)
            bm.to_mesh(me)
            bm.free()
            me.materials.append(self._material(p))
            ob = bpy.data.objects.new(p.name, me)
            self.out.objects.link(ob)
            ob.location = p.pivot
            ob["roblox_material"] = p.material
            ob["role"] = p.role
            ob["parent_part"] = p.parent or ""
            p.obj = ob
        for p in self.parts:
            for ob in p.pieces:
                me = ob.data
                bpy.data.objects.remove(ob, do_unlink=True)
                bpy.data.meshes.remove(me)
            p.pieces = []
        bpy.data.collections.remove(self._tmp)
        bpy.context.view_layer.update()      # refresh matrix_world before bbox()
        self.built = True

    def _material(self, p):
        m = bpy.data.materials.new(f"{self.key}_{p.name}")
        m.use_nodes = True
        nt = m.node_tree
        bsdf = nt.nodes.get("Principled BSDF")
        if p.textured:
            tex = nt.nodes.new("ShaderNodeTexImage")
            tex.image, tex.interpolation, tex.location = self.image, 'Closest', (-400, 200)
            nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            bsdf.inputs["Metallic"].default_value = 0.6 if p.material in METALLIC else 0.0
            bsdf.inputs["Roughness"].default_value = 0.45 if p.material in METALLIC else 0.75
        else:
            lin = (*srgb_to_linear(hex_rgb(p.rgb)), 1.0)
            bsdf.inputs["Base Color"].default_value = lin
            bsdf.inputs["Emission Color"].default_value = lin
            bsdf.inputs["Emission Strength"].default_value = 3.0
        m["roblox_material"] = p.material
        return m

    # ---------------------------------------------------------------- checks
    def bbox(self):
        pts = [ob.matrix_world @ v.co for p in self.parts for ob in [p.obj]
               for v in ob.data.vertices]
        lo = Vector([min(q[i] for q in pts) for i in range(3)])
        hi = Vector([max(q[i] for q in pts) for i in range(3)])
        return lo, hi

    def report(self):
        """Print triangles, budgets, placement and topology. Returns warnings."""
        self.build()
        warn = []
        lines = [f"\n[parts_lib] {self.key}  ({self.category}, palette {self.palette_name})"]
        lines.append(f"  {'part':<18}{'role':<7}{'material':<14}{'tris':>6}  topology")
        names = {p.name for p in self.parts}
        for p in self.parts:
            t = _topology(p.obj.data)
            issues = ", ".join(f"{k} {v}" for k, v in t.items() if v) or "ok"
            lines.append(f"  {p.name:<18}{p.role:<7}{p.material:<14}{p.tris:>6}  {issues}")
            if p.tris > PART_TRI_LIMIT:
                warn.append(f"{p.name}: {p.tris} tris > {PART_TRI_LIMIT} per MeshPart")
            if p.parent and p.parent not in names:
                warn.append(f"{p.name}: parent '{p.parent}' does not exist")
            if t["open_edges"] or t["loose"] or t["degenerate"]:
                warn.append(f"{p.name}: topology - {issues}")
        total = sum(p.tris for p in self.parts)
        lines.append(f"  {'TOTAL':<39}{total:>6}  ({len(self.parts)} parts)")
        if self.tri_budget and total > self.tri_budget:
            warn.append(f"total {total} tris > budget {self.tri_budget}")
        if self.part_budget and len(self.parts) > self.part_budget:
            warn.append(f"{len(self.parts)} parts > budget {self.part_budget}")
        lo, hi = self.bbox()
        size, ctr = hi - lo, (hi + lo) / 2
        lines.append(f"  size (Roblox X,Y,Z studs): {[round(x, 2) for x in (size.x, size.z, size.y)]}")
        if abs(lo.z) > 0.05:
            warn.append(f"base is at z={lo.z:.2f}, expected 0")
        if abs(ctr.x) > 0.1 * max(size.x, 1) or abs(ctr.y) > 0.1 * max(size.y, 1):
            warn.append(f"model not centred on X/Y (centre {ctr.x:.2f}, {ctr.y:.2f})")
        lines += [f"  ! {w}" for w in warn] or ["  all checks passed"]
        print("\n".join(lines) + "\n")
        return warn

    # ---------------------------------------------------------------- outputs
    def root(self):
        a = _argv()
        if "--out" in a:
            return os.path.abspath(a[a.index("--out") + 1])
        return os.environ.get("ORBITFALL_ROOT") or os.path.dirname(os.path.abspath(__file__))

    def _path(self, *rel):
        p = os.path.join(self.root(), *rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    def save_palette(self):
        path = self._path("art", "fbx", f"palette_{self.palette_name}.png")
        self.image.filepath_raw = path
        self.image.file_format = 'PNG'
        self.image.save()
        return path

    def export_fbx(self):
        self.build()
        self.save_palette()
        path = self._path("art", "fbx", f"{self.key}.fbx")
        bpy.ops.object.select_all(action='DESELECT')
        for p in self.parts:
            p.obj.select_set(True)
        bpy.ops.export_scene.fbx(filepath=path, use_selection=True,
                                 object_types={'MESH'}, **FBX_SETTINGS)
        print(f"[parts_lib] FBX -> {path}")
        return path

    def manifest_entry(self):
        self.build()
        lo, hi = self.bbox()
        size, ctr = hi - lo, (hi + lo) / 2
        parts = []
        for p in self.parts:
            parts.append({
                "name": p.name, "role": p.role, "parent": p.parent,
                "pivot": to_roblox(p.pivot), "material": p.material,
                "textured": p.textured, "triangles": p.tris,
                "rgb": list(int(round(c * 255)) for c in hex_rgb(p.rgb)) if p.rgb else None,
            })
        return {
            "fbx": f"art/fbx/{self.key}.fbx",
            "texture": f"art/fbx/palette_{self.palette_name}.png",
            "size_studs_roblox_xyz": [round(size.x, 3), round(size.z, 3), round(size.y, 3)],
            "bbox_center_roblox": to_roblox(ctr),
            "palette": self.palette_name,
            "parts": parts,
            "weak_spots": [p.name for p in self.parts if p.role == "weak"],
            "attachments": [{"name": n, "part": pt, "pos": to_roblox(v)}
                            for n, pt, v in self.attachments],
            "assetId": "",
        }

    def write_manifest(self):
        path = self._path("art", "fbx", "manifest.json")
        data = {}
        if os.path.exists(path):
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        entry = self.manifest_entry()
        if isinstance(data, list):     # tolerate a list-style manifest
            data = [e for e in data if e.get("key") != self.key] + [{"key": self.key, **entry}]
        else:
            old = data.get(self.key, {})
            entry["assetId"] = old.get("assetId", "")   # never wipe an uploaded id
            data[self.key] = entry
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"[parts_lib] manifest entry '{self.key}' -> {path}")
        return path

    def _preview_rig(self):
        sc = bpy.context.scene
        if getattr(self, "_cam", None):
            return self._cam
        col = bpy.data.collections.new("_preview")
        sc.collection.children.link(col)
        cam = bpy.data.objects.new("PreviewCam", bpy.data.cameras.new("PreviewCam"))
        cam.data.lens = 50
        col.objects.link(cam)
        sc.camera = cam
        for name, rot, energy in (("Key", (radians(50), 0, radians(30)), 3.5),
                                  ("Rim", (radians(60), 0, radians(200)), 2.0)):
            ld = bpy.data.lights.new(name, 'SUN')
            ld.energy = energy
            ob = bpy.data.objects.new(name, ld)
            ob.rotation_euler = rot
            col.objects.link(ob)
        world = sc.world or bpy.data.worlds.new("World")
        sc.world = world
        world.use_nodes = True
        bg = world.node_tree.nodes.get("Background")
        bg.inputs[0].default_value = (0.22, 0.22, 0.22, 1)
        bg.inputs[1].default_value = 1.0
        self._cam = cam
        return cam

    def preview(self, size=1024, suffix="", poses=None, direction=(0.65, -1.0, 0.55),
                zoom=1.0, target=None, moves=None):
        """Render on neutral grey -> art/previews/<key><suffix>.png.
        poses = {part_name: (rx, ry, rz) radians} rotates rigged parts about their
        pivots for this shot only (e.g. an open door). moves = {part_name: (dx, dy, dz)}
        slides parts in their parent's frame (e.g. barrel recoil). Default view: 3/4 front."""
        self.build()
        sc = bpy.context.scene
        objs = {p.name: p.obj for p in self.parts}
        # chain rigged parts for posed shots so a child follows its parent
        # (e.g. Gun pitches on a yawed turret); unlinked again after the render
        linked = []
        if poses or moves:
            for p in self.parts:
                if p.parent in objs and p.parent != p.name:
                    ob, par = objs[p.name], objs[p.parent]
                    ob.parent = par
                    ob.matrix_parent_inverse = par.matrix_world.inverted()
                    linked.append(ob)
        for name, rot in (poses or {}).items():
            objs[name].rotation_euler = rot
        for name, d in (moves or {}).items():
            objs[name].location = objs[name].location + Vector(d)
        bpy.context.view_layer.update()
        lo, hi = self.bbox()
        ctr, rad = (hi + lo) / 2, max((hi - lo).length / 2, 0.5)
        if target is not None:
            ctr = Vector(target)
        cam = self._preview_rig()
        dist = rad / sin(radians(39.6 / 2)) * 1.08 / zoom
        cam.data.clip_start, cam.data.clip_end = dist * 0.01, dist + rad * 4
        d = Vector(direction).normalized()
        cam.location = ctr + d * dist
        cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
        r = sc.render
        r.resolution_x = r.resolution_y = size
        r.resolution_percentage = 100
        r.film_transparent = False
        r.image_settings.file_format = 'PNG'
        sc.view_settings.view_transform = 'Standard'
        final = self._path("art", "previews", f"{self.key}{suffix}.png")
        # render to a temp file first: synced folders (OneDrive) can briefly lock
        # the target, which must not trigger an engine fallback
        import tempfile, shutil, time
        r.filepath = os.path.join(tempfile.gettempdir(), f"_pl_{self.key}{suffix}.png")
        out = None
        for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
            try:
                r.engine = eng
                if eng == "BLENDER_WORKBENCH":
                    sc.display.shading.color_type = 'TEXTURE'
                bpy.ops.render.render(write_still=True)
                break
            except Exception as e:     # engine missing or no GPU: try the next
                print(f"[parts_lib] {eng} failed: {e}")
        else:
            eng = None
        if eng:
            for attempt in range(10):
                try:
                    shutil.copyfile(r.filepath, final)
                    out = final
                    break
                except OSError:
                    time.sleep(0.5)
            print(f"[parts_lib] preview ({eng}) -> {out or 'FAILED to write ' + final}")
        for name in (poses or {}):
            objs[name].rotation_euler = (0, 0, 0)
        for name, d in (moves or {}).items():
            objs[name].location = objs[name].location - Vector(d)
        bpy.context.view_layer.update()
        for ob in linked:
            ob.parent = None
            ob.matrix_parent_inverse = Matrix.Identity(4)
        bpy.context.view_layer.update()
        return out

    def save_blend(self):
        path = self._path("art", "blend", f"{self.key}.blend")
        bpy.ops.wm.save_as_mainfile(filepath=path)
        return path

    def finish(self, fbx=None, preview=None, manifest=None, blend=None, extra_previews=()):
        """Build + report, then write whatever the flags (or args) ask for.
        extra_previews: list of preview() kwargs, e.g. [dict(suffix="_open", poses=...)]"""
        a = _argv()
        every = "--all" in a
        pick = lambda v, flag: v if v is not None else (every or flag in a)
        self.build()
        warn = self.report()
        if pick(fbx, "--fbx"):
            self.export_fbx()
        if pick(manifest, "--manifest"):
            self.write_manifest()
        if pick(preview, "--preview"):
            self.preview()
            for kw in extra_previews:
                self.preview(**kw)
        if pick(blend, "--blend"):
            self.save_blend()
        return warn

def _argv():
    return sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def _topology(me):
    bm = bmesh.new()
    bm.from_mesh(me)
    t = {
        "open_edges": sum(1 for e in bm.edges if not e.is_manifold),
        "loose": sum(1 for v in bm.verts if not v.link_edges)
                 + sum(1 for e in bm.edges if not e.link_faces),
        "degenerate": sum(1 for f in bm.faces if f.calc_area() < 1e-9),
        "ngons": sum(1 for f in bm.faces if len(f.verts) > 4),
    }
    bm.free()
    return t


def reset_scene():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for c in list(bpy.data.collections):
        bpy.data.collections.remove(c)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.images,
                 bpy.data.cameras, bpy.data.lights):
        for block in list(coll):
            if block.users == 0:
                coll.remove(block)


def _palette_image(name):
    img = bpy.data.images.get(f"palette_{name}")
    if img:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(f"palette_{name}", ATLAS_PX, ATLAS_PX, alpha=False)
    img.colorspace_settings.name = 'sRGB'
    cols = [hex_rgb(h) for _, h in PALETTES[name]]
    filler = hex_rgb("808080")
    sw = ATLAS_PX // ATLAS_GRID
    px = []
    for y in range(ATLAS_PX):                    # Blender pixel rows start at the bottom
        row = ATLAS_GRID - 1 - y // sw
        for x in range(ATLAS_PX):
            i = row * ATLAS_GRID + x // sw
            px.extend((*(cols[i] if i < len(cols) else filler), 1.0))
    img.pixels[:] = px
    return img


@contextmanager
def mirrored(part):
    """Pieces made inside `with mirrored(part):` get an X-mirrored twin."""
    part._mirror_now = True
    try:
        yield part
    finally:
        part._mirror_now = False


# =====================================================================
# CORE PRIMITIVES
# =====================================================================
def _add(part, bm, loc=(0, 0, 0), rot=(0, 0, 0), color=None, bevel=0.0, angle=50):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    idx = part.kit.swatch(color or part.color) if part.textured else 0
    for f in bm.faces:
        f.material_index = idx          # read back as the swatch index in build()
    me = bpy.data.meshes.new("_piece")
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new("_piece", me)
    part.kit._tmp.objects.link(ob)
    ob.location = Vector(loc)
    ob.rotation_euler = _rot(rot)
    if part._mirror_now:
        ob["_mirror"] = True
    if bevel and bevel > 0:
        b = ob.modifiers.new("Bevel", 'BEVEL')
        b.width, b.segments = bevel, 1
        b.limit_method, b.angle_limit = 'ANGLE', radians(angle)
    part.pieces.append(ob)
    return ob


def box(part, size, loc, color=None, rot=(0, 0, 0), bevel=None):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    return _add(part, bm, loc, rot, color, _auto_bevel(*size) if bevel is None else bevel)


def cyl(part, r, depth, loc, color=None, rot=(0, 0, 0), segs=12, r2=None, bevel=None):
    """Cylinder / truncated cone along local Z, centred on loc."""
    if r2 is not None and r2 <= 1e-6:
        return lathe(part, [(r, -depth / 2), (0, depth / 2)], loc, color, rot, segs)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segs,
                          radius1=r, radius2=r if r2 is None else r2, depth=depth)
    bv = _auto_bevel(r * 0.66, depth, k=0.1, cap=0.04) if bevel is None else bevel
    return _add(part, bm, loc, rot, color, bv)


def sphere(part, r, loc, color=None, segs=10, scale=(1, 1, 1), rot=(0, 0, 0)):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=max(3, segs // 2), radius=r)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    return _add(part, bm, loc, rot, color)


def ico(part, r, loc, color=None, subdiv=1, scale=(1, 1, 1), rot=(0, 0, 0),
        jitter=0.0, seed=None):
    """Icosphere; jitter (fraction of r) gives blobby/faceted shapes."""
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=r)
    if jitter:
        rng = random.Random(part.kit.rng.random() if seed is None else seed)
        for v in bm.verts:
            v.co *= 1 + rng.uniform(-jitter, jitter)
    bmesh.ops.scale(bm, vec=Vector(scale), verts=bm.verts)
    return _add(part, bm, loc, rot, color)


def torus(part, R, r, loc, color=None, rot=(0, 0, 0), segs=16, csegs=6, arc=2 * pi):
    """Ring around local Z. arc < 2*pi gives a capped partial ring."""
    full = arc >= 2 * pi - 1e-6
    n = segs if full else segs + 1
    bm = bmesh.new()
    rings = []
    for i in range(n):
        a = arc * i / segs
        rings.append([bm.verts.new(((R + r * cos(b)) * cos(a), (R + r * cos(b)) * sin(a),
                                    r * sin(b)))
                      for b in (2 * pi * j / csegs for j in range(csegs))])
    for i in range(segs):
        A, B = rings[i], rings[(i + 1) % n]
        for j in range(csegs):
            k = (j + 1) % csegs
            bm.faces.new((A[j], B[j], B[k], A[k]))
    if not full:
        bm.faces.new(rings[0])
        bm.faces.new(list(reversed(rings[-1])))
    return _add(part, bm, loc, rot, color)


def lathe(part, profile, loc, color=None, rot=(0, 0, 0), segs=12, bevel=0, twist=0.0):
    """Revolve [(radius, z), ...] (bottom -> top) around local Z. r=0 makes a pole."""
    bm = bmesh.new()
    rings = []
    for k, (r, z) in enumerate(profile):
        if r <= 1e-6:
            rings.append([bm.verts.new((0, 0, z))])
        else:
            off = twist * k
            rings.append([bm.verts.new((r * cos(2 * pi * i / segs + off),
                                        r * sin(2 * pi * i / segs + off), z))
                          for i in range(segs)])
    for A, B in zip(rings, rings[1:]):
        if len(A) == 1 and len(B) == 1:
            continue
        for i in range(segs):
            j = (i + 1) % segs
            if len(A) == 1:
                bm.faces.new((A[0], B[i], B[j]))
            elif len(B) == 1:
                bm.faces.new((A[i], A[j], B[0]))
            else:
                bm.faces.new((A[i], A[j], B[j], B[i]))
    if len(rings[0]) > 1:
        bm.faces.new(list(reversed(rings[0])))
    if len(rings[-1]) > 1:
        bm.faces.new(rings[-1])
    return _add(part, bm, loc, rot, color, bevel)


def loft(part, rings, loc=(0, 0, 0), color=None, rot=(0, 0, 0), cap=True,
         closed=False, bevel=0):
    """Skin equal-length rings of 3D points. closed=True joins last ring to first."""
    bm = bmesh.new()
    R = [[bm.verts.new(Vector(p)) for p in ring] for ring in rings]
    m = len(R[0])
    pairs = list(zip(R, R[1:])) + ([(R[-1], R[0])] if closed else [])
    for A, B in pairs:
        for i in range(m):
            j = (i + 1) % m
            bm.faces.new((A[i], A[j], B[j], B[i]))
    if cap and not closed:
        bm.faces.new(R[0])
        bm.faces.new(list(reversed(R[-1])))
    return _add(part, bm, loc, rot, color, bevel)


def taper_box(part, bot, top, z0, z1, color=None, top_offset=(0, 0), loc=(0, 0, 0),
              rot=(0, 0, 0), bevel=None):
    """Tapered block. bot/top = (size_x, size_y); top can shift by top_offset."""
    def ring(s, z, o=(0, 0)):
        x, y = s[0] / 2, s[1] / 2
        return [(o[0] - x, o[1] - y, z), (o[0] + x, o[1] - y, z),
                (o[0] + x, o[1] + y, z), (o[0] - x, o[1] + y, z)]
    bv = _auto_bevel(*bot, *top, z1 - z0) if bevel is None else bevel
    return loft(part, [ring(bot, z0), ring(top, z1, top_offset)], loc, color, rot, bevel=bv)


def extrude(part, profile, depth, loc, color=None, rot=(0, 0, 0), plane='XZ', bevel=None):
    """Extrude a 2D outline. plane XY->along Z, XZ->along Y, YZ->along X."""
    def p3(a, b, t):
        return {'XY': (a, b, t), 'XZ': (a, t, b), 'YZ': (t, a, b)}[plane]
    bm = bmesh.new()
    A = [bm.verts.new(p3(a, b, -depth / 2)) for a, b in profile]
    B = [bm.verts.new(p3(a, b, depth / 2)) for a, b in profile]
    bm.faces.new(A)
    bm.faces.new(list(reversed(B)))
    n = len(profile)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((A[i], A[j], B[j], B[i]))
    bv = _auto_bevel(depth, k=0.25, cap=0.04) if bevel is None else bevel
    return _add(part, bm, loc, rot, color, bv)


def gear(part, r_tip, r_root, teeth, thick, loc, color=None, rot=(0, 0, 0), hub=0.0):
    """Cog around local Z. hub > 0 adds a raised hub of that radius."""
    p = 2 * pi / teeth
    prof = []
    for i in range(teeth):
        a = i * p
        for f, r in ((0.0, r_root), (0.18, r_tip), (0.48, r_tip), (0.66, r_root)):
            prof.append((r * cos(a + f * p), r * sin(a + f * p)))
    ob = extrude(part, prof, thick, loc, color, rot, plane='XY', bevel=0)
    if hub:
        cyl(part, hub, thick * 1.6, loc, color, rot, segs=10)
    return ob


def rod(part, p0, p1, r, color=None, segs=8, r2=None, bevel=0):
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    return cyl(part, r, d.length, (p0 + p1) / 2, color, orient(d), segs, r2, bevel)


def _frames(points, closed=False):
    pts = [Vector(p) for p in points]
    n = len(pts)
    out, nrm = [], None
    for i in range(n):
        if closed:
            t = pts[(i + 1) % n] - pts[i - 1]
        else:
            t = pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]
        t.normalize()
        nrm = t.orthogonal() if nrm is None else nrm - t * nrm.dot(t)
        nrm.normalize()
        out.append((pts[i], nrm.copy(), t.cross(nrm)))
    return out


def tube(part, points, r, color=None, sides=6, closed=False, cap=True, profile=None):
    """Sweep a circle (or `profile` [(a, b)...] in the ring plane) along points.
    r may be a number or a list with one radius per point."""
    rs = r if isinstance(r, (list, tuple)) else [r] * len(points)
    shape = profile or [(cos(2 * pi * i / sides), sin(2 * pi * i / sides)) for i in range(sides)]
    rings = [[c + (n * a + b * bb) * max(rr, 0.004) for a, bb in shape]
             for (c, n, b), rr in zip(_frames(points, closed), rs)]
    return loft(part, rings, color=color, cap=cap, closed=closed)


# =====================================================================
# SHARED DETAIL (bolts, seams, plates, stripes, vents)
# =====================================================================
def bolt(part, loc, normal=(0, 0, 1), r=0.05, color=None, segs=6):
    """Hex bolt head sitting on a surface (segs=4: cheap square rivet, 12 tris)."""
    n = Vector(normal).normalized()
    return cyl(part, r, r * 0.8, Vector(loc) + n * r * 0.3, color, orient(n), segs=segs, bevel=0)


def bolt_row(part, p0, p1, count, normal=(0, 0, 1), r=0.05, color=None, segs=6):
    p0, p1 = Vector(p0), Vector(p1)
    for i in range(count):
        t = i / (count - 1) if count > 1 else 0.5
        bolt(part, p0.lerp(p1, t), normal, r, color, segs)


def bolt_ring(part, center, normal, R, count, r=0.05, color=None):
    n = Vector(normal).normalized()
    t1 = n.orthogonal().normalized()
    t2 = n.cross(t1)
    for i in range(count):
        a = 2 * pi * i / count
        bolt(part, Vector(center) + (t1 * cos(a) + t2 * sin(a)) * R, n, r, color)


def strip(part, p0, p1, normal=(0, 0, 1), w=0.05, h=0.03, color=None, bevel=0):
    """Thin bar from p0 to p1 lying on a surface (panel seams, trims, welds)."""
    p0, p1 = Vector(p0), Vector(p1)
    d, n = p1 - p0, Vector(normal).normalized()
    return box(part, (d.length, w, h), (p0 + p1) / 2 + n * h / 2, color,
               basis(d, n), bevel)


def plate(part, w, h, t, loc, rot=(0, 0, 0), color=None, chamfer=0.25, bevel=None):
    """Armour plate in its local XY (thickness along Z) with clipped corners."""
    c = min(w, h) * chamfer
    prof = [(-w / 2 + c, -h / 2), (w / 2 - c, -h / 2), (w / 2, -h / 2 + c), (w / 2, h / 2 - c),
            (w / 2 - c, h / 2), (-w / 2 + c, h / 2), (-w / 2, h / 2 - c), (-w / 2, -h / 2 + c)]
    if c <= 1e-6:
        prof = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    return extrude(part, prof, t, loc, color, rot, plane='XY', bevel=bevel)


def riveted_plate(part, w, h, t, loc, rot=(0, 0, 0), color=None, rivet_color=None,
                  spacing=0.5, rivet_r=None, chamfer=0.2, rivet_segs=6, bevel=None):
    """Plate with a rivet border on its outer (+Z local) face. With chamfered
    corners the rows stop where the chamfer starts (no rivets off the plate).
    Budget knobs: rivet_segs=4 (square rivets), bevel=0 (thin armour plates)."""
    plate(part, w, h, t, loc, rot, color, chamfer, bevel)
    f = frame(loc, rot)
    n = _rot(rot).to_matrix() @ Vector((0, 0, 1))
    rr = rivet_r or min(0.06, min(w, h) * 0.06)
    c = min(w, h) * chamfer
    ix, iy, z = w / 2 - rr * 2.5, h / 2 - rr * 2.5, t / 2
    lx, ly = min(ix, w / 2 - c - rr), min(iy, h / 2 - c - rr)   # row extents
    nx = max(2, int(2 * lx / spacing) + 1)
    ny = max(2, int(2 * ly / spacing) + 1)
    bolt_row(part, f((-lx, -iy, z)), f((lx, -iy, z)), nx, n, rr, rivet_color, rivet_segs)
    bolt_row(part, f((-lx, iy, z)), f((lx, iy, z)), nx, n, rr, rivet_color, rivet_segs)
    if c > 1e-6:                     # columns are separate from the rows
        bolt_row(part, f((-ix, -ly, z)), f((-ix, ly, z)), ny, n, rr, rivet_color, rivet_segs)
        bolt_row(part, f((ix, -ly, z)), f((ix, ly, z)), ny, n, rr, rivet_color, rivet_segs)
    elif ny > 2:                     # square plate: skip the shared corners
        dy = 2 * iy / (ny - 1)
        bolt_row(part, f((-ix, -iy + dy, z)), f((-ix, iy - dy, z)), ny - 2, n, rr, rivet_color, rivet_segs)
        bolt_row(part, f((ix, -iy + dy, z)), f((ix, iy - dy, z)), ny - 2, n, rr, rivet_color, rivet_segs)


def hazard_stripes(part, w, h, loc, rot=(0, 0, 0), stripes=5, c1="Hazard", c2=None,
                   t=0.03, slant=None):
    """Diagonal two-tone stripes on a thin plate (local XY, facing +Z)."""
    c2 = c2 or ("Black" if "Black" in part.kit.swatches else part.kit.palette[1][0])
    box(part, (w, h, t), loc, c2, rot, bevel=0)
    f = frame(loc, rot)
    sw = w / (stripes * 2)
    s = h * 0.6 if slant is None else slant
    def clip(poly, xc, keep_less):
        out = []
        for i, a in enumerate(poly):
            b = poly[(i + 1) % len(poly)]
            ina, inb = (a[0] <= xc) == keep_less, (b[0] <= xc) == keep_less
            if ina:
                out.append(a)
            if ina != inb:
                u = (xc - a[0]) / (b[0] - a[0])
                out.append((xc, a[1] + u * (b[1] - a[1])))
        return out
    for k in range(stripes + 2):
        x0 = -w / 2 + k * 2 * sw - s
        poly = [(x0, -h / 2), (x0 + sw, -h / 2), (x0 + sw + s, h / 2), (x0 + s, h / 2)]
        poly = clip(clip(poly, w / 2, True), -w / 2, False)
        poly = [p for i, p in enumerate(poly)
                if (Vector(p) - Vector(poly[i - 1])).length > 1e-4]
        area = 0.5 * abs(sum(poly[i][0] * poly[i - 1][1] - poly[i - 1][0] * poly[i][1]
                             for i in range(len(poly)))) if len(poly) >= 3 else 0
        if area < 1e-4:
            continue
        extrude(part, poly, t * 0.4, f((0, 0, t / 2 + t * 0.2)), c1, rot, plane='XY', bevel=0)


def vent_grille(part, w, h, slats, loc, rot=(0, 0, 0), color=None, slat_color=None,
                glow=None, depth=0.12):
    """Framed vent (local XY, facing +Z). glow=Part puts a hot plate behind the slats."""
    f = frame(loc, rot)
    fw = min(w, h) * 0.12
    for x, y, sx, sy in ((0, h / 2 - fw / 2, w, fw), (0, -h / 2 + fw / 2, w, fw),
                         (w / 2 - fw / 2, 0, fw, h), (-w / 2 + fw / 2, 0, fw, h)):
        box(part, (sx, sy, depth), f((x, y, 0)), color, rot)
    inner = h - 2 * fw
    for i in range(slats):
        y = -inner / 2 + inner * (i + 0.5) / slats
        box(part, (w - 2 * fw, inner / slats * 0.55, depth * 0.5), f((0, y, 0)), slat_color,
            Euler(_rot(rot)).to_matrix() @ Matrix.Rotation(radians(30), 3, 'X'), bevel=0)
    target = glow if glow is not None else part
    box(target, (w - 2 * fw, inner, depth * 0.2), f((0, 0, -depth * 0.35)),
        None if glow is not None else (slat_color or color), rot, bevel=0)


def stencil_panel(part, w, h, loc, rot=(0, 0, 0), color=None, mark_color=None, t=0.04):
    """Raised panel with chunky stencil-style marks (serial-number feel, no text)."""
    box(part, (w, h, t), loc, color, rot)
    f = frame(loc, rot)
    rng = part.kit.rng
    bars = rng.choice([[(-.3, 0, .12, .7), (0, .25, .4, .14), (0, -.25, .4, .14), (.3, 0, .12, .7)],
                       [(-.25, 0, .14, .8), (.1, .3, .5, .14), (.1, 0, .5, .14), (.1, -.3, .5, .14)],
                       [(-.3, .2, .3, .14), (0, 0, .14, .7), (.3, -.2, .3, .14)],
                       [(-.2, 0, .14, .8), (.2, 0, .14, .8), (0, .3, .55, .14)]])
    for x, y, sx, sy in bars:
        box(part, (sx * w * 0.8, sy * h * 0.8, t * 0.4), f((x * w, y * h, t / 2 + t * 0.2)),
            mark_color, rot, bevel=0)


def cable(part, p0, p1, r=0.04, sag=0.3, color=None, segs=6, sides=5):
    p0, p1 = Vector(p0), Vector(p1)
    pts = [p0.lerp(p1, i / segs) - Vector((0, 0, sag * 4 * (i / segs) * (1 - i / segs)))
           for i in range(segs + 1)]
    return tube(part, pts, r, color, sides)


def antenna(part, base, height, r=0.03, color=None, tip=None, segs=6):
    """Whip antenna with a base collar. tip=glow Part adds a lamp bead."""
    b = Vector(base)
    cyl(part, r * 2.5, r * 4, b + Vector((0, 0, r * 2)), color, segs=segs)
    rod(part, b, b + Vector((0, 0, height)), r, color, segs=5, r2=r * 0.6)
    if tip is not None:
        ico(tip, r * 2.2, b + Vector((0, 0, height)), subdiv=1)


def lamp(body, glow, loc, normal=(0, 0, 1), r=0.15, color=None, cage=True):
    """Recessed lamp: housing in `body`, lens in `glow` set inside the rim."""
    n = Vector(normal).normalized()
    o = Vector(loc)
    cyl(body, r * 1.3, r * 0.6, o + n * r * 0.3, color, orient(n), segs=10)
    torus(body, r * 1.05, r * 0.18, o + n * r * 0.62, color, orient(n), segs=10, csegs=4)
    cyl(glow, r * 0.9, r * 0.12, o + n * r * 0.62, rot=orient(n), segs=10, bevel=0)
    if cage:
        t1 = n.orthogonal().normalized()
        for t in (t1, n.cross(t1)):
            rod(body, o + n * r * 0.75 - t * r, o + n * r * 0.75 + t * r, r * 0.07, color, segs=4)


# =====================================================================
# COGWORK LEGION  (gunmetal, rust, brass; red lenses kept inside geometry)
# =====================================================================
def pipe(part, points, r, color="Copper", joint="Brass", sides=8):
    pts = [Vector(p) for p in points]
    tube(part, pts, r, color, sides)
    for p in pts[1:-1]:
        sphere(part, r * 1.3, p, joint, segs=sides)
    for p, q in ((pts[0], pts[1]), (pts[-1], pts[-2])):
        cyl(part, r * 1.6, r * 0.8, p, joint, orient(q - p), segs=sides)


def steam_boiler(part, r, length, loc, rot=AX_X, color="Rust", band_color="Brass",
                 bands=3, rivets=False, segs=14):
    """Domed boiler along local Z, centred on loc."""
    L = length / 2
    lathe(part, [(0, -L - r * 0.4), (r * 0.7, -L - r * 0.3), (r, -L), (r, L),
                 (r * 0.7, L + r * 0.3), (0, L + r * 0.4)], loc, color, rot, segs)
    f = frame(loc, rot)
    m = _rot(rot).to_matrix()
    for i in range(bands):
        z = -L + length * (i + 0.5) / bands
        cyl(part, r * 1.06, min(0.12, length * 0.06), f((0, 0, z)), band_color, rot, segs, bevel=0)
        if rivets:
            for k in range(segs // 2):
                a = 2 * pi * k / (segs // 2)
                radial = m @ Vector((cos(a), sin(a), 0))
                bolt(part, f((0, 0, z)) + radial * r * 1.06, radial, r * 0.07, band_color)


def gauge(part, loc, normal, r, rim="Brass", face="Ivory", needle="Oil"):
    n = Vector(normal).normalized()
    o, ro = Vector(loc), orient(n)
    t1 = n.orthogonal().normalized()
    cyl(part, r, r * 0.4, o, rim, ro, segs=12)
    cyl(part, r * 0.8, r * 0.1, o + n * r * 0.22, face, ro, segs=12, bevel=0)
    tip = o + n * r * 0.3 + (t1 * 0.55 + n.cross(t1) * 0.45).normalized() * r * 0.65
    rod(part, o + n * r * 0.3, tip, r * 0.08, needle, segs=4)


def handwheel(part, loc, normal, R, stem=0.12, color="Brass", stem_color="Gunmetal"):
    n = Vector(normal).normalized()
    o = Vector(loc)
    t1 = n.orthogonal().normalized()
    t2 = n.cross(t1)
    rod(part, o - n * stem, o, R * 0.15, stem_color, segs=6)
    torus(part, R, R * 0.13, o, color, orient(n), segs=12, csegs=4)
    for a in (0, pi / 3, 2 * pi / 3):
        t = t1 * cos(a) + t2 * sin(a)
        rod(part, o - t * R, o + t * R, R * 0.07, color, segs=4)


def whistle(part, loc, h=0.3, color="Brass"):
    x, y, z = loc
    cyl(part, 0.04, h, (x, y, z + h / 2), color, segs=8)
    cyl(part, 0.07, 0.18, (x, y, z + h + 0.09), color, segs=10, r2=0.05)


def piston(part, p0, p1, r, color="Gunmetal", rod_color="Steel", split=0.55, segs=8):
    """Hydraulic ram from p0 (cylinder end) to p1 (rod end) with eye caps."""
    p0, p1 = Vector(p0), Vector(p1)
    m = p0.lerp(p1, split)
    rod(part, p0, m, r, color, segs=segs)
    rod(part, m, p1, r * 0.5, rod_color, segs=max(5, segs - 2))
    cyl(part, r * 1.15, r * 0.4, m, color, orient(p1 - p0), segs=segs)
    for p in (p0, p1):
        sphere(part, r * 0.9, p, color, segs=6)


def smokestack(part, loc, r, h, color="Gunmetal", rim="Rust", glow=None, segs=12):
    x, y, z = loc
    cyl(part, r * 1.25, h * 0.08, (x, y, z + h * 0.04), rim, segs=segs)
    cyl(part, r, h, (x, y, z + h / 2), color, segs=segs, r2=r * 0.9)
    lathe(part, [(r * 0.85, z + h * 0.92), (r * 1.3, z + h * 1.02), (r * 1.15, z + h * 1.04),
                 (r * 0.7, z + h * 0.97), (0, z + h * 0.97)], (x, y, 0), rim, segs=segs)
    if glow is not None:
        cyl(glow, r * 0.68, 0.02, (x, y, z + h * 0.975), segs=segs, bevel=0)


def tread_assembly(part, length, radius, width, loc, wheels=5, color="Tread",
                   wheel_color="Gunmetal", cog_color="Brass", grouser_every=0.45):
    """Continuous track loop running along Y (model faces -Y), loc = loop centre.
    Low-tri belt + grouser bars, road wheels, front/rear cogs."""
    cx, cy, cz = loc
    L = length / 2 - radius
    pts, segs = [], 6
    for i in range(segs + 1):                      # rear arc (+Y)
        a = -pi / 2 + pi * i / segs
        pts.append((cy + L + radius * cos(a), cz + radius * sin(a)))
    for i in range(segs + 1):                      # front arc (-Y)
        a = pi / 2 + pi * i / segs
        pts.append((cy - L + radius * cos(a), cz + radius * sin(a)))
    rings = []
    for y, z in pts:
        nz = Vector((0, y - (cy + L if y > cy else cy - L), z - cz))
        out = nz.normalized() if nz.length > 1e-6 else Vector((0, 0, 1))
        inner = Vector((0, y, z)) - out * 0.12
        rings.append([(cx - width / 2, y, z), (cx + width / 2, y, z),
                      (cx + width / 2, inner.y, inner.z), (cx - width / 2, inner.y, inner.z)])
    loft(part, rings, color=color, closed=True)
    # grousers along the top and bottom runs
    n = max(2, int(2 * L / grouser_every))
    for i in range(n + 1):
        y = cy - L + 2 * L * i / n
        for z, s in ((cz + radius, 1), (cz - radius, -1)):
            box(part, (width * 0.95, 0.08, 0.06), (cx, y, z + s * 0.03), color, bevel=0)
    for i in range(wheels):
        y = cy - L + 2 * L * i / max(1, wheels - 1)
        cyl(part, radius * 0.72, width * 0.8, (cx, y, cz - radius * 0.2), wheel_color, AX_X,
            segs=12)
        cyl(part, radius * 0.3, width * 0.85, (cx, y, cz - radius * 0.2), cog_color, AX_X, segs=6)
    for y in (cy - L, cy + L):
        gear(part, radius * 0.95, radius * 0.78, 10, width * 0.6, (cx, y, cz), cog_color, AX_X,
             hub=radius * 0.3)


def cog_eye(body, glow, loc, normal=(0, -1, 0), r=0.2, color="GunmetalDark",
            rim="Gunmetal", hood=True, up=(0, 0, 1)):
    """Small recessed red lens: housing + socket rim in `body`, lens in `glow`
    set back inside the rim so the glow sits inside geometry."""
    n, o = Vector(normal).normalized(), Vector(loc)
    cyl(body, r * 1.45, r * 0.8, o - n * r * 0.4, color, orient(n), segs=12)
    torus(body, r * 0.95, r * 0.28, o + n * r * 0.15, rim, orient(n), segs=12, csegs=5)
    cyl(body, r * 0.7, r * 0.1, o - n * 0.0, "Lens", orient(n), segs=10, bevel=0)
    cyl(glow, r * 0.45, r * 0.12, o + n * r * 0.05, rot=orient(n), segs=10, bevel=0)
    if hood:
        u = Vector(up).normalized()
        box(body, (r * 3.0, r * 0.9, r * 0.25), o + u * r * 1.25 + n * r * 0.3, rim,
            basis(n.cross(u), u))


def cog_joint(part, loc, axis, r, w, color="Brass", cap="Gunmetal", teeth=10):
    """Cogwork style rule 1: a hinge / pivot / tilt mount shown as a brass gear on
    the joint axis, with an axle cap."""
    n = Vector(axis).normalized()
    gear(part, r, r * 0.8, teeth, w, loc, color, orient(n))
    cyl(part, r * 0.35, w * 1.6, loc, cap, orient(n), segs=8, bevel=0)


def gear_cluster(part, loc, rot=(0, 0, 0), R=1.0, color="Brass", hub="CogRed", t=0.12,
                 third=True, angle=-35.0):
    """Cogwork style rule 2: panel emblem of meshing brass gears with CogRed hubs.
    Lies in local XY on a surface facing +Z; loc = centre of the big gear's base."""
    f = frame(loc, rot)
    m = _rot(rot).to_matrix()
    spin = lambda a: (m @ Matrix.Rotation(a, 3, 'Z')).to_euler()
    gear(part, R, R * 0.8, 10, t, f((0, 0, t / 2)), color, rot)
    cyl(part, R * 0.3, t * 1.8, f((0, 0, t * 0.9)), hub, rot, segs=8, bevel=0)
    r2, a = R * 0.58, radians(angle)
    c2 = Vector((cos(a), sin(a), 0)) * (R * 0.9 + r2 * 0.92)
    gear(part, r2, r2 * 0.78, 7, t, f(c2 + Vector((0, 0, t / 2))), color, spin(pi / 7))
    cyl(part, r2 * 0.32, t * 1.8, f(c2 + Vector((0, 0, t * 0.9))), hub, rot, segs=6, bevel=0)
    if third:
        r3, a3 = R * 0.36, a + radians(70)
        c3 = c2 + Vector((cos(a3), sin(a3), 0)) * (r2 * 0.9 + r3 * 0.92)
        gear(part, r3, r3 * 0.76, 6, t, f(c3 + Vector((0, 0, t / 2))), color, spin(pi / 6))
        cyl(part, r3 * 0.35, t * 1.8, f(c3 + Vector((0, 0, t * 0.9))), hub, rot, segs=6, bevel=0)


def cog_mark(body, glow, loc, normal=(0, -1, 0), r=0.5, color="Brass", rim="GunmetalDark"):
    """Cogwork style rule 4: faction mark, a brass gear with a recessed red lens."""
    n, o = Vector(normal).normalized(), Vector(loc)
    gear(body, r, r * 0.8, 10, r * 0.2, o + n * r * 0.1, color, orient(n))
    torus(body, r * 0.42, r * 0.1, o + n * r * 0.3, rim, orient(n), segs=10, csegs=4)
    cyl(body, r * 0.45, r * 0.06, o + n * r * 0.22, "Lens", orient(n), segs=10, bevel=0)
    cyl(glow, r * 0.3, r * 0.05, o + n * r * 0.26, rot=orient(n), segs=10, bevel=0)


def visor_slot(body, glow, w, h, loc, normal=(0, -1, 0), up=(0, 0, 1), depth=None,
               lenses=0, color="GunmetalDark", frame_color="Gunmetal"):
    """Recessed horizontal visor slit. lenses=0: glowing strip; lenses=N: N small lenses."""
    n, u, o = Vector(normal).normalized(), Vector(up).normalized(), Vector(loc)
    side = u.cross(n).normalized()
    d = depth or h * 0.6
    rot = basis(side, n)
    fw = h * 0.35
    for c, sx, sy in ((u * (h / 2 + fw / 2), w + 2 * fw, fw), (-u * (h / 2 + fw / 2), w + 2 * fw, fw),
                      (side * (w / 2 + fw / 2), fw, h), (-side * (w / 2 + fw / 2), fw, h)):
        box(body, (sx, sy, d), o + c + n * d / 2, frame_color, rot)
    box(body, (w, h, d * 0.3), o + n * d * 0.15, color, rot, bevel=0)
    if lenses:
        for i in range(lenses):
            s = (i - (lenses - 1) / 2) * w / max(lenses, 1)
            cyl(glow, min(h * 0.35, w / lenses * 0.35), d * 0.15, o + side * s + n * d * 0.38,
                rot=orient(n), segs=8, bevel=0)
    else:
        box(glow, (w * 0.9, h * 0.35, d * 0.15), o + n * d * 0.38, rot=rot, bevel=0)


def armored_limb(part, p0, p1, w, color="Gunmetal", joint_color="GunmetalDark",
                 piston_color="Steel", taper=0.75):
    """Boxy armoured limb segment with a joint ball at p0 and a side ram."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    rot = basis(Vector((1, 0, 0)) if abs(d.normalized().x) < 0.9 else Vector((0, 1, 0)), d)
    taper_box(part, (w, w * 0.85), (w * taper, w * 0.85 * taper), 0, d.length * 0.92,
              color, loc=p0 + d.normalized() * d.length * 0.04, rot=rot)
    sphere(part, w * 0.55, p0, joint_color, segs=8)
    side = _rot(rot).to_matrix() @ Vector((1, 0, 0))
    piston(part, p0 + side * w * 0.6 + d * 0.15, p0 + side * w * 0.5 + d * 0.85, w * 0.12,
           joint_color, piston_color)


# =====================================================================
# SKITTER BROOD  (chitin, bone, goo weak spots)
# =====================================================================
def carapace(part, length, width, height, loc, segments=4, color="Chitin",
             ridge_color="ChitinLight", rot=(0, 0, 0), overlap=0.25, segs=10):
    """Shingled dome plates along local Y (front = -Y, smallest plate at back)."""
    f = frame(loc, rot)
    step = length / segments
    for i in range(segments):
        k = 1 - 0.12 * i
        y = -length / 2 + step * (i + 0.5)
        sx, sy, sz = width / 2 * k, step * (0.5 + overlap), height * k
        sphere(part, 1, f((0, y, 0)), color, segs, (sx, sy, sz), rot)
        box(part, (sx * 0.25, step * 0.9, sz * 0.12), f((0, y, sz * 0.97)), ridge_color, rot)


def bug_leg(part, points, r0, r1=None, color="ChitinMid", knuckle="Chitin",
            claw="Claw", spikes=True, sides=6):
    """Segmented leg through points (hip -> foot) with knuckles, spikes and a claw."""
    pts = [Vector(p) for p in points]
    r1 = r1 if r1 is not None else r0 * 0.35
    n = len(pts)
    rs = [r0 + (r1 - r0) * i / (n - 1) for i in range(n)]
    for i in range(n - 1):
        tube(part, [pts[i], pts[i + 1]], [rs[i], rs[i + 1] * 1.1], color, sides)
        if i > 0:
            sphere(part, rs[i] * 1.25, pts[i], knuckle, segs=8)
        if spikes and i < n - 2:
            m = pts[i].lerp(pts[i + 1], 0.5)
            d = pts[i + 1] - pts[i]
            up = d.cross(Vector((0, 0, 1))).cross(d).normalized()
            if up.length < 0.1:
                up = Vector((0, 0, 1))
            spike(part, m, up + d.normalized() * 0.4, rs[i] * 1.6, rs[i] * 0.4, claw)
    spike(part, pts[-1], pts[-1] - pts[-2], rs[-1] * 4, rs[-1] * 1.1, claw)


def spike(part, base, direction, length, r, color=None, segs=5):
    d = Vector(direction).normalized()
    return lathe(part, [(r, 0), (r * 0.5, length * 0.6), (0, length)], base, color,
                 orient(d), segs)


def mandible(part, base, length, side=1, r=0.15, color="Bone", tip="Claw", curl=0.6,
             forward=(0, -1, 0)):
    """Curved pincer from base, sweeping forward and curling toward the centre
    (side=+1 on the +X side, -1 on the -X side)."""
    b, fw = Vector(base), Vector(forward).normalized()
    inward = Vector((-side, 0, 0))
    pts = [b + fw * length * t + inward * length * curl * t * t * 0.6 for t in (0, .35, .7, 1)]
    tube(part, pts, [r, r * 0.9, r * 0.6, r * 0.25], color, 6)
    spike(part, pts[-1], pts[-1] - pts[-2], r * 1.2, r * 0.3, tip)


def goo_sac(glow, loc, r, seed=None, scale=(1, 1, 1)):
    """Lumpy glowing weak spot (use a kit.glow(..., role='weak') part)."""
    return ico(glow, r, loc, subdiv=1, scale=scale, jitter=0.15, seed=seed)


def egg(part, loc, r, h=None, color="Membrane", segs=10, tilt=(0, 0, 0)):
    h = h or r * 2.6
    return lathe(part, [(0, 0), (r * 0.8, h * 0.08), (r, h * 0.35), (r * 0.75, h * 0.8),
                        (0, h)], loc, color, tilt, segs)


def ribs(part, loc, count, R, thick, length, color="Bone", rot=(0, 0, 0), arc=pi * 0.9):
    """Row of arching ribs along local Y (bug skeletons, hive ribbing)."""
    f = frame(loc, rot)
    for i in range(count):
        y = -length / 2 + length * i / max(1, count - 1)
        k = 1 - abs(y) / length * 0.6
        arch = Matrix.Rotation(pi / 2, 3, 'X') @ Matrix.Rotation((pi - arc) / 2, 3, 'Z')
        torus(part, R * k, thick, f((0, y, 0)), color, _rot(rot).to_matrix() @ arch,
              segs=10, csegs=4, arc=arc)


# =====================================================================
# LUMEN CONCORD  (pearl ceramic plates, gold trim, violet hard light)
# =====================================================================
def ceramic_plate(part, w, h, loc, rot=(0, 0, 0), curve=0.25, t=0.08, taper=0.6,
                  color="Pearl", segs=5, bevel=0.02):
    """Curved shard plate: arc across local X (bulging +Z), height along local Y,
    top edge narrowed by `taper`."""
    def section(y, sx):
        outer = [(sx * (-w / 2 + w * i / segs), y,
                  curve * (1 - (2 * i / segs - 1) ** 2) + t / 2) for i in range(segs + 1)]
        inner = [(x, y, z - t) for x, y, z in reversed(outer)]
        return outer + inner
    return loft(part, [section(-h / 2, 1.0), section(h / 2, taper)], loc, color, rot,
                bevel=bevel)


def crystal(part, base, direction, length, r, color="Crystal", sides=6, tip=0.25,
            jitter=0.1, seed=None):
    """Faceted crystal growing from base along direction."""
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    j = lambda v: v * (1 + rng.uniform(-jitter, jitter))
    prof = [(j(r * 0.7), 0), (j(r), length * 0.12), (j(r * 0.9), length * (1 - tip)), (0, length)]
    return lathe(part, prof, base, color, orient(direction), sides, twist=rng.uniform(0, 0.3))


def crystal_cluster(part, loc, count, size, colors=("Crystal", "CrystalDark", "Lilac"),
                    spread=0.5, seed=None):
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    o = Vector(loc)
    for i in range(count):
        a = rng.uniform(0, 2 * pi)
        lean = rng.uniform(0.1, 0.6) if i else 0.05
        d = Vector((cos(a) * lean, sin(a) * lean, 1))
        ln = size * rng.uniform(0.45, 1.0) * (1.0 if i == 0 else 0.8)
        b = o + Vector((cos(a), sin(a), 0)) * size * spread * rng.uniform(0, 0.5) * (i > 0)
        crystal(part, b, d, ln, ln * rng.uniform(0.12, 0.2), colors[i % len(colors)],
                sides=rng.choice((5, 6)), seed=rng.random())


def hardlight_ring(glow, R, r, loc, rot=(0, 0, 0), gaps=3, gap_frac=0.3, segs=24):
    """Broken floating ring of hard light (glow part)."""
    arc = 2 * pi / gaps * (1 - gap_frac)
    m = _rot(rot).to_matrix()
    for i in range(gaps):
        a0 = 2 * pi * i / gaps
        torus(glow, R, r, loc, rot=m @ Matrix.Rotation(a0, 3, 'Z'),
              segs=max(3, segs // gaps), csegs=4, arc=arc)


def energy_core(glow, loc, r, subdiv=1, scale=(1, 1, 1)):
    return ico(glow, r, loc, subdiv=subdiv, scale=scale)


def fin_blade(part, length, width, loc, rot=(0, 0, 0), t=0.08, sweep=0.3, color="Pearl",
              bevel=0.015):
    """Leaf/blade fin in local XZ (span along +Z), thickness along Y."""
    prof = [(0, 0), (width * 0.5, length * 0.15), (width * 0.35 + sweep, length * 0.7),
            (sweep, length), (-width * 0.25 + sweep * 0.6, length * 0.6), (-width * 0.3, length * 0.12)]
    return extrude(part, prof, t, loc, color, rot, plane='XZ', bevel=bevel)


def trim_band(part, R, loc, rot=(0, 0, 0), h=0.08, t=0.05, color="Gold", segs=12, arc=2 * pi):
    """Thin gold trim ring around local Z."""
    return torus(part, R, max(h, t) / 2, loc, color, rot, segs, 4, arc)


# =====================================================================
# HUMAN / SQUAD / CAMP PROPS
# =====================================================================
def crate(part, size, loc, color="Olive", trim="CharcoalDark", latch="Steel",
          mark="Stencil", rot=(0, 0, 0), handles=True):
    """Military crate; loc is the bottom centre. Front = -Y local."""
    sx, sy, sz = size
    f = frame(loc, rot)
    box(part, (sx, sy, sz), f((0, 0, sz / 2)), color, rot)
    e = min(sx, sy, sz) * 0.08
    for x in (-1, 1):
        for y in (-1, 1):
            box(part, (e * 2, e * 2, sz * 1.01), f((x * (sx / 2 - e * 0.6), y * (sy / 2 - e * 0.6),
                                                    sz / 2)), trim, rot)
    for z in (e, sz - e):
        box(part, (sx * 1.02, sy * 1.02, e * 1.6), f((0, 0, z)), trim, rot)
    strip(part, f((-sx / 2 + e * 2, -sy / 2, sz * 0.78)), f((sx / 2 - e * 2, -sy / 2, sz * 0.78)),
          _rot(rot).to_matrix() @ Vector((0, -1, 0)), e * 0.5, e * 0.3, trim)
    fr = _rot(rot).to_matrix() @ Euler((pi / 2, 0, 0)).to_matrix()
    for x in (-sx * 0.3, sx * 0.3):
        box(part, (e * 1.6, e * 0.8, e * 2.4), f((x, -sy / 2 - e * 0.4, sz * 0.78)), latch, rot)
    stencil_panel(part, sx * 0.4, sz * 0.32, f((0, -sy / 2 - e * 0.2, sz * 0.42)), fr, color, mark,
                  t=e * 0.5)
    if handles:
        for x in (-1, 1):
            box(part, (e * 0.8, sy * 0.35, e * 0.8), f((x * (sx / 2 + e * 0.6), 0, sz * 0.65)),
                trim, rot)


def sandbag(part, loc, rot=(0, 0, 0), size=(1.6, 0.8, 0.45), color="Sandbag", segs=8):
    """Low-tri pillow (~56 tris). loc = bottom centre."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=4, radius=1)
    for v in bm.verts:
        v.co.z = max(-0.75, min(0.75, v.co.z))
        v.co.x *= size[0] / 2
        v.co.y *= size[1] / 2
        v.co.z = (v.co.z + 0.75) / 1.5 * size[2]
    return _add(part, bm, loc, rot, color)


def sandbag_wall(part, length, rows=3, loc=(0, 0, 0), rot=(0, 0, 0), arc=0.0,
                 bag=(1.6, 0.8, 0.45), color="Sandbag", seed=None):
    """Staggered sandbag wall along local X. arc (radians) bends it into a curve."""
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    f = frame(loc, rot)
    base_r = _rot(rot).to_matrix()
    per = max(1, round(length / (bag[0] * 0.92)))
    for row in range(rows):
        n = per - (row % 2)
        for i in range(n):
            t = (i + 0.5 + 0.5 * (row % 2)) / per - 0.5
            if arc:
                R = length / arc
                a = t * arc
                p = (R * sin(a), R * (1 - cos(a)), row * bag[2] * 0.85)
                yaw = a
            else:
                p, yaw = (t * length, 0, row * bag[2] * 0.85), 0
            jit = Matrix.Rotation(yaw + rng.uniform(-0.06, 0.06), 3, 'Z')
            sandbag(part, f(p), base_r @ jit, bag, color)


def nozzle(body, glow, loc, direction, r, length, color="Charcoal", inner="Black", segs=10):
    """Thruster bell pointing along direction (exhaust out), glow set inside the bell."""
    d = Vector(direction).normalized()
    lathe(body, [(0, -length * 0.1), (r * 0.6, -length * 0.1), (r * 0.55, 0), (r, length),
                 (r * 0.85, length), (r * 0.45, length * 0.18), (0, length * 0.18)],
          loc, color, orient(d), segs=segs)
    cyl(glow, r * 0.42, 0.02, Vector(loc) + d * length * 0.2, rot=orient(d), segs=segs, bevel=0)


def fin(part, root, tip, span, loc, rot=(0, 0, 0), sweep=None, t=0.1, color=None):
    """Trapezoid fin in local XZ (span along +Z), thickness along Y."""
    sw = root - tip if sweep is None else sweep
    prof = [(0, 0), (root, 0), (sw + tip, span), (sw, span)]
    return extrude(part, prof, t, loc, color, rot, plane='XZ')


def hatch(part, w, h, loc, rot=(0, 0, 0), color=None, hinge_color=None, handle_color=None):
    """Door/hatch panel (local XY, facing +Z) with hinges on -X edge and a handle."""
    f = frame(loc, rot)
    plate(part, w, h, 0.06, loc, rot, color, chamfer=0.1)
    m = _rot(rot).to_matrix()
    ax = m @ Euler((pi / 2, 0, 0)).to_matrix()
    for y in (-h * 0.3, h * 0.3):
        cyl(part, 0.06, h * 0.18, f((-w / 2, y, 0.03)), hinge_color, ax, segs=8)
    box(part, (0.08, h * 0.25, 0.08), f((w * 0.35, 0, 0.1)), handle_color, rot)


# =====================================================================
# TERRAIN  (rocks, fins, strata)
# =====================================================================
def rock(part, size, loc, color="Rock", seed=None, jag=0.25, subdiv=1, flat_base=True,
         rot=(0, 0, 0)):
    """Faceted boulder; loc = bottom centre. subdiv 1 = 80 tris (rubble-safe)."""
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    off = Vector((rng.uniform(-50, 50), rng.uniform(-50, 50), rng.uniform(-50, 50)))
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1)
    for v in bm.verts:
        v.co *= 1 + jag * noise.noise(v.co * 1.7 + off) + rng.uniform(-jag, jag) * 0.4
        v.co = Vector((v.co.x * size[0] / 2, v.co.y * size[1] / 2,
                       (v.co.z * 0.5 + 0.5) * size[2]))
        if flat_base:
            v.co.z = max(v.co.z, size[2] * 0.08)
    lo = min(v.co.z for v in bm.verts)
    for v in bm.verts:
        v.co.z -= lo
    return _add(part, bm, loc, rot, color)


def rock_fin(part, height, width, thickness, loc, lean=(0.25, 0.0), colors=("Rock", "RockDark"),
             layers=5, sides=7, seed=None, top_jag=0.25):
    """Jagged leaning rock fin built from stacked strata. loc = base centre.
    lean = (x, y) horizontal drift at the top as a fraction of height."""
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    o = Vector(loc)
    radii = [rng.uniform(0.75, 1.15) for _ in range(sides)]
    angs = [2 * pi * i / sides + rng.uniform(-0.25, 0.25) for i in range(sides)]

    def ring(k, z):
        s = 1 - 0.55 * (k / layers) ** 1.3
        c = o + Vector((lean[0] * z, lean[1] * z, 0)) * 1.0
        return [c + Vector((cos(a) * width / 2 * s * rr * rng.uniform(0.92, 1.08),
                            sin(a) * thickness / 2 * s * rr * rng.uniform(0.92, 1.08), z))
                for a, rr in zip(angs, radii)]
    zs = [height * (k / layers) ** 0.9 for k in range(layers + 1)]
    for k in range(layers):
        bot = ring(k, zs[k])
        top = ring(k + 1, zs[k + 1])
        ledge = rng.uniform(0.97, 1.08)
        cen = sum((Vector(p) for p in top), Vector()) / sides
        top = [cen + (Vector(p) - cen) * ledge for p in top]
        if k == layers - 1:   # broken, jagged crown
            top = [Vector(p) + Vector((0, 0, rng.uniform(-top_jag, top_jag * 0.6) * height / layers))
                   for p in top]
        loft(part, [bot, top], color=colors[k % len(colors)])


def strata_block(part, size, loc, layers=4, colors=("Rock", "Strata", "RockLight"), seed=None,
                 jitter=0.12, rot=(0, 0, 0)):
    """Layered mesa block (stacked irregular slabs). loc = bottom centre."""
    rng = random.Random(part.kit.rng.random() if seed is None else seed)
    f = frame(loc, rot)
    sx, sy, sz = size
    h = sz / layers
    for k in range(layers):
        s = 1 - 0.06 * k + rng.uniform(-jitter, jitter) * 0.5
        taper_box(part, (sx * s, sy * s), (sx * s * 0.96, sy * s * 0.96), 0, h * 1.02,
                  colors[k % len(colors)],
                  top_offset=(rng.uniform(-0.03, 0.03) * sx, rng.uniform(-0.03, 0.03) * sy),
                  loc=f((rng.uniform(-jitter, jitter) * sx * 0.1, 0, k * h)), rot=rot,
                  bevel=h * 0.08)


# =====================================================================
# LINEUP  (category sheet from existing previews)
# =====================================================================
def lineup(keys, name, root=None):
    """Stitch art/previews/<key>.png side by side into art/previews/lineup_<name>.png."""
    import numpy as np
    root = root or os.environ.get("ORBITFALL_ROOT") or os.path.dirname(os.path.abspath(__file__))
    imgs = [bpy.data.images.load(os.path.join(root, "art", "previews", f"{k}.png"))
            for k in keys]
    w, h = imgs[0].size
    out = bpy.data.images.new(f"lineup_{name}", w * len(imgs), h, alpha=False)
    big = np.zeros((h, w * len(imgs), 4), dtype=np.float32)
    for i, im in enumerate(imgs):
        a = np.empty(w * h * 4, dtype=np.float32)
        im.pixels.foreach_get(a)
        big[:, i * w:(i + 1) * w] = a.reshape(h, w, 4)
    out.pixels.foreach_set(big.ravel())
    path = os.path.join(root, "art", "previews", f"lineup_{name}.png")
    out.filepath_raw, out.file_format = path, 'PNG'
    out.save()
    return path
