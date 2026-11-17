"""Bulwark (COG heavy) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Same rig as the old bulwark_rig.py so the game's code-driven poses keep working:
  Body (root) / Core (weak, Neon) / Shield (armor) / Leg_1..4 / Arm_L|R, plus Glow (Neon embers + Cog Eye lens).
Leg_1 = left front (+X), Leg_2 = right front, Leg_3 = left rear, Leg_4 = right rear. Hips at x +-2.5, y -0.1 / 2.2, z 3.05.
Arms pivot at x +-2.85, y -1.5, z 3.0. Shield pivot (0, -2.207, 2.65). Core (0, 0.8, 5.55).
Blender: -Y is the front, Z up, feet at z = 0 (nothing is shifted after modelling, so the pivots stay put).

Silhouette: squat four-legged crab-walker. A tall CogRed riveted shield (gear cluster + Cog Eye) with a gun-port notch,
a central cannon through the notch, a cannon on each arm, a boiler + smokestacks + big cog at the back, and the
Core (red-orange Neon) sitting in a cage on top-back behind a CogRed visor: you only see it from the sides / behind.

Run in Blender:  import cog_bulwark; cog_bulwark.build_all()   then  cog_bulwark.finish() / cog_bulwark.export(root)
"""
import os
import sys
from math import pi, radians, sin, cos

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
import parts_lib as pl
import bpy
from mathutils import Vector

KEY = "bulwark_cog"
HIP_Z = 3.05
LEG_X = 2.5
LEG_Y = {1: -0.1, 2: -0.1, 3: 2.2, 4: 2.2}   # Leg_n -> hip y
LEG_SIDE = {1: 1, 2: -1, 3: 1, 4: -1}        # +X = left
SH_X, SH_Y, SH_Z = 2.85, -1.5, 3.0
CORE = (0.0, 0.8, 5.55)
GUN_Z = 3.96            # central cannon height = 60 % of the 6.6 body height
GUN_TIP = -5.5          # frontmost point of the whole model

# shield plate frame: local XY = plate (u across, v up the plate), local Z = outward normal, leaning back
SH_TILT = 12.0
SH_ROT = (radians(90 - SH_TILT), 0, 0)
SH_LOC = (0.0, -3.3, 2.45)

K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="heavy", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 1.05, 3.05), color="Gunmetal")
    P["Core"] = k.glow("Core", role="weak", pivot=CORE, parent="Body")
    P["Shield"] = k.part("Shield", "armor", "Metal", pivot=(0, -2.207, 2.65), parent="Body", color="CogRed")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 1.05, 3.05), parent="Body")
    for n in (1, 2, 3, 4):
        P[f"Leg_{n}"] = k.part(f"Leg_{n}", "limb", "Metal", pivot=(LEG_SIDE[n] * LEG_X, LEG_Y[n], HIP_Z),
                               parent="Body", color="Gunmetal")
    P["Arm_R"] = k.part("Arm_R", "limb", "Metal", pivot=(-SH_X, SH_Y, SH_Z), parent="Body", color="Gunmetal")
    P["Arm_L"] = k.part("Arm_L", "limb", "Metal", pivot=(SH_X, SH_Y, SH_Z), parent="Body", color="Gunmetal")
    K.clear()
    K.update(kit=k, P=P)
    return k


def sh(u, v, w=0.0):
    """Shield-plate coordinates -> world."""
    return pl.frame(SH_LOC, SH_ROT)((u, v, w))


def _mark(body, glow, loc, n, r=0.3):
    """Cog Eye faction mark (brass gear, dark rim, recessed red lens), facing direction n."""
    o = Vector(loc)
    n = Vector(n).normalized()
    pl.gear(body, r, r * 0.8, 10, r * 0.22, o + n * r * 0.1, "Brass", pl.orient(n))
    pl.torus(body, r * 0.44, r * 0.1, o + n * r * 0.3, "GunmetalDark", pl.orient(n), segs=10, csegs=4)
    pl.cyl(body, r * 0.46, r * 0.06, o + n * r * 0.22, "Lens", pl.orient(n), segs=10, bevel=0)
    pl.cyl(glow, r * 0.28, r * 0.05, o + n * r * 0.27, rot=pl.orient(n), segs=10, bevel=0)


