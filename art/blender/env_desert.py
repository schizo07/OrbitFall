"""Dustbowl Ridge desert kit: rounded, chunky cartoon sandstone (look pass, 2026-11-18).

Rocks are smooth-shaded blobs shaped by a few flat cuts (big readable planes with soft edges) and stepped sandstone
layers. Colour comes from one gradient texture: U = how much a vertex faces up (side -> sun-bleached top),
V = height in studs (horizontal rock layers, so the bands stay straight whatever the triangles do).

Headless:  Blender -b --python env_desert.py -- --out <folder> [--export] [--only key,key]
"""
import os
import sys
import math
import random

import bpy
import bmesh
from mathutils import Vector, noise

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------------------------------------------------
# texture: x = topness (0 side .. 1 top), y = height (0 .. BAND_H studs)
TEX_W, TEX_H = 64, 256
BAND_H = 48.0  # studs covered by the texture's height

TOP = (0xD2, 0xB0, 0x84)  # sun-bleached sand on top faces
LAYERS = [  # (thickness in studs, colour, ledge: +1 sticks out / -1 tucks in) bottom-up, repeated
    (3.4, (0xA8, 0x68, 0x46), 1),
    (1.1, (0x8A, 0x52, 0x3A), -1),
    (4.2, (0xB2, 0x74, 0x50), 1),
    (0.8, (0x93, 0x58, 0x3D), -1),
    (2.6, (0xBA, 0x80, 0x5A), 1),
    (1.4, (0x9A, 0x60, 0x42), -1),
]
BASE_DUST = (0xB0, 0x8A, 0x62)  # the bottom stud picks up ground dust


def _lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def layer_at(z):
    period = sum(t for t, _, _ in LAYERS)
    z = z % period
    for t, col, _ in LAYERS:
        if z < t:
            return col
        z -= t
    return LAYERS[-1][1]


def layer_bounds(top):
    """Every layer boundary height from 0 to `top`, with its ledge flag below/above."""
    out, z, i = [], 0.0, 0
    while z < top:
        t, _, led = LAYERS[i % len(LAYERS)]
        out.append((z, led))
        z += t
        i += 1
    return out


def ledge_of(z):
    period = sum(t for t, _, _ in LAYERS)
    zz = z % period
    for t, _, led in LAYERS:
        if zz < t:
            return led, zz, t
        zz -= t
    return 0, 0, 1


def make_texture(name="desert_rock"):
    img = bpy.data.images.get(name)
    if img:
        bpy.data.images.remove(img)
    img = bpy.data.images.new(name, TEX_W, TEX_H, alpha=False)
    img.colorspace_settings.name = "sRGB"
    px = []
    for y in range(TEX_H):  # Blender rows start at the bottom
        z = (y + 0.5) / TEX_H * BAND_H
        side = layer_at(z)
        if z < 1.0:
            k = 1 - z
            side = tuple(s + (d - s) * k * 0.6 for s, d in zip(side, BASE_DUST))
        for x in range(TEX_W):
            t = (x + 0.5) / TEX_W
            k = min(1.0, max(0.0, (t - 0.72) / 0.14))  # side below 0.72, top above 0.86
            k = k * k * (3 - 2 * k)
            c = tuple(s + (tp - s) * k for s, tp in zip(side, TOP))
            px.extend((c[0] / 255, c[1] / 255, c[2] / 255, 1.0))
    img.pixels[:] = px
    return img


# --------------------------------------------------------------------------------------------------------------------
# shape helpers (all work on a bmesh in place)

def blob(subdiv=3):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    return bm


def ellipsoid(bm, sx, sy, sz):
    for v in bm.verts:
        v.co = Vector((v.co.x * sx, v.co.y * sy, v.co.z * sz))


def wobble(bm, amp, freq, seed):
    off = Vector((seed * 13.1, seed * 7.7, seed * 3.3))
    for v in bm.verts:
        n = noise.noise(v.co * freq + off)
        d = v.co.copy()
        d.z *= 0.3  # mostly push sideways: keeps tops flat-ish
        if d.length > 1e-6:
            v.co += d.normalized() * n * amp


