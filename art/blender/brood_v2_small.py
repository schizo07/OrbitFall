"""Skitterling (SKITTER, Brood regular) and Spitter (SPITTER, Brood medium) in the Brood style (art/STYLE.md).

Drop-in rebuilds of the rigged v2 models (rigVersion 2): same part names, parents, roles and pivots as the
entries in src/shared/Data/Meshes.luau / art/fbx/manifest.json, so EnemyAnim's code-driven legs, mandibles,
neck and head keep working. Blender -Y is the front, Z up, lowest point at z = 0, no shifts after the pivots.

  Skitter parts: Body (root) / Eye (weak, Neon) / Mandible_L|R / Leg_1..6 (odd = left = +X, front -> back pairs)
  Spitter parts: Body (root) / Sac (weak, Neon) / Neck / Head (parent Neck) / Leg_1..6

Palette "brood": Chitin / Carapace structure, Bone plates, Membrane trim, Goo green glow only in Eye / Sac.

Run:  Blender -b --factory-startup --python brood_v2_small.py -- <scratch root> [<image dir>]
Writes <root>/art/fbx/<key>_brood.fbx, palette_brood.png, <key>_brood.entry.json and <key>_brood_{front,back}.png.
"""
import json
import os
import sys
from math import pi, radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector


# ------------------------------------------------------------------ small helpers
def seg(part, p0, p1, r0, r1, color, segs=8):
    """Tapered cylinder from p0 (radius r0) to p1 (radius r1)."""
    p0, p1 = Vector(p0), Vector(p1)
    d = p1 - p0
    return pl.cyl(part, r0, d.length, (p0 + p1) / 2, color, pl.orient(d), segs=segs, r2=r1, bevel=0)


def foot_z(knee, foot_xy, r1):
    """Height of the foot point so that bug_leg's claw spike (length 4*r1 along knee->foot) ends at z = 0."""
    z = r1 * 4
    for _ in range(8):
        d = (Vector((foot_xy[0], foot_xy[1], z)) - Vector(knee)).normalized()
        z = -d.z * r1 * 4
    return z


def leg(part, hip, knee, foot_xy, r0, r1, spikes=True):
    fz = foot_z(knee, foot_xy, r1)
    pts = [hip, knee, (foot_xy[0], foot_xy[1], fz)]
    pl.bug_leg(part, pts, r0, r1, "ChitinMid", "Chitin", "Claw", spikes=spikes, sides=6)


def mirror_lr(mx):
    """Pivot x for the left (+X, odd) / right (-X, even) leg of a pair."""
    return mx


# ------------------------------------------------------------------ SKITTERLING
SK_KEY = "skitter_brood"


