"""Orbitfall environment set 1 (art/STYLE.md): rocks, crag, squad crate, sandbags, Cog barricade.

Built with helper/parts_lib.py. Rocks are one untextured part each (the game tints them per biome);
props use the palette atlas like the call-in models.

Run inside Blender:  import env_set1; env_set1.main(out="<folder>")      (lineup preview only)
                     env_set1.main(out=..., export=True)                  (+ FBX per model)
"""
import os
import random
import sys
from math import pi, sin, cos, radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
import importlib
import parts_lib as pl
importlib.reload(pl)
import bpy
from mathutils import Vector, Euler

ROCK_KEYS = ("env_rock_a", "env_rock_b", "env_rock_c", "env_spire_b")


# ---------------------------------------------------------------- rock primitive
def stone(part, loc, size, sides=7, taper=0.72, cham=0.16, lean=(0.0, 0.0), tilt=(0, 0, 0),
          seed=0, top_tip=0.0, color="Rock", jag=0.16, chips=2):
    """Hard-faceted slab: irregular polygon lofted bottom -> shoulder -> chamfered top.
    loc = bottom centre, size = (x, y, h). lean = top drift (fraction of h).
    chips = how many crown corners are knocked down (broken, not machined)."""
    rng = random.Random(seed)
    sx, sy, h = size
    yaw = rng.uniform(0, 2 * pi)
    angs = [yaw + 2 * pi * i / sides + rng.uniform(-0.32, 0.32) for i in range(sides)]
    radii = [rng.uniform(1 - jag * 1.7, 1 + jag) for _ in range(sides)]

    def ring(z, s, wob=0.0):
        cx, cy = lean[0] * z, lean[1] * z
        return [(cx + cos(a) * sx / 2 * rr * s * rng.uniform(1 - wob, 1 + wob),
                 cy + sin(a) * sy / 2 * rr * s * rng.uniform(1 - wob, 1 + wob), z)
                for a, rr in zip(angs, radii)]
    zs = h * (1 - cham)
    r0 = ring(0, 1.0, 0.05)
    r1 = ring(zs * rng.uniform(0.85, 1.0), taper + (1 - taper) * cham, 0.08)
    r2 = ring(h, taper * (1 - cham * 1.4), 0.1)
    # tipped crown plane + knocked-down corners
    tt = top_tip or 0.1
    tx, ty = rng.uniform(-1, 1) * tt, rng.uniform(-1, 1) * tt
    r2 = [(x, y, z + tx * x + ty * y) for x, y, z in r2]
    for i in rng.sample(range(sides), min(chips, sides)):
        x, y, z = r2[i]
        r2[i] = (x * 0.9, y * 0.9, z - h * rng.uniform(0.15, 0.32))
        x, y, z = r1[i]
        r1[i] = (x, y, z - h * rng.uniform(0.05, 0.15))
    return pl.loft(part, [r0, r1, r2], loc, color, tilt)


def spike(part, loc, size, sides=6, lean=(0.0, 0.0), seed=0, color="Rock", tilt=(0, 0, 0)):
    """Broken-off pointed shard (crag crowns): base ring -> shoulder -> blunt tip."""
    rng = random.Random(seed)
    sx, sy, h = size
    angs = [2 * pi * i / sides + rng.uniform(-0.3, 0.3) for i in range(sides)]
    radii = [rng.uniform(0.8, 1.12) for _ in range(sides)]

    def ring(z, s):
        return [(lean[0] * z + cos(a) * sx / 2 * rr * s, lean[1] * z + sin(a) * sy / 2 * rr * s, z)
                for a, rr in zip(angs, radii)]
    tip = ring(h, 0.12)
    tip = [(x, y, z - rng.uniform(0, 0.12) * h) for x, y, z in tip]
    return pl.loft(part, [ring(0, 1), ring(h * 0.55, 0.62), tip], loc, color, tilt)


