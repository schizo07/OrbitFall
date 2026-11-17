"""Tinker Drone (COG regular) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Same rig as the old tinker_rig.py so the game's code-driven poses keep working:
  Body (root) / Head / Eye (weak, Neon) / Leg_L|R_Upper / Leg_L|R_Lower / Arm_L|R, plus Glow (Neon ember).
Pivots in Blender coords (Roblox = (-bx, bz, by)): hip z 1.7, knee z 1.1, shoulders x +-1.5 z 3.0, head (0,-0.55,3.05).
The blaster is on Arm_R (x -1.85, z ~2.45, muzzle at y -3.0, like EnemyModels MESH_MUZZLE), Arm_L carries a wrench claw.
Blender: -Y is the front, Z up, feet at z = 0.

Run headless:  Blender -b --factory-startup --python cog_tinker.py -- <scratch root> [<repo root>]
Writes <scratch>/art/fbx/tinker_cog.fbx, <scratch>/tinker_cog.entry.json, <scratch>/tinker_cog_{front,back}.png
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

KEY = "tinker_cog"
HIP_Z, KNEE_Z = 1.7, 1.1
SH_X, SH_Z = 1.5, 3.0
GUN_X, GUN_Z = 1.85, 2.45          # blaster centre on Arm_R (blender x = -GUN_X)
HEAD_PIVOT = (0, -0.55, 3.05)
EYE_PIVOT = (0, -1.62, 3.55)

K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="regular", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 0.05, HIP_Z), color="Gunmetal")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 0.05, HIP_Z), parent="Body")
    P["Head"] = k.part("Head", "limb", "Metal", pivot=HEAD_PIVOT, parent="Body", color="Gunmetal")
    P["Eye"] = k.glow("Eye", role="weak", pivot=EYE_PIVOT, parent="Head")
    for s, n in ((1, "L"), (-1, "R")):
        x = s * 0.95
        P[f"Leg_{n}_Upper"] = k.part(f"Leg_{n}_Upper", "limb", "Metal", pivot=(x, 0.05, HIP_Z), parent="Body", color="Gunmetal")
        P[f"Leg_{n}_Lower"] = k.part(f"Leg_{n}_Lower", "limb", "Metal", pivot=(x, 0.05, KNEE_Z), parent=f"Leg_{n}_Upper", color="Gunmetal")
    # Arm_R sits at Blender x -1.5 (Roblox +1.5), Arm_L at +1.5
    for s, n in ((1, "L"), (-1, "R")):
        P[f"Arm_{n}"] = k.part(f"Arm_{n}", "limb", "Metal", pivot=(s * SH_X, -0.2, SH_Z), parent="Body", color="Gunmetal")
    K.clear()
    K.update(kit=k, P=P)
    return k


def torso():
    b, g = K["P"]["Body"], K["P"]["Glow"]
    # pelvis block + hip gears (rule 1: every joint is a gear)
    pl.box(b, (2.1, 1.15, 0.5), (0, 0.05, 1.9), "GunmetalDark", bevel=0.1)
    pl.box(b, (1.5, 0.22, 0.34), (0, -0.55, 1.85), "Rust", bevel=0.05)                  # grimy codpiece guard
    for s in (1, -1):
        pl.cog_joint(b, (s * 1.3, 0.05, HIP_Z), (1, 0, 0), 0.34, 0.14, teeth=8)
    # squat top-heavy torso: chamfered loft, widest at the shoulders
    rings = [pl.chamfer_rect(0.95, 0.62, 0.22, 2.1),
             [(x, y - 0.08, z) for x, y, z in pl.chamfer_rect(1.3, 0.78, 0.3, 2.65)],
             [(x, y - 0.06, z) for x, y, z in pl.chamfer_rect(1.2, 0.72, 0.28, 3.2)]]
    pl.loft(b, rings, color="Gunmetal", bevel=0.04)
    # chest: CogRed riveted plate + a small meshing gear pair, Cog Eye mark below
    pl.riveted_plate(b, 1.55, 0.62, 0.12, (0, -0.9, 2.62), (radians(90 + 4), 0, 0), "CogRed", "Brass",
                     spacing=0.5, chamfer=0.22, rivet_r=0.04)
    pl.gear(b, 0.26, 0.21, 8, 0.07, (-0.45, -1.0, 2.62), "Brass", pl.orient(Vector((0, -1, 0))))
    pl.gear(b, 0.16, 0.12, 6, 0.07, (-0.12, -1.0, 2.52), "Brass", pl.orient(Vector((0, -1, 0))))
    pl.cyl(b, 0.2, 0.05, (0.42, -1.0, 2.62), "GunmetalDark", pl.orient(Vector((0, -1, 0))), segs=8, bevel=0)  # blank dial
    pl.box(b, (1.7, 0.14, 0.1), (0, -0.82, 2.22), "Brass", bevel=0.02)                  # brass trim band
    # collar the head sits in
    pl.box(b, (1.45, 1.0, 0.25), (0, -0.4, 3.18), "GunmetalDark", bevel=0.06)
    # shoulder pauldrons: CogRed, brass edge strip
    for s in (1, -1):
        rot = (0, radians(s * 28), 0)
        pl.box(b, (0.62, 0.9, 0.32), (s * 1.42, -0.2, 3.28), "GunmetalDark", bevel=0.05)
        pl.loft(b, [[(x * 0.55, y, 0) for x, y, _ in pl.chamfer_rect(0.95, 0.78, 0.25, 0)],
                    [(x * 0.55, y, 0.3) for x, y, _ in pl.chamfer_rect(0.78, 0.62, 0.2, 0)]],
                loc=(s * 1.72, -0.2, 3.36), rot=rot, color="CogRed", bevel=0.03)
        pl.box(b, (0.8, 0.09, 0.09), (s * 1.72, -0.68, 3.34), "Brass", rot=rot, bevel=0.02)
    # back: small boiler drum, one smokestack with ember glow, copper feed pipe
    pl.box(b, (1.5, 0.35, 1.0), (0, 0.55, 2.65), "GunmetalDark", bevel=0.06)
    pl.steam_boiler(b, 0.42, 1.2, (0, 0.95, 2.6), rot=pl.AX_X, color="Rust", bands=2, segs=10)
    pl.smokestack(b, (0.45, 0.85, 2.95), 0.15, 0.85, glow=g, segs=8)
    pl.pipe(b, [(-0.45, 0.95, 2.95), (-0.8, 0.7, 2.95), (-0.95, 0.3, 2.85)], 0.06, sides=6)
    pl.vent_grille(b, 0.8, 0.4, 3, (0, 0.38, 2.15), (radians(-90), 0, 0), "GunmetalDark", "Soot", glow=g)


def head():
    h, e = K["P"]["Head"], K["P"]["Eye"]
    # big domed-box helm: the head is large for the body, fodder-bot look. CogRed brow hood over a single recessed Cog Eye lens
    pl.taper_box(h, (2.35, 2.0), (1.95, 1.65), 3.3, 4.2, "Gunmetal", loc=(0, -0.5, 0), top_offset=(0, -0.05))
    pl.taper_box(h, (2.1, 0.7), (1.8, 0.55), 3.85, 4.28, "CogRed", loc=(0, -0.92, 0))            # brow hood
    pl.box(h, (0.2, 1.1, 0.12), (0, -0.4, 4.3), "Brass", bevel=0.03)                              # crest bar
    pl.cog_eye(h, e, (0, -1.6, 3.55), normal=(0, -1, 0), r=0.38, hood=False)
    pl.box(h, (1.2, 0.2, 0.24), (0, -1.45, 3.42 - 0.3), "GunmetalDark", bevel=0.04)               # jaw grille
    for i in range(3):
        pl.box(h, (1.0, 0.05, 0.04), (0, -1.57, 3.06 + i * 0.07), "Soot", bevel=0)
    pl.gear(h, 0.36, 0.29, 8, 0.1, (0, 0.34, 3.8), "Brass", pl.AX_Y)                               # rear cooling gear
    pl.cyl(h, 0.12, 0.16, (0, 0.38, 3.8), "Soot", pl.AX_Y, segs=6, bevel=0)
    for s in (1, -1):
        pl.cog_joint(h, (s * 1.2, -0.45, 3.65), (1, 0, 0), 0.3, 0.12, teeth=8)                    # ear gears
    pl.antenna(h, (-0.6, 0.1, 4.2), 0.34, color="Steel")


def legs():
    P = K["P"]
    for s, n in ((1, "L"), (-1, "R")):
        x = s * 0.95
        u, lo = P[f"Leg_{n}_Upper"], P[f"Leg_{n}_Lower"]
        # thigh: stubby armoured segment, CogRed outer plate
        pl.taper_box(u, (0.8, 0.9), (0.7, 0.8), 1.2, 1.82, "Gunmetal", loc=(x, 0.05, 0))
        pl.plate(u, 0.5, 0.45, 0.08, (x + s * 0.4, 0.05, 1.55), (0, radians(s * 90), 0), "CogRed", chamfer=0.25)
        pl.piston(u, (x - s * 0.15, 0.5, 1.85), (x - s * 0.15, 0.5, 1.2), 0.07, "GunmetalDark")
        # knee: brass gear on the joint axis + knee guard (moves with the shin)
        pl.cog_joint(lo, (x + s * 0.0, 0.05, KNEE_Z), (1, 0, 0), 0.4, 0.62, teeth=8)
        pl.box(lo, (0.6, 0.24, 0.5), (x, -0.45, 1.05), "CogRed", rot=(radians(-12), 0, 0), bevel=0.05)
        # shin + ankle + chunky foot (rust toe cap)
        pl.taper_box(lo, (0.62, 0.7), (0.72, 0.78), 0.45, 1.05, "Gunmetal", loc=(x, 0.05, 0))
        pl.box(lo, (0.78, 0.82, 0.14), (x, 0.05, 0.55), "Rust", bevel=0.03)
        pl.taper_box(lo, (1.2, 1.7), (0.95, 1.3), 0.0, 0.45, "GunmetalDark", top_offset=(0, 0.05), loc=(x, -0.25, 0))
        pl.box(lo, (1.2, 0.45, 0.38), (x, -0.95, 0.2), "Rust", bevel=0.06)
        pl.box(lo, (1.2, 1.6, 0.06), (x, -0.3, 0.03), "Grime", bevel=0)


def arms():
    P = K["P"]
    # ---- Arm_R (blender -x): forward blaster
    a = P["Arm_R"]
    s = -1
    x = s * GUN_X
    pl.cog_joint(a, (s * SH_X, -0.2, SH_Z), (1, 0, 0), 0.42, 0.4, teeth=8)                      # shoulder gear
    pl.taper_box(a, (0.6, 0.7), (0.72, 0.8), 2.7, 3.3, "Gunmetal", loc=(x, -0.2, 0))                # upper arm
    rings = [[(x + px, y, GUN_Z + pz) for px, pz in ((-0.4, -0.34), (0.4, -0.34), (0.44, 0.26), (0.26, 0.44),
                                                       (-0.26, 0.44), (-0.44, 0.26))] for y in (0.05, -1.7)]
    pl.loft(a, rings, color="Gunmetal", bevel=0.03)                                                # cannon housing
    pl.plate(a, 0.6, 1.3, 0.1, (x, -0.85, GUN_Z + 0.44), (0, 0, 0), "CogRed", chamfer=0.2, bevel=0)
    pl.bolt_row(a, (x - 0.2, -0.3, GUN_Z + 0.5), (x - 0.2, -1.4, GUN_Z + 0.5), 3, (0, 0, 1), 0.045, "Brass")
    pl.bolt_row(a, (x + 0.2, -0.3, GUN_Z + 0.5), (x + 0.2, -1.4, GUN_Z + 0.5), 3, (0, 0, 1), 0.045, "Brass")
    pl.gear(a, 0.46, 0.38, 10, 0.16, (x, -1.75, GUN_Z), "Brass", pl.AX_Y)
    pl.cyl(a, 0.24, 1.1, (x, -2.35, GUN_Z), "GunmetalDark", pl.AX_Y, segs=8)
    pl.cyl(a, 0.32, 0.3, (x, -2.85, GUN_Z), "Gunmetal", pl.AX_Y, segs=8)
    pl.cyl(a, 0.17, 0.06, (x, -3.0, GUN_Z), "Oil", pl.AX_Y, segs=8, bevel=0)
    pl.cog_joint(a, (x + s * 0.45, -0.2, 2.8), (1, 0, 0), 0.28, 0.12, teeth=8)                  # elbow gear, outer face
    pl.pipe(a, [(x + 0.25, -0.2, GUN_Z + 0.35), (x + 0.2, 0.15, GUN_Z + 0.6), (s * SH_X + 0.15, 0.15, SH_Z + 0.2)], 0.05, sides=6)

    # ---- Arm_L (blender +x): upper arm + wrench claw hanging forward (the tinker's tool)
    a = P["Arm_L"]
    s = 1
    x = s * GUN_X
    pl.cog_joint(a, (s * SH_X, -0.2, SH_Z), (1, 0, 0), 0.42, 0.4, teeth=8)
    pl.taper_box(a, (0.6, 0.7), (0.72, 0.8), 2.5, 3.3, "Gunmetal", loc=(x, -0.2, 0))
    pl.cog_joint(a, (x + s * 0.4, -0.25, 2.5), (1, 0, 0), 0.34, 0.14, teeth=8)                  # elbow gear
    # forearm angled forward-down to the claw
    pl.rod(a, (x, -0.25, 2.5), (x, -1.15, 1.75), 0.26, "Gunmetal", segs=8)
    pl.box(a, (0.5, 0.18, 0.18), (x, -0.7, 2.2), "CogRed", rot=(radians(-40), 0, 0), bevel=0.03)
    # open-jaw wrench head: brass handle collar, CogRed jaws, dark nut inside the gap
    pl.cyl(a, 0.34, 0.24, (x, -1.15, 1.75), "Brass", pl.orient(Vector((0, -0.7, -0.7))), segs=8)
    pl.box(a, (0.46, 0.5, 0.7), (x, -1.45, 1.35), "Gunmetal", bevel=0.05)
    pl.box(a, (0.3, 0.7, 0.2), (x - 0.0, -1.7, 1.67), "CogRed", bevel=0.04)                     # upper jaw
    pl.box(a, (0.3, 0.7, 0.2), (x - 0.0, -1.7, 1.03), "CogRed", bevel=0.04)                     # lower jaw
    pl.cyl(a, 0.12, 0.3, (x, -1.8, 1.35), "GunmetalDark", pl.AX_X, segs=6, bevel=0)             # nut in the gap


def finish():
    k = K["kit"]
    k.build()
    k.report()
    return k


def build_all():
    start()
    torso()
    head()
    legs()
    arms()
    return K["kit"]


def export(root):
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'  # 1 BU = 1 stud in Roblox
    k = K["kit"]
    k.export_fbx()
    return k.manifest_entry()


def _relink_palette(k):
    img = bpy.data.images.get(f"palette_{k.palette_name}")
    k.image = img
    for p in k.parts:
        for n in p.obj.data.materials[0].node_tree.nodes:
            if n.type == 'TEX_IMAGE':
                n.image = img


def main():
    args = pl._argv()
    root = args[0] if args else "/private/tmp/orbitfall-tinker_cog"
    os.makedirs(root, exist_ok=True)
    k = build_all()
    finish()
    entry = export(root)
    with open(os.path.join(root, "tinker_cog.entry.json"), "w") as f:
        json.dump(entry, f, indent=2)
    print("ENTRY size", entry["size_studs_roblox_xyz"], "weak", entry["weak_spots"])
    for p in entry["parts"]:
        print("PART", p["name"], p["parent"], p["pivot"], p["triangles"])
    import env_set1
    _relink_palette(k)
    for name, d in (("front", (0.45, -1.0, 0.4)), ("back", (-0.5, 1.0, 0.45))):
        env_set1.stage(os.path.join(root, f"tinker_cog_{name}.png"), [k], size=(900, 900), cam_dir=d)


if __name__ == "__main__":
    main()