def build_skitter():
    k = pl.Kit(SK_KEY, palette="brood", category="regular", reset=True)
    body = k.part("Body", "body", "SmoothPlastic", pivot=(0, 0.2, 1.05), color="Chitin")
    eye = k.glow("Eye", role="weak", pivot=(0, -1.98, 1.643), parent="Body")
    jaw = {}
    for s, n in ((1, "L"), (-1, "R")):
        jaw[s] = k.part(f"Mandible_{n}", "limb", "SmoothPlastic", pivot=(s * 0.4, -1.95, 1.2),
                        parent="Body", color="Bone")
    legs = {}
    for i, hy in enumerate((-0.55, 0.2, 0.95)):
        for j, s in enumerate((1, -1)):
            n = i * 2 + j + 1
            legs[n] = (k.part(f"Leg_{n}", "limb", "SmoothPlastic", pivot=(s * 0.75, hy, 1.05),
                              parent="Body", color="ChitinMid"), s, hy)

    # ---- Body: low wedge head, shingled carapace back with a bone spine, plated abdomen, membrane belly
    pl.sphere(body, 1.0, (0, -1.2, 1.15), "Chitin", segs=8, scale=(1.1, 0.88, 0.78))            # head
    pl.box(body, (1.5, 0.75, 0.22), (0, -1.55, 1.95), "Bone", rot=(radians(18), 0, 0), bevel=0.05)  # brow plate
    pl.sphere(body, 0.55, (0, -1.9, 1.1), "Carapace", segs=8, scale=(1.3, 0.55, 0.55))          # snout plate
    for s in (1, -1):                                                                           # eye sockets (dark rim)
        pl.torus(body, 0.34, 0.09, (s * 0.5, -1.97, 1.64), "Black", pl.orient((s * 0.3, -1, 0.15)),
                 segs=8, csegs=4)
        pl.sphere(body, 0.3, (s * 0.5, -1.75, 1.64), "Black", segs=8)
    pl.carapace(body, 2.0, 2.3, 0.82, (0, -0.35, 1.3), segments=2, color="Carapace", ridge_color="CarapaceLight",
                segs=8)
    pl.carapace(body, 2.7, 2.4, 1.0, (0, 0.85, 1.28), segments=4, color="Carapace", ridge_color="CarapaceLight",
                rot=(radians(8), 0, 0), segs=8)
    pl.sphere(body, 0.5, (0, 1.75, 1.5), "Chitin", segs=8, scale=(0.9, 1.0, 0.85))              # tail tip
    for y, zz, h in ((-0.1, 2.12, 0.5), (0.7, 2.3, 0.6), (1.5, 2.28, 0.5)):                       # dorsal spikes
        pl.spike(body, (0, y, zz - 0.1), (0, 0.15, 1), h, 0.2, "Bone", segs=6)
    for s in (1, -1):                                                                           # side hip plates
        for hy in (-0.55, 0.2, 0.95):
            pl.sphere(body, 0.6, (s * 0.95, hy, 1.1), "CarapaceLight", segs=8, scale=(0.75, 0.85, 0.6))
    pl.sphere(body, 1.0, (0, 0.1, 0.95), "Membrane", segs=8, scale=(0.95, 1.8, 0.45))            # belly
    for y in (0.0, 0.7, 1.4):
        pl.sphere(body, 1.0, (0, y, 0.95), "Flesh", segs=8, scale=(1.0, 0.12, 0.47))              # belly seams

    # ---- Eye (weak): two big compound eyes with a few small ones, sitting inside the sockets
    with pl.mirrored(eye):
        pl.ico(eye, 0.26, (0.5, -1.98, 1.64), subdiv=1, scale=(1, 0.8, 1), jitter=0.08, seed=1)
        pl.ico(eye, 0.1, (0.3, -2.02, 1.12), subdiv=1, jitter=0.1, seed=2)
        pl.ico(eye, 0.09, (0.92, -1.8, 1.2), subdiv=1, jitter=0.1, seed=3)

    # ---- mandibles: big hooked bone pincers, pivot at the jaw hinge
    for s, p in jaw.items():
        base = Vector((s * 0.4, -1.95, 1.2))
        pl.sphere(p, 0.3, base, "BoneDark", segs=8)
        pl.mandible(p, base, 1.0, side=s, r=0.27, color="Bone", tip="Claw", curl=0.8)
        pl.spike(p, base + Vector((s * 0.5, -0.5, 0.1)), (s * 0.4, -0.2, 1), 0.38, 0.1, "BoneDark", segs=5)

    # ---- six legs: sprawling, claw tips on the ground
    for n, (p, s, hy) in legs.items():
        hip = (s * 0.75, hy, 1.05)
        pl.sphere(p, 0.4, hip, "ChitinMid", segs=8)
        leg(p, hip, (s * 1.85, hy + (-0.35 if hy < 0.5 else 0.5), 1.95),
            (s * 2.55, {-0.55: -1.7, 0.2: 0.1, 0.95: 1.8}[hy]), 0.32, 0.1, spikes=hy < 0.5)
    return k


# ------------------------------------------------------------------ SPITTER
SP_KEY = "spitter_brood"