def block(part, loc, size, seed=0, cut=(0.18, 0.5), taper=0.82, tip=0.14, rot=(0, 0, 0),
          color="Rock", bulge=0.12, mids=7):
    """Fractured stone block (convex hull): 8 corners each cut off at random depths, a
    jagged mid band that breaks the sides into big facets, a tapered top with a tipped
    fracture-plane crown. Hard and angular, ~60-90 tris. loc = bottom centre."""
    import bmesh
    rng = random.Random(seed)
    hx, hy, h = size[0] / 2, size[1] / 2, size[2]
    tx, ty = rng.uniform(-tip, tip), rng.uniform(-tip, tip)
    pts = []
    for sxn in (-1, 1):
        for syn in (-1, 1):
            for top in (0, 1):
                s = taper * rng.uniform(0.85, 1.1) if top else rng.uniform(0.92, 1.05)
                cx, cy, cz = sxn * hx * s, syn * hy * s, h * top
                cx += rng.uniform(-0.1, 0.1) * hx
                cy += rng.uniform(-0.1, 0.1) * hy
                for ax in range(3):
                    q = [cx, cy, cz]
                    c = rng.uniform(*cut)
                    if ax == 0:
                        q[0] -= sxn * c * hx
                    elif ax == 1:
                        q[1] -= syn * c * hy
                    else:
                        q[2] += (-1 if top else 1) * c * min(h * 0.45, (hx + hy) * 0.6)
                    pts.append(q)
    # mid band: points around the waist, some pushed out, some sucked in
    zmid = h * rng.uniform(0.35, 0.65)
    sm = (1 + taper) / 2
    a0 = rng.uniform(0, 2 * pi)
    for i in range(mids):
        a = a0 + 2 * pi * i / mids + rng.uniform(-0.3, 0.3)
        k = sm * rng.uniform(1 - bulge, 1 + bulge * 0.8)
        pts.append([cos(a) * hx * k * 1.08, sin(a) * hy * k * 1.08,
                    zmid + rng.uniform(-0.15, 0.15) * h])
    for q in pts:            # crown fracture plane applies to the upper half
        if q[2] > h * 0.5:
            q[2] += (tx * q[0] + ty * q[1]) * (q[2] / h)
    bm = bmesh.new()
    vs = [bm.verts.new(q) for q in pts]
    bmesh.ops.convex_hull(bm, input=vs)
    for v in [v for v in bm.verts if not v.link_faces]:
        bm.verts.remove(v)
    bmesh.ops.dissolve_limit(bm, angle_limit=radians(3), verts=bm.verts, edges=bm.edges)
    return pl._add(part, bm, loc, rot, color)


def column(part, loc, size, segs=2, seed=0, rot=(0, 0, 0), step=0.12, **kw):
    """Tall stone column made of `segs` fractured blocks, each a bit narrower and shifted,
    so the column has ledges/strata breaks instead of one smooth prism."""
    rng = random.Random(seed)
    w, d, h = size
    m = pl._rot(rot).to_matrix()
    z, ox, oy = 0.0, 0.0, 0.0
    fr = [rng.uniform(0.8, 1.2) for _ in range(segs)]
    tot = sum(fr)
    for i in range(segs):
        hh = h * fr[i] / tot
        s = 1 - step * i
        last = i == segs - 1
        block(part, Vector(loc) + m @ Vector((ox, oy, z - (0.6 if i == 0 else 0.25))),
              (w * s, d * s, hh + 0.5), seed=seed * 7 + i, rot=rot,
              taper=kw.get("taper", 0.8) if last else 0.94, tip=kw.get("tip", 0.16) if last else 0.05,
              cut=kw.get("cut", (0.18, 0.5)))
        z += hh
        ox += rng.uniform(-0.08, 0.08) * w
        oy += rng.uniform(-0.08, 0.08) * d
    return z


def rock_kit(key, category="prop", first=False):
    k = pl.Kit(key, palette="terrain", category=category, reset=first)
    return k, k.part("Rock", material="Slate", color="Rock")


def R(x=0, y=0, z=0):
    return (radians(x), radians(y), radians(z))


