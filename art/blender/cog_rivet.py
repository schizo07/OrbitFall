"""Rivet Trooper (COG medium) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Same rig as the old rivet_rig.py so the game's code-driven poses keep working:
  Body (root) / Head / Eye (weak, Neon) / Leg_L|R_Upper / Leg_L|R_Lower / Arm_L|R, plus Glow (Neon embers + Cog Eye lens).
Joint pivots match the old rig (hip z 3.4, knee z 2.2, shoulders x +-2.2 z 5.0, head z 5.85); gun barrels sit at
x +-2.25, z ~3.65 like before (EnemyModels MESH_MUZZLE). Blender: -Y is the front, Z up, feet at z = 0.

Run in Blender:  import cog_rivet; cog_rivet.build_all()            (everything at once)
           or:   cog_rivet.start(); cog_rivet.torso(); cog_rivet.head(); cog_rivet.legs(); cog_rivet.arms()  (live, staged)
                 cog_rivet.finish(out)                                 (merge parts, render previews)
                 cog_rivet.export(root)                                (FBX + manifest entry under root/art/fbx)
"""
import os
import sys
from math import pi, radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
import parts_lib as pl
import bpy
from mathutils import Vector

KEY = "rivet_cog"
HIP_Z, KNEE_Z = 3.4, 2.2
SH_X, SH_Z = 2.2, 5.0
GUN_X, GUN_Z = 2.25, 3.65

K = {}  # live kit + parts between staged calls


def start():
    k = pl.Kit(KEY, palette="cogwork", category="medium", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, -0.05, HIP_Z), color="Gunmetal")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, -0.05, HIP_Z), parent="Body")
    P["Head"] = k.part("Head", "limb", "Metal", pivot=(0, -0.2, 5.85), parent="Body", color="Gunmetal")
    P["Eye"] = k.glow("Eye", role="weak", pivot=(0, -0.2, 5.85), parent="Head")
    for s, n in ((1, "L"), (-1, "R")):
        x = s * 1.15
        P[f"Leg_{n}_Upper"] = k.part(f"Leg_{n}_Upper", "limb", "Metal", pivot=(x, -0.05, HIP_Z), parent="Body", color="Gunmetal")
        P[f"Leg_{n}_Lower"] = k.part(f"Leg_{n}_Lower", "limb", "Metal", pivot=(x, -0.05, KNEE_Z), parent=f"Leg_{n}_Upper", color="Gunmetal")
    for s, n in ((1, "L"), (-1, "R")):
        P[f"Arm_{n}"] = k.part(f"Arm_{n}", "limb", "Metal", pivot=(s * SH_X, -0.15, SH_Z), parent="Body", color="Gunmetal")
    K.clear()
    K.update(kit=k, P=P)
    return k


def _mark(body, glow, loc, r=0.3):
    """Cog Eye faction mark facing -Y: brass gear, dark rim, recessed red lens (glow sits inside the rim)."""
    o = Vector(loc)
    n = Vector((0, -1, 0))
    pl.gear(body, r, r * 0.8, 10, r * 0.22, o + n * r * 0.1, "Brass", pl.orient(n))
    pl.torus(body, r * 0.44, r * 0.1, o + n * r * 0.3, "GunmetalDark", pl.orient(n), segs=10, csegs=4)
    pl.cyl(body, r * 0.46, r * 0.06, o + n * r * 0.22, "Lens", pl.orient(n), segs=10, bevel=0)
    pl.cyl(glow, r * 0.28, r * 0.05, o + n * r * 0.27, rot=pl.orient(n), segs=10, bevel=0)


