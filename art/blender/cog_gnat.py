"""Gnat Drone (DRONE_COG, key gnat_cog) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Replaces the Part-built rotor gnat in server/Enemies/DroneAI.luau (ball body, eye up front, cross arm with two rotors,
gun under the chin). Same layout: front = -Y (Roblox -Z), eye up front, arm + rotors on top, gun under the chin.
Zones (Data/Enemies DRONE_COG): body -> Body (+ RotorL / RotorR), eye -> Eye (role weak, Neon). Glow = embers + Cog Eye lens (no zone).
RotorL / RotorR are brass gears on a limb pivot so the client can spin them (axis = up) instead of the old blur anchors.
Lowest point at z = 0 (hover height is code's job).

Run headless:  Blender -b --factory-startup --python cog_gnat.py -- <scratch root> [<image dir>]
"""
import json
import os
import sys
from math import radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector

KEY = "gnat_cog"
ROT_X, ROT_Z = 1.55, 2.95          # rotor gear centre (x +-, z); pivot of RotorL / RotorR
K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="regular", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 0, 1.45), color="Gunmetal")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 0, 1.45), parent="Body")
    P["Eye"] = k.glow("Eye", role="weak", pivot=(0, -1.05, 1.5), parent="Body")
    P["RotorL"] = k.part("RotorL", "limb", "Metal", pivot=(ROT_X, 0, ROT_Z), parent="Body", color="Brass")
    P["RotorR"] = k.part("RotorR", "limb", "Metal", pivot=(-ROT_X, 0, ROT_Z), parent="Body", color="Brass")
    K.clear()
    K.update(kit=k, P=P)
    return k


def hull():
    b, g, e = K["P"]["Body"], K["P"]["Glow"], K["P"]["Eye"]
    # squat chamfered hull, mass high and forward (old ball: 2.3 across, centre ~1.2)
    rings = [pl.chamfer_rect(0.7, 0.72, 0.3, 0.75),
             [(x, y - 0.03, z) for x, y, z in pl.chamfer_rect(1.08, 1.05, 0.4, 1.3)],
             [(x, y - 0.05, z) for x, y, z in pl.chamfer_rect(1.05, 1.0, 0.38, 2.05)],
             [(x, y - 0.08, z) for x, y, z in pl.chamfer_rect(0.78, 0.72, 0.28, 2.4)]]
    pl.loft(b, rings, color="Gunmetal", bevel=0.05)
    pl.box(b, (1.3, 0.14, 0.18), (0, -1.0, 0.98), "Brass", bevel=0.02)               # brass trim band under the eye
    # CogRed armour: top cap with a brow hood over the eye, side panels (one carries the gear cluster)
    pl.taper_box(b, (1.9, 1.7), (1.45, 1.25), 2.38, 2.62, "CogRed", top_offset=(0, -0.05), loc=(0, 0.0, 0))
    pl.taper_box(b, (1.5, 0.6), (1.3, 0.5), 1.95, 2.2, "CogRed", loc=(0, -1.0, 0))       # brow hood
    for s in (1, -1):
        pl.plate(b, 1.2, 0.9, 0.1, (s * 1.1, 0.15, 1.55), (0, radians(s * 90), 0), "CogRed", chamfer=0.3)
        pl.bolt_row(b, (s * 1.16, -0.25, 1.9), (s * 1.16, 0.55, 1.9), 3, (s, 0, 0), 0.05, "Brass")
    pl.gear_cluster(b, (-1.17, 0.2, 1.55), (0, radians(-90), 0), R=0.3, t=0.08)
    # Cog Eye socket (weak spot): raised brass ring, dark lens, glow set back inside the rim (not flat on the surface)
    n = Vector((0, -1, 0))
    o = Vector((0, -1.06, 1.45))
    pl.cyl(b, 0.64, 0.1, o, "GunmetalDark", pl.orient(n), segs=10, bevel=0)
    pl.torus(b, 0.56, 0.15, o + n * 0.2, "Brass", pl.orient(n), segs=10, csegs=4)
    pl.cyl(b, 0.47, 0.06, o + n * 0.07, "Lens", pl.orient(n), segs=10, bevel=0)
    pl.cyl(e, 0.38, 0.1, o + n * 0.1, rot=pl.orient(n), segs=10, bevel=0)
    # drive gear + cross arm (rotating hardware gets teeth)
    pl.cyl(b, 0.34, 0.45, (0, 0, 2.7), "GunmetalDark", segs=8)
    pl.gear(b, 0.5, 0.4, 8, 0.12, (0, 0, 2.52), "Brass")
    pl.box(b, (2 * ROT_X + 0.3, 0.34, 0.3), (0, 0, 2.82), "GunmetalDark", bevel=0.05)
    for s in (1, -1):
        pl.cyl(b, 0.17, 0.3, (s * ROT_X, 0, 2.75), "Gunmetal", segs=8)              # rotor axle stub
        pl.box(b, (0.3, 0.5, 0.3), (s * 1.05, 0, 2.7), "Rust", bevel=0.03)
    # gun under the chin: mount, brass toothed collar, dark barrel, recessed muzzle
    pl.box(b, (0.7, 1.0, 0.3), (0, -0.55, 0.68), "GunmetalDark", bevel=0.06)
    pl.gear(b, 0.34, 0.27, 8, 0.14, (0, -0.95, 0.55), "Brass", pl.AX_Y)
    pl.cyl(b, 0.2, 1.0, (0, -1.0, 0.55), "GunmetalDark", pl.AX_Y, segs=8)
    pl.cyl(b, 0.27, 0.22, (0, -1.5, 0.55), "Gunmetal", pl.AX_Y, segs=8)
    pl.cyl(b, 0.13, 0.05, (0, -1.62, 0.55), "Oil", pl.AX_Y, segs=8, bevel=0)
    # skids (it hovers, but it is a machine): two rust-footed runners on short struts
    for s in (1, -1):
        pl.box(b, (0.22, 1.5, 0.14), (s * 0.6, 0.0, 0.07), "Rust", bevel=0.02)
        pl.box(b, (0.16, 0.16, 0.6), (s * 0.6, 0.3, 0.4), "GunmetalDark", bevel=0.02)
    # back: ember stack, thruster bell, copper feed pipe, whip antenna
    pl.smokestack(b, (0.55, 0.8, 1.85), 0.18, 0.95, glow=g)
    pl.nozzle(b, g, (0, 1.0, 1.15), (0, 1, 0), 0.34, 0.45, "GunmetalDark", "Soot")
    pl.pipe(b, [(0.4, 0.9, 1.7), (0.75, 0.55, 2.35), (0.55, 0.0, 2.55)], 0.07)
    pl.antenna(b, (-0.5, 0.55, 2.55), 0.7, color="Steel")
    pl.vent_grille(b, 0.7, 0.4, 3, (-0.1, 1.02, 1.8), (radians(-90), 0, 0), "GunmetalDark", "Soot", glow=g)