# ---------------------------------------------------------------- rocks
def rock_a(first=False):
    """Chunky boulder: a heavy fractured block with a second block shouldered into it."""
    k, r = rock_kit("env_rock_a", first=first)
    block(r, (0, 0, -0.4), (9.5, 7.5, 6.2), seed=1, rot=R(4, -6, 20))
    block(r, (3.8, 1.2, -0.6), (5.5, 5.0, 4.6), seed=2, rot=R(-10, 14, -15))
    block(r, (-4.6, -2.2, -0.3), (3.0, 2.6, 2.2), seed=3, rot=R(12, -10, 40))
    block(r, (1.5, -4.4, -0.2), (2.0, 1.8, 1.3), seed=4, rot=R(-8, 6, 10))
    return k


def rock_b(first=False):
    """Tall outcrop: a broken stone slab tipped up out of the ground (two strata), a
    shorter one leaning on its back, a fractured top."""
    k, r = rock_kit("env_rock_b", first=first)
    column(r, (0, 0, 0), (8.0, 5.6, 13.5), segs=2, seed=11, rot=R(9, -7, 10), tip=0.25)
    block(r, (-2.8, 3.0, -0.6), (6.0, 4.6, 8.0), seed=12, taper=0.78, tip=0.3, rot=R(-14, 10, -25))
    block(r, (4.2, -2.4, -0.3), (3.6, 3.0, 2.8), seed=13, rot=R(8, 16, 30))
    block(r, (-4.0, -2.8, -0.2), (2.2, 2.0, 1.5), seed=14, rot=R(-10, 0, 0))
    return k


def rock_c(first=False):
    """Low wide ledge: a broad tilted shelf with a smaller step on top and loose chunks."""
    k, r = rock_kit("env_rock_c", first=first)
    block(r, (0, 0, -0.6), (15.0, 10.5, 3.8), seed=21, taper=0.88, tip=0.06, rot=R(3, -4, 0))
    block(r, (-2.2, 1.2, 2.2), (8.5, 6.5, 3.0), seed=22, taper=0.8, tip=0.1, rot=R(-4, 5, 18))
    block(r, (6.8, -3.4, -0.3), (3.0, 2.6, 2.0), seed=23, rot=R(-12, 10, 35))
    block(r, (-6.6, 4.2, -0.2), (2.4, 2.0, 1.4), seed=24, rot=R(10, 0, 0))
    return k


def spire_b(first=False):
    """Big crag: a cluster of fractured stone columns of different heights (with strata
    ledges and tipped crowns), leaning slightly apart; scree blocks at the foot."""
    k, r = rock_kit("env_spire_b", category="set_piece", first=first)
    cols = (  # x, y, w, d, h, tilt x, tilt y, yaw, segs, seed
        (0.0, 0.0, 12.0, 10.0, 46.0, 2, 3, 10, 4, 31),
        (-8.0, 2.5, 9.5, 8.5, 32.0, -2, -6, 35, 3, 32),
        (7.0, 3.0, 8.5, 8.0, 25.0, 3, 8, -20, 3, 33),
        (-3.0, -6.0, 9.0, 7.0, 16.0, 7, -3, 15, 2, 34),
        (5.5, -5.0, 7.0, 6.0, 10.0, 9, 10, 50, 1, 35),
    )
    for x, y, w, d, h, ax, ay, yaw, sg, sd in cols:
        column(r, (x, y, 0), (w, d, h), segs=sg, seed=sd, rot=R(ax, ay, yaw), tip=0.2)
    block(r, (0, 0, -1.2), (25.0, 19.0, 6.0), seed=36, taper=0.78, tip=0.05, rot=R(0, 0, 8))
    for i, (px, py, s) in enumerate(((13.5, -6.5, 4.2), (-2.0, -11.5, 3.0), (-15.0, -1.0, 3.6),
                                     (8.0, 10.0, 2.6), (4.0, -12.5, 1.8), (-12.5, 7.5, 2.2))):
        block(r, (px, py, -0.3), (s * 1.3, s * 1.1, s * 0.75), seed=60 + i,
              rot=R(10 - i * 4, -12 + i * 5, i * 37))
    return k