def cut(bm, normal, dist, hard=0.9):
    """Flatten everything past the plane (normal . p > dist) toward it: a big chunky facet."""
    n = Vector(normal).normalized()
    for v in bm.verts:
        d = v.co.dot(n) - dist
        if d > 0:
            v.co -= n * d * hard


def random_cuts(bm, rng, count, reach, tilt=(0.1, 0.45)):
    """`count` side facets around the rock, each cut at `reach` (0..1) of the vertex extent in its direction."""
    a0 = rng.uniform(0, math.tau)
    for i in range(count):
        a = a0 + i * math.tau / count + rng.uniform(-0.35, 0.35)
        nz = rng.uniform(*tilt)
        n = Vector((math.cos(a), math.sin(a), nz)).normalized()
        ext = max(v.co.dot(n) for v in bm.verts)
        cut(bm, n, ext * rng.uniform(reach - 0.06, reach + 0.04))


def flat_top(bm, z, keep=0.12):
    for v in bm.verts:
        if v.co.z > z:
            v.co.z = z + (v.co.z - z) * keep


def flat_bottom(bm, z=-0.6):
    for v in bm.verts:
        if v.co.z < z:
            v.co.z = z


def ledges(bm, depth, axis_half=0.0, ramp=0.45):
    """Sandstone layers: hard layers stick out, soft ones tuck in, matching the texture's bands.
    Pushes sideways from the piece's centre line (a segment along X of half-length axis_half)."""
    for v in bm.verts:
        cx = max(-axis_half, min(axis_half, v.co.x))
        r = Vector((v.co.x - cx, v.co.y, 0))
        if r.length < 1e-4 or v.co.z < 0.3:
            continue
        led, zz, t = ledge_of(v.co.z)
        # soften the step over `ramp` studs at the bottom of each layer
        k = min(1.0, zz / ramp) if t > ramp else 1.0
        prev = ledge_of(v.co.z - zz - 0.01)[0]
        amt = prev + (led - prev) * (k * k * (3 - 2 * k))
        patch = 0.5 + 0.5 * noise.noise(Vector((v.co.x * 0.09, v.co.y * 0.09, v.co.z * 0.02 + 5.0)))
        v.co += r.normalized() * amt * depth * (0.25 + 0.75 * patch)


def add_loops(bm, top):
    """Edge loops at every layer boundary (and just above it) so the ledges get crisp steps."""
    for z, _ in layer_bounds(top):
        for zz in (z,):
            if zz <= 0.05:
                continue
            geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
            bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, zz), plane_no=(0, 0, 1))


def smooth(bm, times=2, factor=0.5):
    for _ in range(times):
        bmesh.ops.smooth_vert(bm, verts=bm.verts, factor=factor, use_axis_x=True, use_axis_y=True, use_axis_z=True)


def merge(dst, src, offset=(0, 0, 0), rot=0.0):
    """Append src's geometry into dst (overlapping shells are fine for a rock)."""
    me = bpy.data.meshes.new("_m")
    src.to_mesh(me)
    src.free()
    c, s = math.cos(rot), math.sin(rot)
    for v in me.vertices:
        x, y = v.co.x, v.co.y
        v.co = Vector((x * c - y * s + offset[0], x * s + y * c + offset[1], v.co.z + offset[2]))
    dst.from_mesh(me)
    bpy.data.meshes.remove(me)