def build_spitter():
    k = pl.Kit(SP_KEY, palette="brood", category="medium", reset=True)
    body = k.part("Body", "body", "SmoothPlastic", pivot=(0, 0.4, 1.92), color="Chitin")
    sac = k.glow("Sac", role="weak", pivot=(0, 1.274, 3.92), parent="Body")
    neck = k.part("Neck", "limb", "SmoothPlastic", pivot=(0, -1.28, 2.56), parent="Body", color="Chitin")
    head = k.part("Head", "limb", "SmoothPlastic", pivot=(0, -2.12, 4.88), parent="Neck", color="Chitin")
    legs = {}
    for i, hy in enumerate((-0.8, 0.4, 1.6)):
        for j, s in enumerate((1, -1)):
            n = i * 2 + j + 1
            legs[n] = (k.part(f"Leg_{n}", "limb", "SmoothPlastic", pivot=(s * 0.72, hy, 1.92),
                              parent="Body", color="ChitinMid"), s, hy, i)

    # ---- Body: thorax + swollen abdomen under the sac cradle, membrane skirt
    pl.sphere(body, 1.0, (0, -0.55, 2.2), "Chitin", segs=8, scale=(1.05, 1.15, 0.86))             # thorax
    pl.carapace(body, 1.7, 1.9, 0.62, (0, -0.55, 2.45), segments=2, color="Carapace", ridge_color="Bone", segs=8)
    pl.carapace(body, 3.2, 2.5, 1.05, (0, 1.6, 2.35), segments=4, color="Carapace", ridge_color="Bone",
                rot=(radians(14), 0, 0), segs=8)
    pl.sphere(body, 1.0, (0, 0.0, 1.62), "Membrane", segs=8, scale=(1.0, 2.0, 0.45))              # belly skirt
    pl.sphere(body, 1.0, (0, 1.9, 1.7), "Membrane", segs=8, scale=(1.15, 1.35, 0.5))
    for y in (0.5, 1.5, 2.4):
        pl.sphere(body, 1.0, (0, y, 1.64), "Flesh", segs=8, scale=(1.18, 0.1, 0.55))
    # sac cradle: bone ring + thorns around the bulb
    pl.torus(body, 1.1, 0.16, (0, 1.274, 3.22), "Bone", segs=12, csegs=4)
    import math
    for a in range(0, 360, 45):
        x = math.cos(math.radians(a)) * 1.2
        y = 1.274 + math.sin(math.radians(a)) * 1.2
        pl.spike(body, (x, y, 3.2), (x * 0.5, (y - 1.274) * 0.5, 1.0), 0.8, 0.16, "Bone", segs=5)
    for a in range(22, 360, 90):                                                                  # dark root of the cradle
        pl.sphere(body, 0.25, (math.cos(math.radians(a)) * 1.1, 1.274 + math.sin(math.radians(a)) * 1.1, 3.15),
                  "BoneDark", segs=6)
    # neck seat on the thorax
    pl.sphere(body, 0.62, (0, -1.28, 2.62), "CarapaceLight", segs=8, scale=(1, 1, 0.8))

    # ---- Sac (weak): big bulb + satellite bubbles, nested in the thorn cradle
    pl.ico(sac, 1.05, (0, 1.274, 3.98), subdiv=2, scale=(0.95, 1.0, 1.05), jitter=0.05, seed=7)
    with pl.mirrored(sac):
        pl.ico(sac, 0.4, (0.85, 0.75, 3.55), subdiv=1, jitter=0.1, seed=8)
        pl.ico(sac, 0.32, (0.65, 1.95, 3.5), subdiv=1, jitter=0.1, seed=9)

    # ---- Neck: stacked tapering segments, membrane joints (pivot at the thorax)
    pts = [(0, -1.28, 2.56), (0, -1.7, 3.3), (0, -1.75, 4.1), (0, -2.12, 4.88)]
    for i, (a, b) in enumerate(zip(pts, pts[1:])):
        r0, r1 = 0.62 - 0.07 * i, 0.55 - 0.07 * i
        seg(neck, a, b, r0, r1, "Carapace" if i % 2 == 0 else "Chitin", segs=8)
        pl.sphere(neck, r1 * 1.12, b, "Membrane", segs=8, scale=(1, 1, 0.55))
    pl.sphere(neck, 0.6, pts[0], "Membrane", segs=8, scale=(1, 1, 0.6))

    # ---- Head: skull, bone funnel snout with a wet dark mouth, eyes, horns (pivot at the neck top)
    pl.sphere(head, 1.0, (0, -2.4, 5.05), "Chitin", segs=8, scale=(0.82, 0.92, 0.7))
    pl.box(head, (1.3, 0.5, 0.2), (0, -2.6, 5.62), "Carapace", rot=(radians(-12), 0, 0), bevel=0.04)   # brow
    seg(head, (0, -3.0, 4.98), (0, -3.75, 5.2), 0.52, 0.36, "Bone", segs=8)                       # tapering spout
    seg(head, (0, -3.75, 5.2), (0, -4.15, 5.3), 0.36, 0.3, "BoneDark", segs=8)
    seg(head, (0, -4.1, 5.29), (0, -4.3, 5.34), 0.3, 0.46, "Bone", segs=8)                        # short flared lip
    pl.cyl(head, 0.27, 0.12, (0, -4.3, 5.34), "Black", pl.orient((0, -1, 0.25)), segs=8, bevel=0)
    pl.cyl(head, 0.15, 0.06, (0, -4.34, 5.35), "FleshDark", pl.orient((0, -1, 0.25)), segs=8, bevel=0)
    pl.sphere(head, 0.3, (0, -3.2, 4.62), "Flesh", segs=8, scale=(1.2, 1.0, 0.6))                  # throat pouch under the spout
    for s in (1, -1):
        pl.sphere(head, 0.32, (s * 0.62, -2.9, 5.3), "Bone", segs=8)
        pl.sphere(head, 0.17, (s * 0.7, -3.12, 5.34), "Black", segs=6)
        pts_h = [(s * 0.45, -2.3, 5.5), (s * 0.85, -2.0, 5.85), (s * 0.8, -1.55, 6.0)]
        pl.tube(head, pts_h, [0.2, 0.14, 0.04], "Bone", 6)

    # ---- legs: front pair short, rear two pairs strong, claws on the ground
    for n, (p, s, hy, row) in legs.items():
        hip = (s * 0.72, hy, 1.92)
        ky = (hy - 0.5, hy + 0.2, hy + 0.55)[row] if False else hy + (-0.5, 0.15, 0.55)[row]
        fy = (-1.84, 0.56, 2.72)[row]
        r0 = (0.34, 0.4, 0.4)[row]
        pl.sphere(p, r0 * 1.2, hip, "ChitinMid", segs=8)
        leg(p, hip, (s * 1.68, ky, 2.4), (s * 2.24, fy), r0, 0.13, spikes=row > 0)
    return k


