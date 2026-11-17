"""Carapace Charger (BROOD heavy) and Hive Titan (BROOD behemoth) in the Brood style (art/STYLE.md).

Drop-in replacements for the rig-v2 models (charger_rig.py / titan_rig.py): the same part names, roles, parents
and pivots as art/fbx/manifest.json, so the game's code-driven animation keeps working. Blender: -Y is the front,
Z up, feet at z = 0 (nothing is shifted, so pivots stay exactly as listed). Roblox = (-bx, bz, by).

  CHARGER  Body (root) / Abdomen (weak goo sac, rear) / Ram (armour, pivots at the neck) / Leg_1..6 (pivot = hip).
  TITAN    Body (root) / Abdomen / Head / Mandible_L|R / Leg_n_Upper (hip) / Leg_n_Lower (knee) / Vent_1..4 (weak).
           Leg_n: odd = left (+X), front -> back.  Vent_4 hangs off Abdomen.

Run headless:  blender -b --factory-startup --python brood_v2_big.py -- charger|titan [--no-render]
Scratch root: /private/tmp/orbitfall-brood2 (export + previews), outputs copied to art/fbx/new and art/images.
"""
import json
import os
import shutil
import sys
from math import pi, cos, sin, radians

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "helper"))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector

SCRATCH = "/private/tmp/orbitfall-brood2"


# ------------------------------------------------------------------ local helpers
def ring_xz(y, hx, hz, zc, c=0.4, xc=0.0, n=10, ex=2.4):
    """Faceted squircle section in the XZ plane at depth y (loft ring, for hulls along Y). c is unused (kept so
    older ring tuples still work); n sides, ex = 2 for an ellipse, higher for boxier."""
    pts = []
    for i in range(n):
        a = 2 * pi * (i + 0.5) / n
        ca, sa = cos(a), sin(a)
        pts.append((hx * abs(ca) ** (2 / ex) * (1 if ca >= 0 else -1), hz * abs(sa) ** (2 / ex) * (1 if sa >= 0 else -1)))
    return [(xc + x, y, zc + z) for x, z in pts]


def hull(part, rings, color):
    """rings = [(y, hx, hz, zc[, chamfer])...] lofted front to back."""
    pl.loft(part, [ring_xz(*r) for r in rings], color=color)


def scute(part, loc, size, color, rot=(0, 0, 0), segs=8):
    """Faceted armour plate: a flattened low-poly dome (size = radii)."""
    pl.sphere(part, 1.0, loc, color, segs, size, rot)


def horn(part, pts, radii, color="Bone", base="BoneDark", sides=6, tip=0.9):
    pts = [Vector(p) for p in pts]
    pl.tube(part, pts, radii, color, sides)
    d = pts[-1] - pts[-2]
    pl.spike(part, pts[-1], d, tip, radii[-1] * 1.05, color, segs=sides)
    pl.sphere(part, radii[0] * 1.2, pts[0], base, segs=8)


def check_vs_old(k, key):
    """Compare the new entry with the repo manifest's rig entry: names / roles / parents / pivots / size."""
    old = json.load(open(os.path.join(REPO, "art", "fbx", "manifest.json")))[key]
    new = k.manifest_entry()
    om = {p["name"]: p for p in old["parts"]}
    nm = {p["name"]: p for p in new["parts"]}
    bad = []
    if set(om) != set(nm):
        bad.append(f"part names differ: missing {sorted(set(om) - set(nm))} extra {sorted(set(nm) - set(om))}")
    for n in om:
        if n in nm:
            a, b = om[n], nm[n]
            if (a["role"], a["parent"]) != (b["role"], b["parent"]):
                bad.append(f"{n}: role/parent {a['role']}/{a['parent']} vs {b['role']}/{b['parent']}")
            if any(abs(x - y) > 0.002 for x, y in zip(a["pivot"], b["pivot"])):
                bad.append(f"{n}: pivot {a['pivot']} vs {b['pivot']}")
            if a["material"] != b["material"]:
                bad.append(f"{n}: material {a['material']} vs {b['material']}")
    so, sn = old["size_studs_roblox_xyz"], new["size_studs_roblox_xyz"]
    print(f"[check] {key}: old size {so} new size {sn} ({[round(100 * (b / a - 1)) for a, b in zip(so, sn)]} %)")
    print(f"[check] old bbox centre {old['bbox_center_roblox']} new {new['bbox_center_roblox']}")
    print("[check] pivots/names/roles match:", "YES" if not bad else "NO")
    for b in bad:
        print("   !", b)
    return not bad