def torso():
    b, g = K["P"]["Body"], K["P"]["Glow"]
    FRONT = pl.AX_Y  # local +Z -> world -Y
    # pelvis block + hip gears (rule 1: every joint is a gear)
    pl.box(b, (2.7, 1.45, 0.75), (0, -0.05, 3.62), "GunmetalDark", bevel=0.12)
    pl.box(b, (2.2, 0.3, 0.5), (0, -0.82, 3.55), "Rust", bevel=0.06)                 # grimy codpiece guard
    for s in (1, -1):
        pl.cog_joint(b, (s * 1.62, -0.05, HIP_Z), (1, 0, 0), 0.42, 0.16, teeth=10)
    # waist turret ring (rotating hardware gets teeth)
    pl.cyl(b, 0.62, 0.5, (0, 0, 4.05), "GunmetalDark", segs=12)
    pl.gear(b, 0.86, 0.72, 12, 0.16, (0, 0, 4.12), "Brass")
    # top-heavy chamfered torso, mass high and forward
    rings = [pl.chamfer_rect(1.25, 0.82, 0.28, 4.2),
             [(x, y - 0.12, z) for x, y, z in pl.chamfer_rect(1.95, 1.05, 0.38, 5.05)],
             [(x, y - 0.1, z) for x, y, z in pl.chamfer_rect(1.8, 0.95, 0.34, 5.85)]]
    pl.loft(b, rings, color="Gunmetal", bevel=0.05)
    # chest armour: CogRed riveted plate, gear cluster on its left third, Cog Eye mark top right
    pl.riveted_plate(b, 2.5, 1.25, 0.16, (0, -1.22, 4.98), (radians(90 + 6), 0, 0), "CogRed", "Brass",
                     spacing=0.42, chamfer=0.22)
    pl.gear_cluster(b, (-0.62, -1.32, 4.95), (radians(90 + 6), 0, 0), R=0.34, t=0.08)
    _mark(b, g, (0.6, -1.3, 5.12), r=0.26)
    pl.box(b, (2.4, 0.2, 0.16), (0, -1.12, 4.27), "Brass", bevel=0.03)              # brass trim band
    # collar / gorget the head sits in
    pl.box(b, (1.9, 1.3, 0.35), (0, -0.15, 5.95), "GunmetalDark", bevel=0.08)
    # shoulder pauldrons: CogRed, flared, brass edge rivets
    for s in (1, -1):
        rot = (0, radians(s * 30), 0)
        pl.box(b, (1.0, 1.2, 0.5), (s * 2.0, -0.08, 5.55), "GunmetalDark", bevel=0.06)          # shoulder housing
        pl.loft(b, [[(x * 0.62, y, 0) for x, y, _ in pl.chamfer_rect(1.0, 0.9, 0.3, 0)],
                    [(x * 0.62, y, 0.42) for x, y, _ in pl.chamfer_rect(0.8, 0.72, 0.26, 0)]],
                loc=(s * 2.3, -0.08, 5.62), rot=rot, color="CogRed", bevel=0.04)                  # shell pauldron
        pl.box(b, (1.3, 0.12, 0.12), (s * 2.3, -0.98, 5.58), "Brass", rot=rot, bevel=0.02)
        pl.bolt_row(b, (s * 2.12, -0.6, 6.0), (s * 2.12, 0.45, 6.0), 3, (s * 0.5, 0, 1), 0.06, "Brass")
    # back: horizontal boiler drum, twin smokestacks with ember glow, copper feed pipes
    pl.box(b, (2.3, 0.5, 1.5), (0, 1.05, 4.95), "GunmetalDark", bevel=0.08)
    pl.steam_boiler(b, 0.6, 1.8, (0, 1.55, 4.85), rot=pl.AX_X, color="Rust", bands=3)
    for s in (1, -1):
        pl.smokestack(b, (s * 0.62, 1.45, 5.35), 0.2, 1.25, glow=g)
        pl.pipe(b, [(s * 1.05, 1.55, 4.6), (s * 1.55, 1.2, 4.6), (s * 1.75, 0.5, 4.75)], 0.08)
    pl.vent_grille(b, 1.1, 0.5, 3, (0, 1.32, 4.1), (radians(-90), 0, 0), "GunmetalDark", "Soot", glow=g)