# ------------------------------------------------------------------ build / export / preview
EXPECT = {
    "skitter_brood": {
        "Body": (0, 1.05, 0.2), "Eye": (0, 1.643, -1.98), "Mandible_L": (-0.4, 1.2, -1.95), "Mandible_R": (0.4, 1.2, -1.95),
        "Leg_1": (-0.75, 1.05, -0.55), "Leg_2": (0.75, 1.05, -0.55), "Leg_3": (-0.75, 1.05, 0.2),
        "Leg_4": (0.75, 1.05, 0.2), "Leg_5": (-0.75, 1.05, 0.95), "Leg_6": (0.75, 1.05, 0.95)},
    "spitter_brood": {
        "Body": (0, 1.92, 0.4), "Sac": (0, 3.92, 1.274), "Neck": (0, 2.56, -1.28), "Head": (0, 4.88, -2.12),
        "Leg_1": (-0.72, 1.92, -0.8), "Leg_2": (0.72, 1.92, -0.8), "Leg_3": (-0.72, 1.92, 0.4),
        "Leg_4": (0.72, 1.92, 0.4), "Leg_5": (-0.72, 1.92, 1.6), "Leg_6": (0.72, 1.92, 1.6)},
}
OLD_SIZE = {"skitter_brood": (5.48, 2.8, 5.53), "spitter_brood": (5.1, 6.02, 7.41)}


def _relink_palette(k):
    img = bpy.data.images.get(f"palette_{k.palette_name}")
    k.image = img
    for p in k.parts:
        for n in p.obj.data.materials[0].node_tree.nodes:
            if n.type == 'TEX_IMAGE':
                n.image = img


def make(fn, root, img_dir):
    import env_set1
    k = fn()
    k.build()
    k.report()
    lo, hi = k.bbox()
    entry_path_ok = abs(lo.z) < 0.03
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'
    k.export_fbx()                       # export BEFORE rendering (stage moves the parts)
    entry = k.manifest_entry()
    out = os.path.join(root, "out")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, f"{k.key}.entry.json"), "w") as f:
        json.dump(entry, f, indent=2)
    # checks
    exp = EXPECT[k.key]
    bad = []
    for p in entry["parts"]:
        e = exp.get(p["name"])
        if e is None or any(abs(a - b) > 0.002 for a, b in zip(p["pivot"], e)):
            bad.append((p["name"], p["pivot"], e))
    missing = set(exp) - {p["name"] for p in entry["parts"]}
    print("CHECK", k.key, "pivots match:", not bad and not missing, bad, missing, "ground ok:", entry_path_ok,
          "lowest z %.3f" % lo.z)
    print("CHECK size", entry["size_studs_roblox_xyz"], "old", OLD_SIZE[k.key], "tris", sum(p["triangles"] for p in entry["parts"]))
    for p in entry["parts"]:
        print("PART", p["name"], p["role"], p["parent"], p["pivot"], p["triangles"])
    _relink_palette(k)
    for name, d in (("front", (0.45, -1.0, 0.4)), ("back", (-0.5, 1.0, 0.45))):
        env_set1.stage(os.path.join(img_dir, f"{k.key}_{name}.png"), [k], size=(900, 900), cam_dir=d)
    return entry


def main():
    args = pl._argv()
    root = args[0] if args else "/private/tmp/orbitfall-brood1"
    img_dir = args[1] if len(args) > 1 else os.path.join(root, "out")
    only = args[2] if len(args) > 2 else None
    os.makedirs(img_dir, exist_ok=True)
    for fn in (build_skitter, build_spitter):
        if only and only not in fn.__name__:
            continue
        make(fn, root, img_dir)


if __name__ == "__main__":
    main()
