"""Bastion Emplacement (COG heavy) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Replaces the part-built block in EnemyModels.buildBastion (11 x 11 footprint, ~10 studs tall, front = -Z Roblox = -Y Blender).
Zones (Enemies.BASTION): body armour 5, eye 1.5x, vent 2.5x armour 1 (rear heat sink, flankers shoot it).
Parts (Blender coords; Roblox = (-bx, bz, by)):
  Body     root, static base: footing plinth, corner anchors, toothed turret ring.           -> zone "body"
  Turret   parent Body, pivot on the yaw axis (0, 0, 2.2): armoured bunker, mantlet,
           twin cannons, roof boiler, stacks, antenna.                                      -> zone "body"
  Heatsink parent Turret (role weak, textured): light rear housing, fins, slats, pipes.      -> zone "vent"
  Vent     parent Turret (role weak, Neon): hot plate behind the slats.                      -> zone "vent"
  EyeL/EyeR parent Turret (role weak, Neon): glowing cannon bores, flare on wind-up.         -> zone "eye"
  Glow     parent Turret (role glow, Neon): stack embers, Cog Eye lens, beacon lamp.         -> zone "body"
Cannon muzzle mid-point (Blender) (0, -7.4, 5.7)  ==  EnemyModels MESH_MUZZLE BASTION Roblox (0, 5.7, -7.4).
Blender: -Y is the front, Z up, lowest point at z = 0.

Run headless:  blender -b --factory-startup --python cog_bastion.py -- [--out <scratch root>] [--nopreview]
"""
import json
import os
import shutil
import sys
from math import pi, cos, sin, radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
import parts_lib as pl
import bpy
from mathutils import Vector

KEY = "bastion_cog"
YAW_Z = 2.2                    # top of the turret ring: the Turret yaws about (0, 0, z)
GUN_X, GUN_Z = 1.7, 5.7        # cannon axes (Blender x = -Roblox x)
MUZZLE_Y = -7.4
VENT = (0.0, 4.75, 4.8)        # hot plate centre (rear)

K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="heavy", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 0, YAW_Z), color="GunmetalDark")
    P["Turret"] = k.part("Turret", "limb", "Metal", pivot=(0, 0, YAW_Z), parent="Body", color="Gunmetal")
    P["Heatsink"] = k.part("Heatsink", "weak", "Metal", pivot=(0, 0, YAW_Z), parent="Turret", color="Rust")
    P["Vent"] = k.glow("Vent", role="weak", pivot=VENT, parent="Turret")
    P["EyeL"] = k.glow("EyeL", role="weak", pivot=(GUN_X, -6.9, GUN_Z), parent="Turret")
    P["EyeR"] = k.glow("EyeR", role="weak", pivot=(-GUN_X, -6.9, GUN_Z), parent="Turret")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 0, YAW_Z), parent="Turret")
    K.clear()
    K.update(kit=k, P=P)
    return k


def base():
    """Static footing: chamfered plinth, anchor feet, toothed turret ring."""
    b = K["P"]["Body"]
    pl.loft(b, [pl.chamfer_rect(5.5, 5.5, 0.9, 0.0), pl.chamfer_rect(5.5, 5.5, 0.9, 0.55),
                pl.chamfer_rect(5.25, 5.25, 0.75, 1.55)], color="GunmetalDark", bevel=0.05)
    # grime skid + rust band on the lower edge, brass trim band under the ring
    for s in (1, -1):
        pl.box(b, (11.06, 0.12, 0.42), (0, s * 5.52, 0.3), "Grime", bevel=0)
        pl.box(b, (0.12, 10.9, 0.42), (s * 5.52, 0, 0.3), "Grime", bevel=0)
    # top deck the ring sits on
    pl.loft(b, [pl.chamfer_rect(4.9, 4.9, 0.9, 1.55), pl.chamfer_rect(4.55, 4.55, 0.8, 1.95)],
            color="Gunmetal", bevel=0.04)
    # anchor feet at the corners (bolted down to the rock)
    for sx in (1, -1):
        for sy in (1, -1):
            pl.box(b, (1.5, 1.5, 0.5), (sx * 4.7, sy * 4.7, 0.7), "Gunmetal", rot=(0, 0, radians(45)), bevel=0.08)
            pl.bolt_ring(b, (sx * 4.7, sy * 4.7, 0.96), (0, 0, 1), 0.46, 4, 0.1, "Brass")
    # side stair step / cable runs so the plinth reads built, not a block
    for s in (1, -1):
        pl.cable(b, (s * 4.8, -2.2, 1.7), (s * 5.4, 1.6, 0.6), 0.1, sag=0.25, color="Oil")
    # toothed turret ring: the superstructure turns on it
    pl.cyl(b, 4.25, 0.35, (0, 0, 2.02), "GunmetalDark", segs=16)
    pl.gear(b, 4.75, 4.5, 20, 0.22, (0, 0, 1.98), "Brass")