def head():
    h, e = K["P"]["Head"], K["P"]["Eye"]
    # squat armoured helm with a forward CogRed brow hood over a recessed visor slit (weak spot)
    pl.taper_box(h, (1.7, 1.55), (1.4, 1.25), 5.88, 6.75, "Gunmetal", top_offset=(0, -0.05))
    pl.taper_box(h, (1.85, 0.7), (1.6, 0.55), 6.42, 6.82, "CogRed", loc=(0, -0.62, 0))       # brow hood
    pl.box(h, (0.24, 1.3, 0.16), (0, -0.05, 6.86), "Brass", bevel=0.03)                      # crest bar
    pl.visor_slot(h, e, 1.15, 0.24, (0, -0.86, 6.2), lenses=3)
    pl.box(h, (1.3, 0.3, 0.32), (0, -0.88, 5.95), "GunmetalDark", bevel=0.05)               # jaw grille
    for i in range(3):
        pl.box(h, (1.1, 0.06, 0.04), (0, -1.04, 5.88 + i * 0.08), "Soot", bevel=0)
    for s in (1, -1):
        pl.cog_joint(h, (s * 0.86, -0.1, 6.2), (1, 0, 0), 0.26, 0.12, teeth=8)                # ear gears
    pl.antenna(h, (-0.55, 0.4, 6.75), 0.75, color="Steel")


def legs():
    P = K["P"]
    for s, n in ((1, "L"), (-1, "R")):
        x = s * 1.15
        u, lo = P[f"Leg_{n}_Upper"], P[f"Leg_{n}_Lower"]
        # thigh: boxy armoured segment, CogRed outer plate, side ram
        pl.taper_box(u, (1.05, 1.15), (0.9, 1.0), 2.4, 3.3, "Gunmetal", loc=(x, -0.05, 0))
        pl.plate(u, 0.75, 0.7, 0.1, (x + s * 0.55, -0.05, 2.9), (0, radians(s * 90), 0), "CogRed", chamfer=0.25)
        pl.piston(u, (x - s * 0.2, 0.55, 3.2), (x - s * 0.2, 0.6, 2.35), 0.09, "GunmetalDark")
        # knee: brass gear on the joint axis + forward knee guard (moves with the shin)
        pl.cog_joint(lo, (x, -0.05, KNEE_Z), (1, 0, 0), 0.5, 0.75, teeth=10)
        pl.box(lo, (0.85, 0.32, 0.75), (x, -0.62, 2.15), "CogRed", rot=(radians(-12), 0, 0), bevel=0.06)
        # shin: tapers down, rust and grime at the bottom
        pl.taper_box(lo, (0.85, 0.95), (1.0, 1.05), 0.75, 1.95, "Gunmetal", loc=(x, -0.05, 0))
        pl.box(lo, (1.02, 1.08, 0.22), (x, -0.05, 0.92), "Rust", bevel=0.04)
        pl.cyl(lo, 0.5, 0.3, (x, -0.05, 0.62), "GunmetalDark", segs=10)                      # ankle
        # heavy foot: splayed forward toe, rust toe cap, grime skid
        pl.taper_box(lo, (1.45, 2.2), (1.2, 1.7), 0.0, 0.55, "GunmetalDark", top_offset=(0, 0.1), loc=(x, -0.42, 0))
        pl.box(lo, (1.5, 0.6, 0.5), (x, -1.35, 0.25), "Rust", bevel=0.08)
        pl.box(lo, (1.5, 2.1, 0.08), (x, -0.42, 0.04), "Grime", bevel=0)