# =====================================================================
# CHARGER
# =====================================================================
CH_HIPS = {1: (1, -1.672), 2: (-1, -1.672), 3: (1, 0.0), 4: (-1, 0.0), 5: (1, 1.824), 6: (-1, 1.824)}
CH_KNEE_Y = {-1.672: -2.28, 0.0: 0.08, 1.824: 2.43}
CH_FOOT_Y = {-1.672: -2.89, 0.0: 0.15, 1.824: 2.96}


def charger():
    k = pl.Kit("charger_brood", palette="brood", category="heavy", reset=True)
    body = k.part("Body", "body", "SmoothPlastic", pivot=(0, 0, 3.0), color="Carapace")
    abd = k.glow("Abdomen", role="weak", pivot=(0, 2.888, 4.9), parent="Body")
    ram = k.part("Ram", "armor", "SmoothPlastic", pivot=(0, -2.584, 3.4), parent="Body", color="Carapace")
    legs = {}
    for n, (sx, hy) in CH_HIPS.items():
        legs[n] = k.part(f"Leg_{n}", "limb", "SmoothPlastic", pivot=(sx * 2.4, hy, 3.0), parent="Body",
                         color="ChitinMid")

    # ---------------- Body: low hull under a shingled back, soft belly, bone flank plates, spines, sac cradle
    hull(body, [(-2.4, 2.4, 1.5, 3.5), (-0.8, 2.9, 2.0, 3.6), (1.0, 2.9, 1.8, 3.5),
                (2.8, 2.4, 1.5, 3.3), (4.4, 1.7, 1.2, 3.2)], "Chitin")
    pl.carapace(body, 4.8, 6.4, 2.5, (0, -0.9, 3.9), segments=4, overlap=0.5, color="CarapaceLight",
                ridge_color="Bone")
    scute(body, (0, 4.0, 3.3), (2.3, 2.3, 1.6), "Carapace")                       # rear shell the sac sits in
    # soft underside: flesh belly + membrane skirt (the weak, un-armoured side)
    scute(body, (0, -0.1, 2.2), (2.6, 3.7, 0.95), "Flesh")
    scute(body, (0, 0.0, 2.55), (3.15, 4.2, 0.4), "Membrane")
    scute(body, (0, 4.0, 2.2), (1.5, 1.6, 0.6), "FleshDark")
    # bone flank plates (identity colour) and spikes
    for s in (1, -1):
        for y, z, w in ((-1.5, 4.8, 1.0), (0.2, 4.6, 1.1)):
            scute(body, (s * 3.3, y, z), (0.4, w, 0.85), "Bone", rot=(0, s * radians(20), 0))
            pl.spike(body, (s * 3.55, y, z - 0.1), (s * 1.0, 0, 0.35), 1.0, 0.28, "Bone", segs=5)
    for y, z, h in ((-2.4, 6.3, 1.0), (-1.1, 6.55, 1.3), (0.2, 6.3, 1.2)):         # dorsal spines on the ridge
        pl.spike(body, (0, y, z), (0, 0.2, 1.0), h, 0.3, "Bone", segs=5)
    # nest around the glowing abdomen: bone collar + prongs, and a rear stinger-like horn
    pl.torus(body, 2.1, 0.3, (0, 2.888, 4.0), "Bone", segs=10, csegs=4)
    for i in range(6):
        a = radians(30 + i * 60)
        base = (2.15 * cos(a), 2.888 + 2.15 * sin(a), 4.05)
        pl.spike(body, base, (cos(a) * 0.4, sin(a) * 0.4, 1.0), 1.6, 0.32, "Bone", segs=5)
    pl.spike(body, (0, 4.6, 4.0), (0, 1.0, 0.7), 2.0, 0.55, "Bone", segs=6)
    for n, (sx, hy) in CH_HIPS.items():                                           # hip sockets
        pl.torus(body, 0.95, 0.22, (sx * 2.7, hy, 3.0), "BoneDark", rot=(0, pi / 2, 0), segs=8, csegs=4)

    # ---------------- Abdomen (weak): lumpy goo sac, nested in the cradle
    pl.goo_sac(abd, (0, 2.888, 4.9), 2.0, seed=3, scale=(1.0, 1.15, 1.05))
    pl.goo_sac(abd, (-1.2, 2.2, 5.9), 0.75, seed=5)
    pl.goo_sac(abd, (1.2, 3.6, 5.9), 0.7, seed=7)

    # ---------------- Ram: dark armoured head, bone crest plates, great nose horn, tusks
    pl.sphere(ram, 1.0, (0, -3.6, 3.7), "Carapace", 10, (3.0, 2.0, 2.15))             # skull
    pl.sphere(ram, 1.0, (0, -2.5, 3.6), "Carapace", 10, (2.6, 1.6, 2.0))              # neck join
    pl.sphere(ram, 1.0, (0, -4.9, 3.0), "Chitin", 8, (1.7, 1.0, 1.15))                # snout
    pl.carapace(ram, 2.7, 3.8, 0.9, (0, -3.0, 5.15), segments=3, overlap=0.45, color="Bone", ridge_color="BoneDark")
    for s in (1, -1):
        scute(ram, (s * 1.75, -4.75, 4.85), (0.95, 0.75, 0.45), "Bone", rot=(radians(-25), s * radians(12), 0))   # brow
        scute(ram, (s * 3.0, -3.5, 3.5), (0.45, 1.2, 1.25), "Bone", rot=(0, s * radians(18), 0))              # cheek
        pl.spike(ram, (s * 3.2, -4.0, 3.8), (s * 1.0, -0.4, 0.3), 0.9, 0.28, "Bone", segs=5)
        pl.spike(ram, (s * 2.8, -2.9, 5.0), (s * 1.0, -0.1, 0.6), 1.0, 0.28, "Bone", segs=5)
        pl.mandible(ram, (s * 1.3, -4.7, 2.6), 1.2, s, r=0.38, color="Bone", curl=0.8)
        pl.sphere(ram, 0.48, (s * 1.95, -5.0, 4.3), "Black", segs=6)                  # dark eyes
        pl.sphere(ram, 0.2, (s * 2.1, -5.4, 4.5), "Spot", segs=5)
    horn(ram, [(0, -5.0, 3.4), (0, -5.5, 4.9), (0, -5.3, 6.5), (0, -4.5, 7.6)], [0.85, 0.65, 0.47, 0.24], tip=0.55)
    pl.torus(ram, 0.92, 0.17, (0, -5.15, 3.9), "BoneDark", rot=(radians(-12), 0, 0), segs=8, csegs=4)

    # ---------------- legs: thigh out and up, shin down to a flared foot (lowest point z = 0)
    for n, (sx, hy) in CH_HIPS.items():
        p = legs[n]
        hip = Vector((sx * 2.4, hy, 3.0))
        knee = Vector((sx * 4.0, CH_KNEE_Y[hy], 3.95))
        ank = Vector((sx * 4.3, CH_FOOT_Y[hy], 0.85))
        pl.sphere(p, 1.0, hip, "Carapace", segs=8)
        pl.tube(p, [hip, knee], [1.0, 0.85], "ChitinMid", 6)
        pl.sphere(p, 1.1, knee, "Carapace", segs=8)
        pl.spike(p, knee + Vector((0, 0, 0.5)), (sx * 0.3, 0, 1.0), 1.3, 0.38, "Bone", segs=5)
        pl.tube(p, [knee, ank], [0.82, 0.5], "ChitinMid", 6)
        pl.sphere(p, 0.55, ank, "Membrane", segs=6)
        pl.cyl(p, 0.95, 0.8, (ank.x, ank.y, 0.4), "BoneDark", segs=6, r2=0.6, bevel=0)
        pl.spike(p, (ank.x, ank.y - 0.4, 0.45), (0, -1.0, -0.1), 0.9, 0.22, "Claw", segs=5)
    return k