# ---------------------------------------------------------------------------------------- body
def body():
    b, g = K["P"]["Body"], K["P"]["Glow"]
    # hull: squat chamfered slab, lofted
    cy = 0.4
    rings = [[(x, y + cy, z) for x, y, z in pl.chamfer_rect(2.75, 2.7, 0.7, 1.6)],
             [(x, y + cy, z) for x, y, z in pl.chamfer_rect(2.7, 2.62, 0.7, 3.3)],
             [(x, y + cy - 0.05, z) for x, y, z in pl.chamfer_rect(2.3, 2.3, 0.6, 4.0)]]
    pl.loft(b, rings, color="Gunmetal", bevel=0.06)
    pl.box(b, (4.4, 4.6, 0.4), (0, 0.4, 1.4), "GunmetalDark", bevel=0.1)               # belly plate
    pl.box(b, (3.6, 4.4, 0.1), (0, 0.4, 1.17), "Grime", bevel=0)                        # grimy skid
    pl.box(b, (5.2, 0.35, 0.22), (0, -2.38, 1.9), "Rust", bevel=0.04)                   # rusty front lip
    # hip housings sit in the legs; side vents between the hips
    for s in (1, -1):
        pl.bolt_row(b, (s * 2.72, -2.0, 1.95), (s * 2.72, 3.0, 1.95), 5, (s, 0, 0), 0.06, "Brass", 4)
    # CogRed deck armour beside the core pedestal, brass-riveted
    for s in (1, -1):
        pl.riveted_plate(b, 0.7, 4.0, 0.14, (s * 1.88, 0.4, 4.07), (0, 0, 0), "CogRed", "Brass",
                         spacing=0.7, chamfer=0.2, rivet_segs=4, bevel=0.02)
    # central cannon cradle (barrel runs through the shield's gun-port notch)
    pl.box(b, (1.9, 1.0, 1.3), (0, -2.1, 3.9), "GunmetalDark", bevel=0.1)
    pl.box(b, (2.2, 0.4, 0.22), (0, -1.65, 4.6), "Brass", bevel=0.03)                   # trim band
    # core pedestal + toothed turret ring, cage skirt
    pl.cyl(b, 1.55, 0.7, (CORE[0], CORE[1], 4.35), "GunmetalDark", segs=10)
    pl.gear(b, 1.78, 1.52, 10, 0.18, (CORE[0], CORE[1], 4.74), "Brass")
    pl.cyl(b, 1.3, 0.55, (CORE[0], CORE[1], 4.98), "Gunmetal", segs=10)                   # skirt hides the core's underside
    # hex cage: bars + rings around the core, open to the sides and back
    for i in range(8):
        a = radians(i * 45 + 22.5)
        r_lo, r_hi = 1.3, 1.05
        p0 = (CORE[0] + cos(a) * r_lo, CORE[1] + sin(a) * r_lo, 5.2)
        p1 = (CORE[0] + cos(a) * r_hi, CORE[1] + sin(a) * r_hi, 6.45)
        pl.rod(b, p0, p1, 0.11, "GunmetalDark", segs=6)
    for z, rr in ((5.55, 1.18), (6.45, 1.08)):
        pl.torus(b, rr, 0.07, (CORE[0], CORE[1], z), "Steel", segs=10, csegs=3)
    for ang in (0, 90):                                                                    # open cross-bar cap: the core shows from above
        t = radians(ang)
        pl.rod(b, (CORE[0] - cos(t) * 1.1, CORE[1] - sin(t) * 1.1, 6.5), (CORE[0] + cos(t) * 1.1, CORE[1] + sin(t) * 1.1, 6.5),
               0.09, "GunmetalDark", segs=6)
    pl.cyl(b, 0.26, 0.2, (CORE[0], CORE[1], 6.5), "Brass", segs=8, bevel=0)                 # cap boss
    # CogRed visor shields the core from the front
    arc = [radians(a) for a in (212, 232, 252, 272, 292, 312, 332)]
    outer = [(CORE[0] + cos(t) * 1.62, CORE[1] + sin(t) * 1.62) for t in arc]
    inner = [(CORE[0] + cos(t) * 1.38, CORE[1] + sin(t) * 1.38) for t in reversed(arc)]
    pl.extrude(b, outer + inner, 1.45, (0, 0, 5.72), "CogRed", plane='XY', bevel=0.03)
    pl.bolt_row(b, (CORE[0] - 0.5, CORE[1] - 1.64, 6.2), (CORE[0] + 0.5, CORE[1] - 1.64, 6.2), 3, (0, -1, 0), 0.06, "Brass", 4)
    pl.bolt_row(b, (CORE[0] - 0.5, CORE[1] - 1.64, 5.25), (CORE[0] + 0.5, CORE[1] - 1.64, 5.25), 3, (0, -1, 0), 0.06, "Brass", 4)
    # rear: boiler + twin smokestacks with embers, brass feed pipes, big rear cog, vent
    pl.box(b, (4.2, 0.5, 1.8), (0, 2.75, 3.1), "GunmetalDark", bevel=0.08)
    pl.steam_boiler(b, 0.62, 3.2, (0, 3.15, 3.7), rot=pl.AX_X, color="Rust", bands=3, segs=10)
    for s in (1, -1):
        pl.smokestack(b, (s * 1.85, 1.9, 4.0), 0.26, 1.35, glow=g)
        pl.pipe(b, [(s * 1.5, 3.1, 4.3), (s * 1.75, 2.4, 4.4), (s * 1.85, 1.95, 4.35)], 0.09, sides=6)
    pl.gear(b, 1.05, 0.88, 10, 0.2, (0, 3.62, 2.35), "Brass", pl.AX_Y)                      # rear cog, toothed rim
    pl.cyl(b, 0.34, 0.45, (0, 3.5, 2.35), "GunmetalDark", pl.AX_Y, segs=10)
    pl.cyl(b, 0.2, 0.14, (0, 3.75, 2.35), "CogRed", pl.AX_Y, segs=8, bevel=0)
    pl.vent_grille(b, 1.5, 0.5, 3, (0, 3.5, 3.1), (radians(90), 0, 0), "GunmetalDark", "Soot", glow=g)
    # central cannon: barrel through the notch, toothed mantlet collar, fins, muzzle brake
    pl.cyl(b, 0.38, 2.9, (0, -3.95, GUN_Z), "GunmetalDark", pl.AX_Y, segs=10)
    pl.gear(b, 0.66, 0.54, 10, 0.2, (0, -3.62, GUN_Z), "Brass", pl.AX_Y)
    for i in range(3):
        pl.cyl(b, 0.47, 0.1, (0, -4.3 - i * 0.28, GUN_Z), "Gunmetal", pl.AX_Y, segs=10, bevel=0)
    pl.cyl(b, 0.5, 0.5, (0, GUN_TIP + 0.25, GUN_Z), "Gunmetal", pl.AX_Y, segs=8)
    pl.cyl(b, 0.27, 0.05, (0, GUN_TIP + 0.03, GUN_Z), "Oil", pl.AX_Y, segs=8, bevel=0)
    # rear brow of cannon cradle: hazard-free dark vents on the front deck
    for i in range(3):
        pl.box(b, (1.8, 0.12, 0.1), (0, -1.4 + i * 0.22, 4.04 + 0.05), "Soot", bevel=0)