# ---------------------------------------------------------------- props
def supply_crate(first=False):
    """Squad supply crate: olive box, charcoal frame, stencil, hazard band, amber lamp."""
    k = pl.Kit("env_supply_crate", palette="human", category="prop", reset=first)
    b = k.part("Body", material="Metal", color="Tan")
    g = k.glow("Light")
    sx, sy, sz = 4.2, 2.8, 2.6
    pl.crate(b, (sx, sy, sz), (0, 0, 0.18), color="Tan", trim="Charcoal", latch="Orange",
             mark="CharcoalDark")
    # skids
    for x in (-sx * 0.32, sx * 0.32):
        pl.box(b, (0.5, sy * 1.04, 0.2), (x, 0, 0.1), "Charcoal")
    # hazard band on the lid edge, front
    pl.hazard_stripes(b, sx * 0.55, 0.26, (sx * 0.12, -sy / 2 - 0.02, sz - 0.05),
                      rot=(pi / 2, 0, 0), stripes=4)
    # lid hinge strip + recessed amber lamp on top
    pl.box(b, (sx * 0.9, 0.18, 0.12), (0, sy * 0.42, sz + 0.24), "Charcoal")
    pl.lamp(b, g, (-sx * 0.32, 0.0, sz + 0.2), (0, 0, 1), r=0.16, color="Charcoal")
    return k


def sandbags(first=False):
    """Curved squad sandbag wall with two steel stakes and a small hazard plate."""
    k = pl.Kit("env_sandbags", palette="human", category="prop", reset=first)
    b = k.part("Bags", material="SmoothPlastic", color="Sandbag")
    pl.sandbag_wall(b, 9.0, rows=3, loc=(0, 0, 0), arc=0.7, bag=(1.7, 0.95, 0.5), color="Sandbag",
                    seed=7)
    # a second tone row on top so it doesn't read as one blob
    for i, x in enumerate((-2.6, -0.9, 0.8, 2.5)):
        pl.sandbag(b, (x, 0.04 * x * x + 0.15, 1.24), (0, 0, 0.06 * x + (i % 2) * 0.05),
                   size=(1.6, 0.9, 0.42), color="Canvas")
    for x in (-4.6, 4.6):
        y = 0.04 * x * x + 0.9
        pl.box(b, (0.16, 0.16, 2.0), (x, y, 1.0), "Steel", bevel=0)
    pl.hazard_stripes(b, 1.0, 0.5, (0.6, -0.55, 0.9), rot=(pi / 2 + radians(-8), 0, 0), stripes=3)
    return k


def cog_barricade(first=False):
    """Cog wall section: gunmetal frame on rusted feet, two red riveted armour panels,
    a brass gear cluster, spiked crest, rear braces and the Cog Eye mark."""
    k = pl.Kit("env_cog_barricade", palette="cogwork", category="prop", reset=first)
    b = k.part("Body", material="Metal", color="Gunmetal")
    eye = k.glow("Eye")
    W, H, T = 9.6, 4.2, 1.2
    # base sill + core wall (chamfered section)
    pl.taper_box(b, (W + 0.6, T + 1.4), (W + 0.2, T + 1.0), 0, 0.6, "GunmetalDark")
    pl.loft(b, [pl.chamfer_rect(W / 2, T / 2, 0.25, z) for z in (0.6, H)], color="Gunmetal")
    # rust worn lower edge
    pl.box(b, (W + 0.66, T + 1.46, 0.18), (0, 0, 0.12), "Rust", bevel=0)
    # two red armour panels on the front (-Y), slightly tilted back
    for x in (-W / 4, W / 4):
        pl.riveted_plate(b, W / 2 - 0.5, H - 1.2, 0.22, (x, -T / 2 - 0.12, 0.6 + (H - 0.6) / 2),
                         rot=(pi / 2 + radians(-4), 0, 0), color="CogRed", rivet_color="Brass",
                         spacing=0.9, chamfer=0.18, rivet_segs=4, bevel=0)
    # centre post with the faction mark
    pl.box(b, (0.7, T + 0.6, H + 0.3), (0, 0, (H + 0.3) / 2), "GunmetalDark")
    pl.cog_mark(b, eye, (0, -T / 2 - 0.32, H * 0.62), (0, -1, 0), r=0.42)
    # gear cluster offset to a third of the left panel
    pl.gear_cluster(b, (-W / 4 - 0.9, -T / 2 - 0.24, H * 0.42), rot=(pi / 2, 0, 0), R=0.62,
                    t=0.12, third=False)
    # spiked crest
    for i in range(9):
        x = -W / 2 + 0.55 + i * (W - 1.1) / 8
        pl.cyl(b, 0.2, 0.75, (x, 0, H + 0.36), "Steel" if i % 2 else "GunmetalDark", segs=4,
               r2=0.0)
    pl.box(b, (W + 0.1, T * 0.7, 0.2), (0, 0, H + 0.02), "GunmetalDark", bevel=0)
    # rear braces: angled struts to ground feet
    for x in (-W * 0.36, W * 0.36):
        pl.rod(b, (x, T / 2, H * 0.8), (x, T / 2 + 1.7, 0.2), 0.16, "Gunmetal", segs=6)
        pl.box(b, (0.8, 0.9, 0.3), (x, T / 2 + 1.7, 0.15), "Rust")
        pl.cog_joint(b, (x, T / 2 + 0.05, H * 0.8), (1, 0, 0), 0.3, 0.16, teeth=8)
    # copper pipe running along the back top
    pl.pipe(b, [(-W / 2 + 0.4, T / 2 + 0.15, H - 0.5), (W / 2 - 0.4, T / 2 + 0.15, H - 0.5)], 0.12)
    return k