def rounded_box(cuts, sx, sy, sz, round_=0.35):
    """A subdivided cube pulled toward a sphere (soft corners), scaled to sx, sy, sz with its base at z = 0."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    for v in bm.verts:
        v.co = v.co.lerp(v.co.normalized() * 0.62, round_)
    for v in bm.verts:
        v.co = Vector((v.co.x * sx, v.co.y * sy, (v.co.z + 0.5) * sz))
    return bm


def chunk(rng, seed, sx, sy, sz, cuts=6, facets=6, reach=0.8, tilt=(0.05, 0.4)):
    """One chunky stone: rounded box, wobbled, sliced by big facets."""
    bm = rounded_box(cuts, sx, sy, sz, 0.45)
    wobble(bm, min(sx, sy) * 0.08, 0.6 / max(1.0, min(sx, sy) * 0.25), seed)
    for v in bm.verts:
        v.co.z -= sz * 0.5
    random_cuts(bm, rng, facets, reach, tilt)
    top = Vector((rng.uniform(-0.25, 0.25), rng.uniform(-0.25, 0.25), 1)).normalized()
    cut(bm, top, max(v.co.dot(top) for v in bm.verts) * rng.uniform(0.78, 0.88), 1.0)
    for v in bm.verts:
        v.co.z += sz * 0.5
    return bm


# --------------------------------------------------------------------------------------------------------------------
# the rocks (Blender units = studs; z up; base at z = 0, sinks are done in game)

def boulder(seed=1, w=10.0, d=8.0, h=6.5):
    """Chunky boulder: a big faceted stone with a smaller one leaning on it."""
    rng = random.Random(seed)
    bm = chunk(rng, seed, w, d, h, cuts=6, facets=rng.choice((5, 6, 7)), reach=0.78)
    s = rng.uniform(0.42, 0.55)
    side = chunk(rng, seed + 50, w * s, d * s, h * s * 1.1, cuts=4, facets=5, reach=0.8)
    a = rng.uniform(0, math.tau)
    merge(bm, side, (math.cos(a) * w * 0.42, math.sin(a) * d * 0.42, -h * 0.08), rng.uniform(0, math.tau))
    flat_bottom(bm, 0.0)
    smooth(bm, 1, 0.45)
    return bm


def butte(seed=2, w=12.0, d=10.0, h=11.0):
    """Small flat-topped sandstone stack: one tall faceted chunk with layer ledges."""
    rng = random.Random(seed)
    bm = rounded_box(7, w, d, h, 0.3)
    wobble(bm, 0.6, 0.12, seed)
    random_cuts(bm, rng, 5, 0.86, tilt=(0.0, 0.15))
    flat_top(bm, h * 0.93, 0.05)
    flat_bottom(bm, 0.0)
    add_loops(bm, h)
    ledges(bm, 0.3)
    smooth(bm, 1, 0.3)
    return bm


def cliff(seed=3, length=40.0, depth=14.0, h=24.0):
    """Cliff / mesa wall piece: 3-4 tall faceted columns side by side, uneven tops, layer ledges."""
    rng = random.Random(seed)
    bm = bmesh.new()
    n = 3
    x = -length / 2
    for i in range(n):
        cw = length / n * rng.uniform(1.2, 1.6)
        ch = h * (1.0 if i == 1 else rng.uniform(0.62, 0.86))
        cd = depth * rng.uniform(0.75, 1.0)
        c = rounded_box(5, cw, cd, ch, 0.18)
        wobble(c, 0.7, 0.1, seed * 10 + i)
        for k in range(6):
            a = -math.pi / 2 + rng.uniform(-1.3, 1.3) if k < 4 else rng.uniform(0, math.tau)
            nrm = Vector((math.cos(a), math.sin(a), rng.uniform(-0.15, 0.35))).normalized()
            ext = max(v.co.dot(nrm) for v in c.verts)
            cut(c, nrm, ext * rng.uniform(0.8, 0.9), 1.0)
        flat_top(c, ch * rng.uniform(0.9, 0.96), 0.05)
        merge(bm, c, (x + length / n * (i + 0.5), rng.uniform(-2.5, 2.5), 0), rng.uniform(-0.2, 0.2))
    flat_bottom(bm, 0.0)
    add_loops(bm, h)
    ledges(bm, 0.3, axis_half=length / 2 - depth / 2)
    smooth(bm, 1, 0.3)
    return bm


def pebbles(seed=4):
    """3-5 small chunky stones in a clump (ground dressing)."""
    rng = random.Random(seed)
    out = bmesh.new()
    n = rng.randint(3, 5)
    for i in range(n):
        s = rng.uniform(1.2, 2.4) if i else 3.0
        b = chunk(rng, seed * 10 + i, s * 2, s * 1.7, s * 1.2, cuts=3, facets=5, reach=0.8)
        a = rng.uniform(0, math.tau)
        r = 0 if i == 0 else rng.uniform(2.8, 4.4)
        merge(out, b, (math.cos(a) * r, math.sin(a) * r, -s * 0.15), rng.uniform(0, math.tau))
    flat_bottom(out, 0.0)
    smooth(out, 1, 0.4)
    return out


ROCKS = {
    "desert_boulder_a": lambda: boulder(1, 10, 8, 6.5),
    "desert_boulder_b": lambda: boulder(7, 7, 6.5, 6.0),
    "desert_butte": lambda: butte(2),
    "desert_cliff": lambda: cliff(3),
    "desert_pebbles": lambda: pebbles(4),
}


# --------------------------------------------------------------------------------------------------------------------
# object + material

def rock_material(img):
    m = bpy.data.materials.get("desert_rock") or bpy.data.materials.new("desert_rock")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    tex = next((n for n in nt.nodes if n.type == "TEX_IMAGE"), None) or nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Linear"
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.92
    bsdf.inputs["Metallic"].default_value = 0.0
    m["roblox_material"] = "SmoothPlastic"
    return m


def to_object(key, bm, mat, collection):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.normal_update()
    lo = min(v.co.z for v in bm.verts)
    # centre on X/Y, base at z = 0
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    shift = Vector((-(min(xs) + max(xs)) / 2, -(min(ys) + max(ys)) / 2, -lo))
    bmesh.ops.translate(bm, vec=shift, verts=bm.verts)
    bm.normal_update()
    ngons = [f for f in bm.faces if len(f.verts) > 4]
    if ngons:
        bmesh.ops.triangulate(bm, faces=ngons, quad_method="BEAUTY", ngon_method="EAR_CLIP")
    uv = bm.loops.layers.uv.new("UVMap")
    for f in bm.faces:
        f.smooth = True
        for lp in f.loops:
            v = lp.vert
            up = max(0.0, min(1.0, v.normal.z))
            lp[uv].uv = (0.05 + up * 0.9, min(0.995, max(0.005, v.co.z / BAND_H)))
    me = bpy.data.meshes.new(key)
    bm.to_mesh(me)
    tris = sum(len(f.verts) - 2 for f in bm.faces)
    bm.free()
    me.materials.append(mat)
    ob = bpy.data.objects.new(key, me)
    collection.objects.link(ob)
    ob["roblox_material"] = "SmoothPlastic"
    return ob, tris


def reset():
    for ob in list(bpy.data.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    for c in list(bpy.data.collections):
        bpy.data.collections.remove(c)
    for coll in (bpy.data.meshes, bpy.data.materials, bpy.data.images, bpy.data.cameras, bpy.data.lights):
        for b in list(coll):
            if b.users == 0:
                coll.remove(b)


def build(keys, fresh=True):
    if fresh:
        reset()
    col = bpy.data.collections.new("desert")
    bpy.context.scene.collection.children.link(col)
    img = make_texture()
    mat = rock_material(img)
    objs = {}
    for k in keys:
        ob, tris = to_object(k, ROCKS[k](), mat, col)
        objs[k] = (ob, tris)
    bpy.context.view_layer.update()
    return objs, img


# --------------------------------------------------------------------------------------------------------------------
# preview render

GROUND = (0xC9, 0xA4, 0x76)


def stage(out_png, objs, cam_dir=(0.3, -1.0, 0.38), size=(1800, 900), lens=40, gap=4.0, target=None, zoom=1.0):
    sc = bpy.context.scene
    col = bpy.data.collections.new("_stage")
    sc.collection.children.link(col)
    x = 0.0
    lo_all, hi_all = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    for ob in objs:
        bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
        w = max(p.x for p in bb) - min(p.x for p in bb)
        ob.location.x += x - min(p.x for p in bb)
        x += w + gap
        bpy.context.view_layer.update()
        bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
        for p in bb:
            lo_all = Vector([min(a, b) for a, b in zip(lo_all, p)])
            hi_all = Vector([max(a, b) for a, b in zip(hi_all, p)])
    me = bpy.data.meshes.new("_ground")
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=600)
    bm.to_mesh(me)
    bm.free()
    g = bpy.data.objects.new("_ground", me)
    g.location = ((lo_all.x + hi_all.x) / 2, 0, -0.3)
    gm = bpy.data.materials.new("_ground")
    gm.use_nodes = True
    gb = gm.node_tree.nodes.get("Principled BSDF")
    gb.inputs["Base Color"].default_value = (*(_lin(c) for c in GROUND), 1)
    gb.inputs["Roughness"].default_value = 1.0
    me.materials.append(gm)
    col.objects.link(g)
    for name, rot, energy, ang in (("_sun", (math.radians(50), 0, math.radians(-25)), 4.2, 2.0),
                                   ("_fill", (math.radians(70), 0, math.radians(160)), 0.9, 25.0)):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy, ld.angle = energy, math.radians(ang)
        ld.color = (1.0, 0.95, 0.86) if name == "_sun" else (0.75, 0.82, 1.0)
        o = bpy.data.objects.new(name, ld)
        o.rotation_euler = rot
        col.objects.link(o)
    world = sc.world or bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (_lin(0xD8), _lin(0xBC), _lin(0x98), 1)
    bg.inputs[1].default_value = 0.8
    camd = bpy.data.cameras.new("_cam")
    camd.lens = lens
    cam = bpy.data.objects.new("_cam", camd)
    col.objects.link(cam)
    sc.camera = cam
    ctr = Vector(target) if target else (lo_all + hi_all) / 2
    half_w = (hi_all.x - lo_all.x) / 2
    half_h = (hi_all.z - lo_all.z) / 2
    dist = max(half_w / 0.42, half_h / 0.21, 6) * 1.05 / zoom
    d = Vector(cam_dir).normalized()
    cam.location = ctr + d * dist
    cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
    camd.clip_start, camd.clip_end = 0.1, dist * 8
    r = sc.render
    r.resolution_x, r.resolution_y = size
    r.resolution_percentage = 100
    r.image_settings.file_format = "PNG"
    sc.view_settings.view_transform = "Standard"
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
        try:
            r.engine = eng
            break
        except Exception:
            pass
    try:
        sc.eevee.use_shadows = True
    except Exception:
        pass
    r.filepath = out_png
    bpy.ops.render.render(write_still=True)
    print("RENDERED", out_png)
    return out_png


# --------------------------------------------------------------------------------------------------------------------
# export (one model per clean scene; 1 BU = 1 stud)

FBX = dict(axis_forward="Z", axis_up="Y", bake_space_transform=True, global_scale=1.0, apply_unit_scale=True,
           apply_scale_options="FBX_SCALE_ALL", mesh_smooth_type="FACE", use_mesh_modifiers=True,
           use_custom_props=True, path_mode="COPY", embed_textures=True, add_leaf_bones=False, bake_anim=False)


def export(out, keys):
    os.makedirs(out, exist_ok=True)
    info = {}
    for k in keys:
        objs, img = build([k])
        ob, tris = objs[k]
        # the game tints rocks per biome (MapBuilder rockTint + rockMat): ship them untextured
        plain = bpy.data.materials.new("rock_plain")
        plain.use_nodes = True
        ob.data.materials.clear()
        ob.data.materials.append(plain)
        bpy.ops.object.select_all(action="DESELECT")
        ob.select_set(True)
        path = os.path.join(out, f"{k}.fbx")
        bpy.ops.export_scene.fbx(filepath=path, use_selection=True, object_types={"MESH"}, **FBX)
        d = ob.dimensions
        info[k] = {"tris": tris, "size_roblox": [round(d.x, 2), round(d.z, 2), round(d.y, 2)], "fbx": path}
        print("EXPORTED", k, tris, info[k]["size_roblox"])
    return info


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    out = a[a.index("--out") + 1] if "--out" in a else os.path.join(HERE, "_out")
    keys = a[a.index("--only") + 1].split(",") if "--only" in a else list(ROCKS)
    if "--export" in a:
        export(out, keys)
    objs, _ = build(keys)
    for k, (ob, tris) in objs.items():
        print("TRIS", k, tris, [round(x, 1) for x in ob.dimensions])
    stage(os.path.join(out, "desert_rocks.png"), [o for o, _ in objs.values()])


if __name__ == "__main__":
    main()