# ---------------------------------------------------------------------------------------- core
def core():
    c = K["P"]["Core"]
    pl.ico(c, 0.82, CORE, subdiv=1, scale=(1, 1, 1.05))


# ---------------------------------------------------------------------------------------- shield
def shield():
    s, g = K["P"]["Shield"], K["P"]["Glow"]
    n = sh(0, 0, 1) - sh(0, 0, 0)       # outward normal
    # backing frame: heater outline with a gun-port notch in the top edge
    frame_pts = [(-3.0, 2.0), (-0.75, 2.0), (-0.75, 1.05), (0.75, 1.05), (0.75, 2.0), (3.0, 2.0), (3.2, 1.2),
                 (2.9, -0.4), (1.5, -1.6), (0.6, -2.0), (-0.6, -2.0), (-1.5, -1.6), (-2.9, -0.4), (-3.2, 1.2)]
    pl.extrude(s, frame_pts, 0.5, SH_LOC, "Gunmetal", SH_ROT, plane='XY', bevel=0.05)
    # CogRed face plate, inset
    face_pts = [(-2.75, 1.78), (-0.98, 1.78), (-0.98, 1.0), (0.98, 1.0), (0.98, 1.78), (2.75, 1.78), (2.95, 1.2),
                (2.68, -0.3), (1.38, -1.4), (0.5, -1.78), (-0.5, -1.78), (-1.38, -1.4), (-2.68, -0.3), (-2.95, 1.2)]
    pl.extrude(s, face_pts, 0.22, sh(0, 0, 0.35), "CogRed", SH_ROT, plane='XY', bevel=0.04)
    # brass rim of the gun-port notch
    pl.box(s, (0.14, 0.14, 0.2), sh(-0.98, 1.4, 0.4), "Brass", SH_ROT, bevel=0)
    pl.box(s, (0.14, 0.14, 0.2), sh(0.98, 1.4, 0.4), "Brass", SH_ROT, bevel=0)
    pl.box(s, (2.14, 0.14, 0.18), sh(0, 0.95, 0.44), "Brass", SH_ROT, bevel=0.02)
    # rivets: border along the face outline, skipping the notch
    zf = 0.46

    def edge(p, q, count):
        pl.bolt_row(s, sh(p[0], p[1], zf), sh(q[0], q[1], zf), count, n, 0.07, "Brass", 4)
    edge((-2.55, 1.58), (-1.2, 1.58), 3)
    edge((1.2, 1.58), (2.55, 1.58), 3)
    edge((-2.72, 1.1), (-2.5, -0.1), 3)
    edge((2.72, 1.1), (2.5, -0.1), 3)
    edge((-2.2, -0.45), (-1.25, -1.2), 3)
    edge((2.2, -0.45), (1.25, -1.2), 3)
    edge((-0.4, -1.6), (0.4, -1.6), 2)
    # gear cluster on the left third (low), Cog Eye mark upper right
    pl.gear_cluster(s, sh(-1.35, -0.35, 0.46), SH_ROT, R=0.75, t=0.1)
    _mark(s, g, sh(1.85, 0.55, 0.46), n, r=0.42)
    # brass trim band across the lower third + worn rust skirt
    pl.box(s, (4.4, 0.12, 0.14), sh(0, -0.9, 0.47), "Brass", SH_ROT, bevel=0.02)
    pl.box(s, (1.4, 0.3, 0.3), sh(0, -1.9, 0.2), "Rust", SH_ROT, bevel=0.05)             # worn toe of the shield
    # skid blocks / side struts: shield stands on skids
    pl.box(s, (1.7, 1.0, 0.56), (0, -3.72, 0.28), "Rust", bevel=0.06)                    # skid shoe under the tip
    pl.box(s, (1.8, 0.9, 0.06), (0, -3.72, 0.03), "Grime", bevel=0)
    # twin rams hold the shield off the hull; gear at each shoulder joint
    for u in (-1.9, 1.9):
        pl.piston(s, (u, -2.15, 2.9), sh(u, 0.3, -0.25), 0.15, "GunmetalDark")
    pl.box(s, (4.6, 0.3, 0.35), (0, -2.4, 1.25), "GunmetalDark", bevel=0.06)             # lower cross brace
    # top-edge handrail brackets
    for u in (-2.6, 2.6):
        pl.box(s, (0.3, 0.3, 0.3), sh(u, 2.05, 0.1), "Brass", SH_ROT, bevel=0.03)