def hull():
    t, g = K["P"]["Turret"], K["P"]["Glow"]
    # chamfered bunker block: mass sits high, the roof is narrower than the shoulders
    rings = [pl.chamfer_rect(4.3, 4.1, 0.85, YAW_Z), pl.chamfer_rect(4.5, 4.3, 0.95, 5.0),
             pl.chamfer_rect(3.8, 3.4, 0.8, 7.7)]
    pl.loft(t, rings, color="Gunmetal", bevel=0.05)
    pl.box(t, (7.6, 7.2, 0.2), (0, 0.2, 2.35), "Rust", bevel=0.04)                  # grimy skirt where it meets the ring
    pl.box(t, (8.2, 7.8, 0.14), (0, 0, 2.95), "Brass", bevel=0.02)                  # brass trim band
    # roof slab with a stripe and a service hatch
    pl.loft(t, [pl.chamfer_rect(3.95, 3.55, 0.8, 7.7), pl.chamfer_rect(3.5, 3.1, 0.7, 8.15)],
            color="GunmetalDark", bevel=0.04)
    pl.box(t, (7.2, 0.7, 0.1), (0, -1.55, 8.2), "Rust", bevel=0)
    pl.hatch(t, 1.5, 1.1, (-1.55, 0.2, 8.2), (0, 0, 0), "Gunmetal", "Brass", "Brass")
    pl.cyl(t, 0.55, 0.22, (1.5, -0.2, 8.28), "GunmetalDark", segs=8)                # periscope stub
    pl.cyl(t, 0.32, 0.5, (1.5, -0.2, 8.6), "Steel", segs=8)
    pl.cog_eye(t, g, (1.5, -0.5, 8.78), normal=(0, -1, 0.25), r=0.24, hood=True)

    # lower front: CogRed riveted armour, gear cluster off-centre (rule 2)
    pl.riveted_plate(t, 6.9, 1.85, 0.2, (0, -4.34, 3.55), (radians(86), 0, 0), "CogRed", "Brass",
                     spacing=0.7, chamfer=0.14, rivet_segs=4)
    pl.gear_cluster(t, (-2.3, -4.5, 3.55), (radians(86), 0, 0), R=0.45, t=0.09)
    # side armour plates, one gear cluster each
    for s in (1, -1):
        rot = (0, radians(s * 90 - s * 3), 0)
        pl.riveted_plate(t, 2.7, 5.6, 0.22, (s * 4.52, 0.1, 3.95), rot, "CogRed", "Brass",
                         spacing=0.85, chamfer=0.14, rivet_segs=4)
        pl.gear_cluster(t, (s * 4.68, -1.4, 3.95), rot, R=0.55, t=0.09)
        # shoulder fins above the plate, slanting with the roof
        pl.box(t, (0.2, 5.4, 0.28), (s * 4.14, 0.1, 5.7), "Brass", rot=(0, radians(-s * 8), 0), bevel=0.02)
        pl.bolt_row(t, (s * 4.22, -2.2, 5.9), (s * 4.22, 2.4, 5.9), 5, (s, 0, 0.3), 0.08, "Brass")

    # mantlet: heavy box with a CogRed brow, brass collar sockets, faction mark between the cannons
    pl.box(t, (6.9, 1.8, 2.6), (0, -4.45, GUN_Z), "Gunmetal", bevel=0.14)
    pl.plate(t, 6.9, 1.9, 0.22, (0, -4.55, 7.06), (radians(-6), 0, 0), "CogRed", chamfer=0.14)
    pl.bolt_row(t, (-3.0, -3.95, 7.2), (3.0, -3.95, 7.2), 6, (0, 0, 1), 0.07, "Brass")
    pl.box(t, (7.1, 0.2, 0.2), (0, -5.38, 4.45), "Brass", bevel=0.02)               # brass sill
    pl.cog_mark(t, g, (0, -5.38, GUN_Z), r=0.52)
    # left / right cannons: socket collar + toothed ring + barrel + flared muzzle with the Eye glow inside
    for s, nm in ((1, "EyeL"), (-1, "EyeR")):
        x, e = s * GUN_X, K["P"][nm]
        pl.cyl(t, 0.8, 0.5, (x, -5.5, GUN_Z), "GunmetalDark", pl.AX_Y, segs=10)
        pl.gear(t, 1.0, 0.82, 12, 0.18, (x, -5.74, GUN_Z), "Brass", pl.AX_Y)
        pl.cyl(t, 0.52, 1.2, (x, -6.35, GUN_Z), "GunmetalDark", pl.AX_Y, segs=10)
        for i, yy in enumerate((-6.1, -6.7)):
            pl.cyl(t, 0.62, 0.16, (x, yy, GUN_Z), "Rust", pl.AX_Y, segs=10, bevel=0)  # barrel bands
        # muzzle bell: lip at y = -7.9
        pl.lathe(t, [(0, 0.0), (0.4, 0.0), (0.34, 0.1), (0.84, 1.15), (0.7, 1.15), (0.34, 0.25), (0, 0.25)],
                 (x, -6.75, GUN_Z), "Gunmetal", pl.orient((0, -1, 0)), segs=10)
        pl.cyl(e, 0.48, 0.06, (x, -7.3, GUN_Z), rot=pl.AX_Y, segs=10, bevel=0)       # eye: glow sunk inside the bell
        pl.pipe(t, [(x + s * 0.75, -5.2, GUN_Z + 0.9), (x + s * 1.5, -4.9, GUN_Z + 0.6),
                    (s * 2.7, -4.4, GUN_Z - 0.6)], 0.09)