def rotors():
    for s, n in ((1, "RotorL"), (-1, "RotorR")):
        r = K["P"][n]
        c = (s * ROT_X, 0, ROT_Z)
        # brass rotor gear (a gear IS the rotor), hub cap with a CogRed centre, a dark under-ring
        pl.gear(r, 0.68, 0.52, 8, 0.12, c, "Brass")
        pl.cyl(r, 0.22, 0.2, (c[0], 0, c[2] + 0.04), "Gunmetal", segs=8)
        pl.cyl(r, 0.12, 0.28, (c[0], 0, c[2] + 0.04), "CogRed", segs=6, bevel=0)
        pl.cyl(r, 0.4, 0.07, (c[0], 0, c[2] - 0.1), "GunmetalDark", segs=8, bevel=0)


def build_all():
    start()
    hull()
    rotors()
    k = K["kit"]
    k.ground()
    return k


def finish():
    k = K["kit"]
    k.build()
    k.report()
    return k


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
    root = args[0] if args else "/private/tmp/orbitfall-gnat-courier"
    img_dir = args[1] if len(args) > 1 else root
    os.makedirs(root, exist_ok=True)
    k = build_all()
    finish()
    entry = export(root)
    with open(os.path.join(root, f"{KEY}.entry.json"), "w") as f:
        json.dump(entry, f, indent=2)
    print("ENTRY size", entry["size_studs_roblox_xyz"], "weak", entry["weak_spots"])
    for p in entry["parts"]:
        print("PART", p["name"], p["role"], p["parent"], p["pivot"], p["triangles"])
    lo, hi = k.bbox()
    print("BBOX", [round(v, 2) for v in lo], [round(v, 2) for v in hi])
    import env_set1
    _relink_palette(k)
    for name, d in (("front", (0.45, -1.0, 0.4)), ("back", (-0.5, 1.0, 0.45))):
        env_set1.stage(os.path.join(img_dir, f"{KEY}_{name}.png"), [k], size=(900, 900), cam_dir=d)


if __name__ == "__main__":
    main()