# ---------------------------------------------------------------------------------------- legs
def legs():
    P = K["P"]
    for n in (1, 2, 3, 4):
        lg = P[f"Leg_{n}"]
        sd, y = LEG_SIDE[n], LEG_Y[n]
        x_hip = sd * 2.72
        # hip housing + brass hip gear on the joint axis
        pl.box(lg, (0.9, 1.25, 1.2), (sd * 2.85, y, HIP_Z), "GunmetalDark", bevel=0.08)
        pl.cog_joint(lg, (sd * 3.35, y, HIP_Z), (1, 0, 0), 0.55, 0.18, teeth=8)
        # thigh: boxy, slopes outward-down, CogRed armour plate on top
        pl.taper_box(lg, (1.9, 1.15), (1.35, 1.15), 2.4, 3.55, "Gunmetal", loc=(sd * 3.55, y, 0), top_offset=(-sd * 0.2, 0))
        pl.box(lg, (1.3, 0.8, 0.14), (sd * 3.4, y, 3.62), "CogRed", rot=(0, sd * radians(-8), 0), bevel=0.03)
        pl.bolt_row(lg, (sd * 3.1, y - 0.32, 3.72), (sd * 3.7, y - 0.32, 3.72), 2, (0, 0, 1), 0.05, "Brass", 4)
        pl.bolt_row(lg, (sd * 3.1, y + 0.32, 3.72), (sd * 3.7, y + 0.32, 3.72), 2, (0, 0, 1), 0.05, "Brass", 4)
        # knee: brass gear on the outer face + a ram across the thigh
        pl.cog_joint(lg, (sd * 4.45, y, 2.65), (1, 0, 0), 0.5, 0.16, teeth=8)
        # shin tapers to the ankle, rust band and a clank cylinder
        pl.taper_box(lg, (1.05, 1.05), (1.25, 1.2), 0.65, 2.45, "Gunmetal", loc=(sd * 3.83, y, 0))
        pl.box(lg, (1.3, 1.34, 0.2), (sd * 3.83, y, 0.95), "Rust", bevel=0.04)
        pl.cyl(lg, 0.5, 0.35, (sd * 3.83, y, 0.62), "GunmetalDark", segs=10)
        pl.box(lg, (1.3, 0.36, 0.7), (sd * 3.83, y - 0.66, 1.9), "CogRed", rot=(radians(-10), 0, 0), bevel=0.05)  # shin guard
        # heavy foot: splayed pad, rust toe cap, grime skid
        pl.taper_box(lg, (1.9, 2.05), (1.5, 1.7), 0.0, 0.55, "GunmetalDark", loc=(sd * 3.83, y - 0.2, 0))
        pl.box(lg, (1.85, 0.5, 0.42), (sd * 3.83, y - 1.18, 0.23), "Rust", bevel=0.07)
        pl.box(lg, (1.8, 2.0, 0.07), (sd * 3.83, y - 0.2, 0.035), "Grime", bevel=0)