def top():
    t, g = K["P"]["Turret"], K["P"]["Glow"]
    # roof boiler feeding the guns, two smokestacks with embers, copper feeds
    pl.box(t, (3.4, 0.5, 0.35), (0, 2.1, 8.3), "GunmetalDark", bevel=0.06)           # saddle
    pl.steam_boiler(t, 0.78, 3.0, (0, 2.1, 9.05), rot=pl.AX_X, color="Rust", bands=3)
    for s in (-1, 1):
        pl.smokestack(t, (s * 2.7, 1.0, 8.15), 0.38, 1.55, glow=g)
        pl.pipe(t, [(s * 1.7, 2.1, 9.1), (s * 2.5, 2.0, 9.1), (s * 2.7, 1.3, 8.7)], 0.1)
    pl.gauge(t, (0.0, 1.78, 9.1), (0, -1, 0), 0.26)
    pl.whistle(t, (-1.0, 2.1, 9.8), 0.35)
    # beacon mast
    pl.antenna(t, (-2.7, -1.9, 8.15), 2.2, color="Steel")
    pl.lamp(t, g, (-2.7, -1.9, 10.4), normal=(0, 0, 1), r=0.22, color="GunmetalDark")


def heatsink():
    """Rear weak spot: a light, rusty sheet-metal housing hung on the back wall (armour 1), hot plate behind slats."""
    h, v = K["P"]["Heatsink"], K["P"]["Vent"]
    # housing: back plate, top / bottom / side cheeks (open towards +Y), light RustDark skin
    pl.box(h, (6.0, 1.7, 0.35), (0, 4.75, 6.55), "RustDark", bevel=0.05)             # hood
    pl.box(h, (6.0, 1.7, 0.35), (0, 4.75, 3.05), "RustDark", bevel=0.05)             # sill
    for s in (1, -1):
        pl.box(h, (0.35, 1.7, 3.8), (s * 2.95, 4.75, 4.8), "RustDark", bevel=0.05)
    pl.box(h, (5.6, 0.2, 3.3), (0, 4.05, 4.8), "Rust", bevel=0.03)                   # backing sheet
    # slats over the hot plate (vent_grille puts the plate behind the slats in `Vent`)
    pl.vent_grille(h, 5.2, 3.0, 4, (0, 5.52, 4.8), (radians(-90), 0, 0), "RustDark", "Gunmetal", glow=v, depth=0.5)
    # heat-sink fins on the hood and a stub radiator row down each cheek
    for i in range(7):
        x = -2.4 + i * 0.8
        pl.box(h, (0.14, 1.5, 1.15), (x, 4.6, 7.15), "Rust", bevel=0.02)
    for s in (1, -1):
        for i in range(4):
            pl.box(h, (0.9, 1.3, 0.1), (s * 3.55, 4.6, 3.6 + i * 0.7), "Rust", bevel=0)
    # pipes from the housing up to the roof boiler
    for s in (1, -1):
        pl.pipe(h, [(s * 1.4, 5.1, 6.7), (s * 1.4, 5.35, 7.6), (s * 1.0, 3.9, 8.55), (s * 1.0, 2.7, 9.0)], 0.1)
    # warning stencil above the vent
    pl.stencil_panel(h, 1.8, 0.5, (0, 5.65, 6.75), (radians(-90), 0, 0), "Gunmetal", "Brass")
    # a brass bolt row on the hood (polished by the machinery)
    pl.bolt_row(h, (-2.7, 5.2, 6.74), (2.7, 5.2, 6.74), 6, (0, 0, 1), 0.07, "Brass")