def arms():
    P = K["P"]
    for s, n in ((1, "L"), (-1, "R")):
        a = P[f"Arm_{n}"]
        x = s * GUN_X
        pl.cog_joint(a, (s * SH_X, -0.15, SH_Z), (1, 0, 0), 0.55, 0.5, teeth=10)          # shoulder gear
        pl.taper_box(a, (0.8, 0.85), (0.9, 0.95), 3.95, 4.85, "Gunmetal", loc=(x, -0.15, 0))  # upper arm
        pl.cyl(a, 0.36, 0.95, (x, -0.3, 3.65), "GunmetalDark", pl.AX_X, segs=10)                # elbow axle
        pl.cog_joint(a, (x + s * 0.5, -0.3, 3.65), (1, 0, 0), 0.46, 0.16, teeth=10)        # elbow gear (outer face)
        # forearm cannon: chamfered housing, CogRed top armour, brass toothed collar, dark barrel + muzzle
        rings = [[(x + px, y, 3.65 + pz) for px, pz in ((-0.48, -0.4), (0.48, -0.4), (0.52, 0.3), (0.3, 0.52),
                                                         (-0.3, 0.52), (-0.52, 0.3))] for y in (0.05, -2.2)]
        pl.loft(a, rings, color="Gunmetal", bevel=0.04)
        pl.plate(a, 0.75, 1.7, 0.12, (x, -1.1, 4.22), (0, 0, 0), "CogRed", chamfer=0.2)
        pl.bolt_row(a, (x - 0.28, -0.4, 4.29), (x - 0.28, -1.8, 4.29), 4, (0, 0, 1), 0.05, "Brass")
        pl.bolt_row(a, (x + 0.28, -0.4, 4.29), (x + 0.28, -1.8, 4.29), 4, (0, 0, 1), 0.05, "Brass")
        pl.gear(a, 0.58, 0.48, 12, 0.18, (x, -2.25, 3.68), "Brass", pl.AX_Y)
        pl.cyl(a, 0.3, 1.45, (x, -2.95, 3.68), "GunmetalDark", pl.AX_Y, segs=10)
        pl.cyl(a, 0.38, 0.32, (x, -3.6, 3.68), "Gunmetal", pl.AX_Y, segs=8)
        pl.cyl(a, 0.2, 0.06, (x, -3.77, 3.68), "Oil", pl.AX_Y, segs=8, bevel=0)
        for i in range(3):                                                                   # heat fins
            pl.box(a, (0.08, 0.9, 0.22), (x + s * 0.55, -0.9 - i * 0.3, 3.7), "GunmetalDark", bevel=0)
        pl.pipe(a, [(x - s * 0.3, -0.4, 4.25), (x - s * 0.3, 0.2, 4.6), (s * SH_X, 0.2, 4.9)], 0.07)


def colorize():
    """Live preview only: give the unmerged pieces palette colours (slot i = swatch i, matching the face indices)."""
    k = K["kit"]
    mats = []
    for name, hx in k.palette:
        m = bpy.data.materials.get("sw_" + name) or bpy.data.materials.new("sw_" + name)
        m.diffuse_color = (*pl.srgb_to_linear(pl.hex_rgb(hx)), 1.0)
        mats.append(m)
    glow = bpy.data.materials.get("sw_glow") or bpy.data.materials.new("sw_glow")
    glow.diffuse_color = (1.0, 0.07, 0.01, 1.0)
    for p in k.parts:
        for ob in p.pieces:
            me = ob.data
            if len(me.materials) == 0:
                for m in (mats if p.textured else [glow]):
                    me.materials.append(m)
    for area in bpy.context.screen.areas:
        if area.type == 'VIEW_3D':
            sh = area.spaces[0].shading
            sh.type, sh.color_type = 'SOLID', 'MATERIAL'


def build_all():
    start()
    torso()
    head()
    legs()
    arms()
    return K["kit"]


def finish():
    k = K["kit"]
    k.build()
    k.report()
    return k


def export(root):
    """FBX + palette + manifest entry under root/art/fbx (kept separate from the repo manifest)."""
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'  # 1 BU = 1 stud in Roblox
    k = K["kit"]
    k.export_fbx()
    return k.manifest_entry()