BUILDERS = (rock_a, rock_b, rock_c, spire_b, supply_crate, sandbags, cog_barricade)


# ---------------------------------------------------------------- preview
DESERT_ROCK = (118, 80, 58)
DESERT_GROUND = (150, 98, 66)


def _lin(rgb):
    return (*pl.srgb_to_linear(tuple(c / 255 for c in rgb)), 1.0)


def tint_rocks(kit, rgb):
    for p in kit.parts:
        m = p.obj.data.materials[0]
        nt = m.node_tree
        for n in list(nt.nodes):
            if n.type == 'TEX_IMAGE':
                nt.nodes.remove(n)
        bsdf = nt.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = _lin(rgb)
        bsdf.inputs["Roughness"].default_value = 0.9
        bsdf.inputs["Metallic"].default_value = 0.0


def stage(out_png, kits, size=(1800, 900), cam_dir=(0.35, -1.0, 0.42), zoom=1.0, target=None):
    """Lay kits out in a row on a desert-coloured ground under a high back sun; render."""
    sc = bpy.context.scene
    for ob in [o for o in bpy.data.objects if o.name.startswith("_stage")]:
        bpy.data.objects.remove(ob, do_unlink=True)
    col = bpy.data.collections.get("_stage") or bpy.data.collections.new("_stage")
    if col.name not in sc.collection.children:
        sc.collection.children.link(col)
    # row layout
    x = 0.0
    lo_all, hi_all = Vector((1e9,) * 3), Vector((-1e9,) * 3)
    for k in kits:
        lo, hi = k.bbox()
        w = hi.x - lo.x
        dx = x - lo.x
        for p in k.parts:
            p.obj.location.x += dx
        x += w + 3.0
        bpy.context.view_layer.update()
        lo, hi = k.bbox()
        lo_all = Vector([min(a, b) for a, b in zip(lo_all, lo)])
        hi_all = Vector([max(a, b) for a, b in zip(hi_all, hi)])
    # ground
    me = bpy.data.meshes.new("_stage_ground")
    import bmesh
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=400)
    bm.to_mesh(me)
    bm.free()
    g = bpy.data.objects.new("_stage_ground", me)
    g.location = ((lo_all.x + hi_all.x) / 2, 0, -0.02)
    gm = bpy.data.materials.new("_stage_ground")
    gm.use_nodes = True
    gb = gm.node_tree.nodes.get("Principled BSDF")
    gb.inputs["Base Color"].default_value = _lin(DESERT_GROUND)
    gb.inputs["Roughness"].default_value = 1.0
    me.materials.append(gm)
    col.objects.link(g)
    # sun behind / above the camera (matches the in-game lighting pass) + soft fill
    for name, rot, energy, ang in (("_stage_sun", (radians(58), 0, radians(-20)), 4.0, 2.0),
                                   ("_stage_fill", (radians(70), 0, radians(160)), 0.8, 20.0)):
        ld = bpy.data.lights.new(name, 'SUN')
        ld.energy, ld.angle = energy, radians(ang)
        ob = bpy.data.objects.new(name, ld)
        ob.rotation_euler = rot
        col.objects.link(ob)
    world = sc.world or bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = _lin((214, 168, 120))
    bg.inputs[1].default_value = 0.9
    # camera
    camd = bpy.data.cameras.new("_stage_cam")
    camd.lens = 40
    cam = bpy.data.objects.new("_stage_cam", camd)
    col.objects.link(cam)
    sc.camera = cam
    ctr = Vector(target) if target else (lo_all + hi_all) / 2
    half_w = (hi_all.x - lo_all.x) / 2
    half_h = (hi_all.z - lo_all.z) / 2
    dist = max(half_w / 0.42, half_h / 0.21, 6) * 1.05 / zoom
    d = Vector(cam_dir).normalized()
    cam.location = ctr + d * dist
    cam.rotation_euler = (-d).to_track_quat('-Z', 'Y').to_euler()
    camd.clip_start, camd.clip_end = 0.1, dist * 6
    r = sc.render
    r.resolution_x, r.resolution_y = size
    r.resolution_percentage = 100
    r.image_settings.file_format = 'PNG'
    sc.view_settings.view_transform = 'Standard'
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
        try:
            r.engine = eng
            break
        except Exception:
            pass
    r.filepath = out_png
    bpy.ops.render.render(write_still=True)
    return out_png