def build_all():
    k = start()
    base()
    hull()
    top()
    heatsink()
    return k


def export(root):
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'  # 1 BU = 1 stud in Roblox
    k = K["kit"]
    k.export_fbx()
    return k.manifest_entry()


def main(scratch, repo, previews=True):
    import importlib.util
    os.makedirs(scratch, exist_ok=True)
    k = build_all()
    k.build()
    lo, _ = k.bbox()
    warn = k.report()
    entry = export(scratch)
    out_dir = os.path.join(repo, "art", "fbx", "cog")
    os.makedirs(out_dir, exist_ok=True)
    shutil.copy(os.path.join(scratch, "art", "fbx", f"{KEY}.fbx"), os.path.join(out_dir, f"{KEY}.fbx"))
    with open(os.path.join(out_dir, f"{KEY}.entry.json"), "w", encoding="utf-8") as f:
        json.dump(entry, f, indent=2)
    if previews:
        spec = importlib.util.spec_from_file_location("env_set1", os.path.join(HERE, "env_set1.py"))
        env = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(env)
        img_dir = os.path.join(repo, "art", "images")
        os.makedirs(img_dir, exist_ok=True)
        for name, cam in (("front", (0.45, -1.0, 0.45)), ("back", (-0.45, 1.0, 0.45))):
            env.stage(os.path.join(img_dir, f"{KEY}_{name}.png"), [k], size=(900, 900), cam_dir=cam)
            img = bpy.data.images.get(f"palette_{k.palette_name}")
            for p in k.parts:
                for nd in p.obj.data.materials[0].node_tree.nodes:
                    if nd.type == 'TEX_IMAGE':
                        nd.image = img
    return k, warn


if __name__ == "__main__":
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    scratch = "/private/tmp/orbitfall-bastion_cog"
    if "--out" in a:
        scratch = a[a.index("--out") + 1]
    repo = os.path.normpath(os.path.join(HERE, "..", ".."))
    main(scratch, repo, previews="--nopreview" not in a)