# =====================================================================
# TITAN
# =====================================================================
TI_ROWS = {0: (-5.04, -6.3, -7.2), 1: (0.54, 0.72, 0.9), 2: (5.94, 7.38, 8.46)}   # hip y, knee y, foot y
TI_VENTS = {   # name: (pivot y, pivot z, pair half-width x or 0, parent)
    "Vent_1": (-3.79, 18.012, 0.0, "Body"), "Vent_2": (0.518, 17.161, 3.6, "Body"),
    "Vent_3": (5.174, 15.384, 2.2, "Body"), "Vent_4": (9.502, 16.38, 0.0, "Abdomen"),
}


def shingle_z(length, width, height, loc, segments, overlap, x, y):
    """Height of the carapace() stack at (x, y), so chimneys can start just under the surface."""
    step = length / segments
    best = 0.0
    for i in range(segments):
        k = 1 - 0.12 * i
        yc = loc[1] - length / 2 + step * (i + 0.5)
        sx, sy, sz = width / 2 * k, step * (0.5 + overlap), height * k
        t = 1 - (x / sx) ** 2 - ((y - yc) / sy) ** 2
        if t > 0:
            best = max(best, loc[2] + sz * t ** 0.5)
    return best


def stag_horn(part, base, out, height, r0, sides=6):
    b = Vector(base)
    o = Vector(out).normalized()
    z = Vector((0, 0, 1))
    pts = [b - z * 0.5, b + o * 0.5 + z * height * 0.3, b + o * 1.3 + z * height * 0.7, b + o * 1.8 + z * height]
    horn(part, pts, [r0, r0 * 0.78, r0 * 0.5, r0 * 0.22], tip=height * 0.18, sides=sides)