def build_all(only=None):
    kits = []
    for i, fn in enumerate(BUILDERS):
        if only and fn.__name__ not in only:
            continue
        k = fn(first=not kits)
        k.center()
        k.build()
        lo, _ = k.bbox()           # true mesh minimum (piece bbox corners overshoot on tilted pieces)
        for p in k.parts:
            p.obj.location.z -= lo.z
            p.pivot.z -= lo.z
        bpy.context.view_layer.update()
        k.report()
        if k.key in ROCK_KEYS:
            tint_rocks(k, DESERT_ROCK)
        kits.append(k)
    # parts_lib rebuilds palette_<name> for every new Kit, which orphans the texture of earlier
    # kits on the same palette: point every kit back at the live image.
    for k in kits:
        img = bpy.data.images.get(f"palette_{k.palette_name}")
        k.image = img
        for p in k.parts:
            for n in p.obj.data.materials[0].node_tree.nodes:
                if n.type == 'TEX_IMAGE':
                    n.image = img
    return kits


def main(out, export=False, only=None, shots=("rocks", "props")):
    os.makedirs(out, exist_ok=True)
    kits = build_all(only)
    info = {}
    for k in kits:
        lo, hi = k.bbox()
        s = hi - lo
        info[k.key] = {"tris": sum(p.tris for p in k.parts), "parts": len(k.parts),
                       "size_roblox": [round(s.x, 2), round(s.z, 2), round(s.y, 2)]}
    if export:
        # each model alone in a clean scene: no ".001" name clashes, own palette image
        os.environ["ORBITFALL_ROOT"] = out
        pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'   # 1 BU = 1 stud in Roblox
        for fn in BUILDERS:
            if only and fn.__name__ not in only:
                continue
            k = build_all([fn.__name__])[0]
            k.export_fbx()
            k.write_manifest()
        kits = build_all(only)
    paths = []
    rocks = [k for k in kits if k.key in ROCK_KEYS]
    props = [k for k in kits if k.key not in ROCK_KEYS]
    def only_show(show):
        for k in kits:
            for p in k.parts:
                p.obj.hide_render = k not in show
    if "rocks" in shots and rocks:
        only_show(rocks)
        paths.append(stage(os.path.join(out, "rocks.png"), rocks, cam_dir=(0.12, -1.0, 0.3), zoom=0.8))
    if "props" in shots and props:
        only_show(props)
        paths.append(stage(os.path.join(out, "props.png"), props, cam_dir=(0.45, -1.0, 0.5)))
        only_show(kits)
    return {"info": info, "renders": paths}