# ---------------------------------------------------------------------------------------- arms
def arms():
    P = K["P"]
    for sd, nm in ((1, "L"), (-1, "R")):
        a = P[f"Arm_{nm}"]
        x = sd * 3.9
        z0 = 3.2
        # shoulder pod on the hull flank
        pl.box(a, (1.0, 1.5, 1.6), (sd * 2.85, SH_Y, SH_Z), "GunmetalDark", bevel=0.1)
        pl.box(a, (0.8, 1.2, 0.15), (sd * 2.85, SH_Y, SH_Z + 0.85), "CogRed", bevel=0.03)
        # shoulder gear on the joint axis (outer side of the gun housing)
        pl.cog_joint(a, (sd * 4.5, SH_Y, SH_Z), (1, 0, 0), 0.6, 0.18, teeth=10)
        # gun housing: chamfered, CogRed top plate with rivets, side heat fins
        rings = [[(x + px, y, z0 + pz) for px, pz in ((-0.55, -0.55), (0.55, -0.55), (0.6, 0.3), (0.35, 0.62),
                                                       (-0.35, 0.62), (-0.6, 0.3))] for y in (-0.85, -3.2)]
        pl.loft(a, rings, color="Gunmetal", bevel=0.04)
        pl.plate(a, 0.75, 1.9, 0.12, (x, -2.0, z0 + 0.7), (0, 0, 0), "CogRed", chamfer=0.2)
        pl.bolt_row(a, (x - 0.28, -1.2, z0 + 0.77), (x - 0.28, -2.8, z0 + 0.77), 4, (0, 0, 1), 0.05, "Brass", 4)
        pl.bolt_row(a, (x + 0.28, -1.2, z0 + 0.77), (x + 0.28, -2.8, z0 + 0.77), 4, (0, 0, 1), 0.05, "Brass", 4)
        for i in range(3):
            pl.box(a, (0.08, 1.0, 0.22), (x - sd * 0.64, -1.4 - i * 0.35, z0 + 0.15), "GunmetalDark", bevel=0)
        # elbow gear on the outer side (joint rule 1)
        # barrel: toothed brass collar, barrel, muzzle
        pl.gear(a, 0.62, 0.5, 10, 0.18, (x, -3.3, z0), "Brass", pl.AX_Y)
        pl.cyl(a, 0.3, 1.6, (x, -4.1, z0), "GunmetalDark", pl.AX_Y, segs=10)
        pl.cyl(a, 0.4, 0.4, (x, -5.15, z0), "Gunmetal", pl.AX_Y, segs=8)
        pl.cyl(a, 0.22, 0.05, (x, -5.35 + 0.0, z0), "Oil", pl.AX_Y, segs=8, bevel=0)