def titan():
    k = pl.Kit("titan_brood", palette="brood", category="behemoth", reset=True)
    vents = {}
    for n, (vy, vz, vx, par) in TI_VENTS.items():
        vents[n] = k.glow(n, role="weak", pivot=(0, vy, vz), parent=par)
    body = k.part("Body", "body", "SmoothPlastic", pivot=(0, 0.54, 7.2), color="Carapace")
    abd = k.part("Abdomen", "limb", "SmoothPlastic", pivot=(0, 3.78, 9.0), parent="Body", color="Carapace")
    head = k.part("Head", "limb", "SmoothPlastic", pivot=(0, -7.2, 7.74), parent="Body", color="Carapace")
    mand = {}
    for s, nm in ((1, "L"), (-1, "R")):
        mand[s] = k.part(f"Mandible_{nm}", "limb", "SmoothPlastic", pivot=(s * 1.71, -10.44, 7.2), parent="Head",
                         color="Bone")
    up, lo = {}, {}
    for n in range(1, 7):
        sx = 1 if n % 2 else -1
        hy, ky, _ = TI_ROWS[(n - 1) // 2]
        up[n] = k.part(f"Leg_{n}_Upper", "limb", "SmoothPlastic", pivot=(sx * 4.32, hy, 7.2), parent="Body", color="ChitinMid")
        lo[n] = k.part(f"Leg_{n}_Lower", "limb", "SmoothPlastic", pivot=(sx * 7.92, ky, 9.36), parent=f"Leg_{n}_Upper",
                       color="ChitinMid")

    # ---------------- Body: hull, shingled elytra, pronotum shield, bone pauldrons, soft belly, vent chimneys
    SH = dict(length=13.0, width=12.4, height=5.6, loc=(0, 0.3, 10.2), segments=6, overlap=0.5)
    hull(body, [(-7.0, 3.8, 3.0, 9.4), (-4.0, 5.4, 4.3, 9.6), (0.0, 6.0, 4.7, 9.8), (4.0, 5.4, 4.3, 9.4),
                (6.8, 4.0, 3.2, 9.0)], "Carapace")
    pl.carapace(body, SH["length"], SH["width"], SH["height"], SH["loc"], segments=SH["segments"],
                overlap=SH["overlap"], color="CarapaceLight", ridge_color="Bone", segs=12)
    scute(body, (0, -6.9, 12.0), (4.9, 3.5, 2.7), "Carapace", segs=10)                  # pronotum shield
    pl.carapace(body, 3.0, 5.4, 1.1, (0, -6.7, 13.9), segments=2, overlap=0.4, color="Bone", ridge_color="BoneDark")
    scute(body, (0, 0.5, 6.4), (5.7, 8.3, 2.6), "Flesh", segs=10)                         # soft belly
    scute(body, (0, 0.5, 7.4), (6.2, 8.6, 0.8), "Membrane", segs=10)                      # membrane skirt
    for s in (1, -1):
        for y, z, w in ((-4.2, 10.4, 2.3), (0.8, 10.0, 2.4)):                              # bone pauldrons
            scute(body, (s * 6.1, y, z), (0.9, w, 2.2), "Bone", rot=(0, s * radians(22), 0))
            pl.spike(body, (s * 6.6, y, z + 0.3), (s * 1.0, 0, 0.5), 2.4, 0.55, "Bone", segs=6)
            pl.spike(body, (s * 6.5, y - 1.0, z - 0.6), (s * 1.0, -0.6, 0.1), 1.8, 0.42, "Bone", segs=6)
    for y in (-2.0, 1.2, 4.0):                                                              # dorsal spines (seam)
        pl.spike(body, (0, y, shingle_z(**SH, x=0, y=y) + 0.2), (0, 0.3, 1.0), 1.7, 0.4, "Bone", segs=6)
    for s in (1, -1):                                                                       # hip sockets
        for hy, ky, fy in TI_ROWS.values():
            pl.torus(body, 2.0, 0.4, (s * 4.9, hy, 7.2), "BoneDark", rot=(0, pi / 2, 0), segs=8, csegs=4)

    # ---------------- Abdomen: rear shingled segment, soft underside, stinger tip
    AB = dict(length=8.0, width=9.6, height=4.4, loc=(0, 8.4, 9.5), segments=4, overlap=0.5)
    pl.carapace(abd, AB["length"], AB["width"], AB["height"], AB["loc"], segments=AB["segments"],
                overlap=AB["overlap"], color="CarapaceLight", ridge_color="Bone", segs=12)
    scute(abd, (0, 10.9, 9.6), (2.7, 2.7, 2.4), "CarapaceLight", segs=10)                        # tip
    pl.spike(abd, (0, 12.4, 9.2), (0, 1.0, -0.1), 1.3, 0.8, "Bone", segs=6)
    scute(abd, (0, 8.0, 6.9), (4.6, 5.6, 1.9), "Flesh", segs=10)
    scute(abd, (0, 8.0, 7.7), (5.0, 5.8, 0.6), "Membrane", segs=10)
    hull(abd, [(3.0, 3.6, 3.3, 9.0), (6.0, 4.6, 3.9, 9.3), (9.0, 3.8, 3.4, 9.4)], "Carapace")

    # ---------------- Vent_1..4 (weak): goo bulbs in bone chimneys
    for n, (vy, vz, vx, par) in TI_VENTS.items():
        xs = (vx, -vx) if vx else (0.0,)
        for x in xs:
            sh = SH if par == "Body" else AB
            z0 = max(shingle_z(**sh, x=x, y=vy), vz - 4.2) - 0.9
            h = min(2.1, vz - 0.6 - z0)
            housing = body if par == "Body" else abd
            pl.lathe(housing, [(2.1, 0), (2.0, 0.5), (1.6, h - 0.6), (1.95, h - 0.2), (1.95, h), (1.1, h)],
                     (x, vy, z0), "Bone", segs=8)
            for i in range(4):                                                              # rim teeth
                a = radians(45 + 90 * i)
                pl.spike(housing, (x + 1.8 * cos(a), vy + 1.8 * sin(a), z0 + h - 0.1),
                         (cos(a) * 0.5, sin(a) * 0.5, 1.0), 1.1, 0.3, "BoneDark", segs=5)
            pl.tube(vents[n], [(x, vy, z0 + h - 0.4), (x, vy, vz)], [1.15, 1.3], None, 6)   # goo stalk out of the socket
            pl.goo_sac(vents[n], (x, vy, vz), 1.4, seed=11 + len(n), scale=(1, 1, 1.05))
            pl.goo_sac(vents[n], (x + 0.2, vy, vz + 1.5), 0.75, seed=21)

    # ---------------- Head: skull, bone helm and brow, dark eyes, crown of horns
    pl.sphere(head, 1.0, (0, -9.0, 7.5), "Carapace", 10, (3.8, 3.4, 3.0))
    pl.sphere(head, 1.0, (0, -7.6, 8.2), "Carapace", 10, (3.4, 2.4, 3.0))
    scute(head, (0, -10.6, 9.6), (3.4, 1.9, 1.0), "Bone", rot=(radians(-14), 0, 0))     # brow ridge
    pl.carapace(head, 3.0, 4.2, 1.1, (0, -8.1, 10.2), segments=3, overlap=0.45, color="Bone", ridge_color="BoneDark")
    scute(head, (0, -11.4, 6.2), (1.9, 1.2, 1.0), "Chitin", segs=8)                        # muzzle / labrum
    for s in (1, -1):
        pl.sphere(head, 0.95, (s * 2.4, -11.1, 8.5), "Black", segs=8)                       # eyes
        pl.sphere(head, 0.4, (s * 2.7, -11.8, 8.9), "Spot", segs=6)
        pl.sphere(head, 0.9, (s * 1.7, -11.2, 5.6), "Membrane", segs=6)                      # mouthparts
    for a, hgt, r0 in ((0, 5.4, 1.35), (40, 4.8, 1.25), (80, 3.8, 1.1)):
        ar = radians(a)
        base = Vector((3.0 * sin(ar), -8.2 - 0.9 * cos(ar), 10.7 - 0.2 * (a / 30)))
        out = Vector((sin(ar), -cos(ar) * 0.4, 0))
        for sgn in ((1, -1) if a else (1,)):
            b = Vector((base.x * sgn, base.y, base.z))
            o = Vector((out.x * sgn, out.y, 0)) if a else Vector((0, -1.0, 0))
            stag_horn(head, b, o, hgt, r0)

    # ---------------- stag mandibles (pivot at the jaw hinge)
    for s in (1, -1):
        m = mand[s]
        pts = [(s * 1.71, -10.44, 7.2), (s * 3.6, -12.4, 6.5), (s * 3.96, -14.4, 7.1), (s * 1.6, -15.8, 8.4)]
        horn(m, pts, [1.15, 1.0, 0.72, 0.3], color="Bone", base="BoneDark", tip=0.6, sides=6)
        for y in (-13.8, -15.0):
            pl.spike(m, (s * (3.7 if y > -14 else 3.0), y, 7.3), (-s * 0.9, 0, 0.9), 1.6, 0.4, "BoneDark", segs=5)

    # ---------------- legs
    for n in range(1, 7):
        sx = 1 if n % 2 else -1
        hy, ky, fy = TI_ROWS[(n - 1) // 2]
        hip = Vector((sx * 4.32, hy, 7.2))
        knee = Vector((sx * 7.92, ky, 9.36))
        ank = Vector((sx * 8.85, fy, 1.8))
        u, l = up[n], lo[n]
        pl.sphere(u, 2.0, hip, "Carapace", segs=8)
        pl.tube(u, [hip, knee], [1.75, 1.45], "ChitinMid", 8)
        scute(u, hip.lerp(knee, 0.5) + Vector((0, 0, 1.3)), (1.7, 1.3, 0.8), "CarapaceLight", rot=(0, -sx * radians(25), 0))
        pl.sphere(u, 1.8, knee, "Carapace", segs=8)
        pl.spike(u, knee + Vector((0, 0, 1.0)), (sx * 0.4, 0, 1.0), 2.4, 0.7, "Bone", segs=6)
        pl.sphere(l, 1.75, knee, "Carapace", segs=8)
        pl.tube(l, [knee, ank], [1.45, 0.85], "ChitinMid", 8)
        for t, h2 in ((0.35, 1.6), (0.6, 1.3)):
            q = knee.lerp(ank, t)
            pl.spike(l, q + Vector((sx * 0.9, 0, 0.3)), (sx * 1.0, 0, 0.5), h2, 0.4, "Bone", segs=5)
        pl.sphere(l, 1.0, ank, "Membrane", segs=6)
        pl.cyl(l, 1.45, 1.7, (ank.x, ank.y, 0.85), "BoneDark", segs=8, r2=1.0, bevel=0)
        for dy in (-1.0, 0.0, 1.0):
            pl.spike(l, (ank.x + sx * 0.3, ank.y + dy * 0.9, 1.0), (sx * 0.6, dy * 0.5, -0.25), 1.6, 0.35, "Claw", segs=5)
    return k


# =====================================================================
# driver
# =====================================================================
MODELS = {"charger": (charger, "charger"), "titan": (titan, "titan")}
DIRS = {"front": (0.45, -1.0, 0.42), "back": (-0.45, 1.0, 0.42)}


def relink_palette(k):
    img = bpy.data.images.get(f"palette_{k.palette_name}")
    k.image = img
    for p in k.parts:
        for n in p.obj.data.materials[0].node_tree.nodes:
            if n.type == 'TEX_IMAGE':
                n.image = img


def main(which, render=True):
    import env_set1
    fn, key = MODELS[which]
    k = fn()
    k.build()
    relink_palette(k)
    k.report()
    for p in k.parts:
        lz = min((p.obj.matrix_world @ v.co).z for v in p.obj.data.vertices)
        if lz < -0.02:
            print(f"[low] {p.name} lowest z {lz:.2f}")
    # export BEFORE rendering (staging moves the parts)
    os.environ["ORBITFALL_ROOT"] = SCRATCH
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'
    fbx = k.export_fbx()
    entry = k.manifest_entry()
    out_dir = os.path.join(REPO, "art", "fbx", "new")
    os.makedirs(out_dir, exist_ok=True)
    shutil.copy(fbx, os.path.join(out_dir, f"{which}_brood.fbx"))
    shutil.copy(os.path.join(SCRATCH, "art", "fbx", "palette_brood.png"), os.path.join(out_dir, "palette_brood.png"))
    with open(os.path.join(out_dir, f"{which}_brood.entry.json"), "w") as f:
        json.dump(entry, f, indent=2)
    ok = check_vs_old(k, key)
    print(f"[done] {which}: tris {sum(p.tris for p in k.parts)}  parts {len(k.parts)}  pivots match {ok}")
    if render:
        os.makedirs(SCRATCH, exist_ok=True)
        for name, d in DIRS.items():
            tmp = os.path.join(SCRATCH, f"{which}_brood_{name}.png")
            env_set1.stage(tmp, [k], size=(900, 900), cam_dir=d)
            shutil.copy(tmp, os.path.join(REPO, "art", "images", f"{which}_brood_{name}.png"))
            # stage() shifts the parts; undo so the second view is laid out the same way
            for p in k.parts:
                p.obj.location.x = p.pivot.x


if __name__ == "__main__":
    a = pl._argv()
    main(a[0], render="--no-render" not in a)