# ---------------------------------------------------------------------------------------- driver
def build_all():
    start()
    body()
    core()
    shield()
    legs()
    arms()
    return K["kit"]


def finish():
    k = K["kit"]
    k.build()
    k.report()
    return k


def export(root):
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'
    k = K["kit"]
    k.export_fbx()
    return k.manifest_entry()


def main():
    import json
    import shutil
    import importlib
    scratch = "/private/tmp/orbitfall-bulwark_cog"
    repo = os.path.normpath(os.path.join(HERE, "..", ".."))
    os.makedirs(scratch, exist_ok=True)
    k = build_all()
    k.build()
    warn = k.report()
    k.build()
    entry = export(scratch)
    os.makedirs(os.path.join(repo, "art", "fbx", "cog"), exist_ok=True)
    shutil.copyfile(os.path.join(scratch, "art", "fbx", f"{KEY}.fbx"), os.path.join(repo, "art", "fbx", "cog", f"{KEY}.fbx"))
    with open(os.path.join(repo, "art", "fbx", "cog", f"{KEY}.entry.json"), "w", encoding="utf-8") as f:
        json.dump(entry, f, indent=2)
    # previews (stage moves objects, so after the export)
    sys.path.insert(0, HERE)
    import env_set1
    img = bpy.data.images.get("palette_cogwork")
    for shot, d in (("front", (0.6, -1.0, 0.32)), ("back", (-0.55, 1.0, 0.5))):
        out = os.path.join(repo, "art", "images", f"bulwark_cog_{shot}.png")
        env_set1.stage(out, [k], size=(900, 900), cam_dir=d, zoom=0.9)
    env_set1.stage(os.path.join(scratch, "side.png"), [k], size=(900, 900), cam_dir=(1.0, -0.15, 0.25), zoom=0.9)
    env_set1.stage(os.path.join(scratch, "top.png"), [k], size=(900, 900), cam_dir=(0.05, -0.35, 1.0), zoom=0.9)
    print("ENTRY size", entry["size_studs_roblox_xyz"])
    for p in entry["parts"]:
        print("PIVOT", p["name"], p["pivot"], p["role"], p["parent"], p["triangles"])


if __name__ == "__main__":
    main()
