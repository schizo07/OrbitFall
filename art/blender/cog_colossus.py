"""Strider Colossus (COG behemoth) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Same rig as the old colossus_rig.py so the game's code-driven walk / weak-spot logic keeps working:
  Body (root) / Core (weak, Neon, rear) / Glow (Neon embers + lenses) /
  Leg_n_Upper (hip -> knee) / Joint_n (weak, Neon knee hub) / Leg_n_Lower (knee -> foot), n = 1..4.
Numbering (Roblox): 1 = right front, 2 = left front, 3 = right rear, 4 = left rear (left = +X in Blender).
Pivots (Blender coords; Roblox = (-bx, bz, by)): hips (+-5.2, +-5.8, 13), knees (+-8.3, +-8.9, 8), core (0, 8.65, 16).
Blender: -Y is the front, Z up, feet at z = 0 (never shifted: pivots stay exactly as listed).

Run headless:  blender -b --factory-startup --python cog_colossus.py -- [--out <scratch root>]
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

KEY = "colossus_cog"
HIP_Z, KNEE_Z = 13.0, 8.0
HIP_X, HIP_Y = 5.2, 5.8
KNEE_X, KNEE_Y = 8.3, 8.9
ANK_X, ANK_Y, ANK_Z = 9.2, 9.9, 1.7
LEGS = {1: (-1, -1), 2: (1, -1), 3: (-1, 1), 4: (1, 1)}      # n -> (sx, sy) in Blender

K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="behemoth", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 0, 13), color="Gunmetal")
    P["Core"] = k.glow("Core", role="weak", pivot=(0, 8.65, 16), parent="Body")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 0, 13), parent="Body")
    for n, (sx, sy) in LEGS.items():
        hip = (sx * HIP_X, sy * HIP_Y, HIP_Z)
        knee = (sx * KNEE_X, sy * KNEE_Y, KNEE_Z)
        P[f"Leg_{n}_Upper"] = k.part(f"Leg_{n}_Upper", "limb", "Metal", pivot=hip, parent="Body", color="Gunmetal")
        P[f"Joint_{n}"] = k.glow(f"Joint_{n}", role="weak", pivot=knee, parent=f"Leg_{n}_Upper")
        P[f"Leg_{n}_Lower"] = k.part(f"Leg_{n}_Lower", "limb", "Metal", pivot=knee, parent=f"Leg_{n}_Upper", color="Gunmetal")
    K.clear()
    K.update(kit=k, P=P)
    return k


# ------------------------------------------------------------------ local helpers
def ring_gear(part, r_tip, r_root, r_in, teeth, thick, loc, axis, color="Brass"):
    """Toothed ring (gear with a big hole): the glowing knee hub shows through the middle."""
    p = 2 * pi / teeth
    outer, inner = [], []
    for i in range(teeth):
        a = i * p
        for f, r in ((0.0, r_root), (0.18, r_tip), (0.48, r_tip), (0.66, r_root)):
            outer.append((r * cos(a + f * p), r * sin(a + f * p)))
            inner.append((r_in * cos(a + f * p), r_in * sin(a + f * p)))
    h = thick / 2
    rings = [[(x, y, -h) for x, y in outer], [(x, y, h) for x, y in outer],
             [(x, y, h) for x, y in inner], [(x, y, -h) for x, y in inner]]
    return pl.loft(part, rings, loc, color, pl.orient(axis), cap=False, closed=True)


def sleeve(part, p0, p1, r0, r1, color, band="Brass", segs=8, rivets=0, rivet_r=0.2):
    """Chamfered octagonal armour sleeve between two points with brass end bands (+ optional rivet rings)."""
    p0, p1 = Vector(p0), Vector(p1)
    d = (p1 - p0).normalized()
    pl.rod(part, p0, p1, r0, color, segs=segs, r2=r1, bevel=0.15)
    for p, r in ((p0, r0), (p1, r1)):
        pl.cyl(part, r * 1.05, 0.28, p, band, pl.orient(d), segs=segs, bevel=0)
        if rivets:
            n = d if p is p0 else -d
            t1 = n.orthogonal().normalized()
            t2 = n.cross(t1)
            for i in range(rivets):
                a = 2 * pi * i / rivets
                pl.bolt(part, p + n * 0.14 + (t1 * cos(a) + t2 * sin(a)) * r * 0.95, n, rivet_r, band, segs=4)


# ------------------------------------------------------------------ body
def torso():
    b, g = K["P"]["Body"], K["P"]["Glow"]
    AX = pl.AX_X
    # belly slab + hull (chamfered octagon sections, mass high)
    pl.box(b, (10.2, 12.4, 1.0), (0, 0.3, 12.1), "GunmetalDark", bevel=0.3)
    rings = [pl.chamfer_rect(6.2, 7.0, 1.4, 12.4), pl.chamfer_rect(6.8, 7.9, 1.6, 13.4),
             pl.chamfer_rect(6.8, 7.9, 1.6, 18.0), pl.chamfer_rect(6.1, 7.2, 1.4, 19.0)]
    pl.loft(b, [[(x, y + 0.3, z) for x, y, z in r] for r in rings], color="Gunmetal", bevel=0.1)
    pl.box(b, (12.4, 0.5, 0.5), (0, -7.85, 18.3), "Brass", bevel=0.08)         # brass brow band over the glacis
    pl.box(b, (9.6, 1.3, 1.0), (0, -7.9, 12.9), "Rust", bevel=0.15)            # grimy front bumper
    # glacis: CogRed riveted plate, gear cluster on the left third, Cog Eye (faction mark) right
    pl.riveted_plate(b, 11.2, 4.2, 0.4, (0, -7.8, 15.7), (radians(90), 0, 0), "CogRed", "Brass",
                     spacing=1.5, chamfer=0.14, rivet_r=0.2, rivet_segs=4, bevel=0)
    pl.gear_cluster(b, (-3.3, -8.0, 15.5), (radians(90), 0, 0), R=1.35, t=0.3)
    pl.cog_mark(b, g, (3.4, -8.0, 15.7), (0, -1, 0), r=1.5)
    # side armour panels with gear clusters (between the hip gearboxes)
    for s in (1, -1):
        rot = pl.basis((0, s, 0), (s, 0, 0))
        pl.riveted_plate(b, 6.4, 4.2, 0.4, (s * 7.0, 0.3, 15.8), rot, "CogRed", "Brass",
                         spacing=1.6, chamfer=0.14, rivet_r=0.2, rivet_segs=4, bevel=0)
        pl.gear_cluster(b, (s * 7.2, -0.8, 15.4), rot, R=1.15, t=0.3, third=False)
        for z in (13.55, 18.05):
            pl.box(b, (0.3, 6.6, 0.3), (s * 6.95, 0.3, z), "Brass", bevel=0)
    # top deck armour (CogRed, riveted)
    for s in (1, -1):
        pl.riveted_plate(b, 1.7, 7.4, 0.3, (s * 5.0, -2.2, 19.0), (0, 0, 0), "CogRed", "Brass",
                         spacing=1.5, chamfer=0.12, rivet_r=0.18, rivet_segs=4, bevel=0)
    # turret: toothed ring, chamfered drum, brow hood over a visor slit with three lenses
    pl.cyl(b, 3.9, 0.7, (0, 0, 19.35), "GunmetalDark", segs=16)
    pl.gear(b, 4.35, 3.85, 12, 0.4, (0, 0, 19.8), "Brass")
    rings = [pl.chamfer_rect(3.3, 3.2, 1.0, 20.0), pl.chamfer_rect(3.3, 3.2, 1.0, 20.9),
             pl.chamfer_rect(2.7, 2.7, 0.9, 21.5)]
    pl.loft(b, rings, color="Gunmetal", bevel=0.1)
    pl.visor_slot(b, g, 3.2, 0.62, (0, -3.2, 20.5), lenses=3)
    pl.taper_box(b, (4.2, 1.5), (3.6, 1.1), 20.95, 21.5, "CogRed", loc=(0, -2.5, 0), bevel=0.08)       # brow hood
    for s in (1, -1):
        pl.box(b, (0.3, 2.4, 0.8), (s * 3.4, 0.2, 20.5), "GunmetalDark", bevel=0.05)          # side vent slot
        pl.box(b, (0.2, 2.0, 0.25), (s * 3.52, 0.2, 20.5), "Soot", bevel=0)
    # laser emitter on top: hex pedestal, flared horn with a recessed lens, brass lip, fins
    pl.cyl(b, 1.5, 0.4, (0, 0, 21.7), "GunmetalDark", segs=8)
    pl.lathe(b, [(0.9, 21.9), (1.0, 22.0), (1.95, 22.5), (1.6, 22.5), (0.65, 22.0), (0, 22.0)],
             (0, 0, 0), "Gunmetal", segs=8)
    pl.torus(b, 1.78, 0.16, (0, 0, 22.5), "Brass", segs=8, csegs=4)
    pl.cyl(g, 0.55, 0.12, (0, 0, 22.08), segs=8, bevel=0)
    for i in range(4):
        a = i * pi / 2 + pi / 4
        pl.box(b, (0.2, 0.9, 0.6), (cos(a) * 1.15, sin(a) * 1.15, 21.95), "Rust",
               pl.orient((0, 0, 1)), bevel=0)
    # rear boiler across the deck, twin smokestacks with ember glow, copper pipes down to the core frame
    pl.steam_boiler(b, 1.3, 6.2, (0, 5.7, 20.3), rot=AX, color="Rust", bands=3, rivets=False, segs=10)
    for s in (1, -1):
        pl.smokestack(b, (s * 4.7, 5.7, 19.0), 1.0, 3.4, glow=g, segs=8)
        pl.pipe(b, [(s * 3.2, 5.7, 20.9), (s * 3.9, 5.7, 21.3), (s * 4.2, 5.7, 21.0)], 0.2)
        pl.pipe(b, [(s * 2.2, 6.9, 19.9), (s * 2.2, 9.1, 19.3), (s * 2.2, 9.6, 17.2)], 0.28)
    # core recess frame: sill, posts, hood, louvres in front of the glow (the glow itself is the Core part)
    for s in (1, -1):
        pl.box(b, (0.9, 1.5, 4.6), (s * 3.95, 8.95, 16.0), "GunmetalDark", bevel=0.12)
        pl.cog_joint(b, (s * 3.95, 9.85, 17.6), (0, 1, 0), 0.55, 0.3, teeth=8)
    pl.box(b, (9.0, 1.5, 0.9), (0, 8.95, 14.1), "GunmetalDark", bevel=0.12)
    pl.box(b, (9.0, 1.7, 0.9), (0, 8.95, 17.9), "CogRed", bevel=0.12)
    for z in (15.1, 16.0, 16.9):
        pl.box(b, (6.6, 0.3, 0.3), (0, 9.5, z), "GunmetalDark", bevel=0.03)
    pl.box(b, (8.9, 0.3, 0.2), (0, 9.7, 13.6), "Brass", bevel=0.03)
    # rear radiator fins on the roof edge
    for i in range(6):
        pl.box(b, (0.4, 1.8, 1.8), (-2.5 + i, 7.4, 19.8), "GunmetalDark", bevel=0.05)


def core():
    c = K["P"]["Core"]
    pl.box(c, (6.6, 0.6, 2.9), (0, 8.65, 16.0), bevel=0.2)       # glowing furnace behind the louvres


# ------------------------------------------------------------------ legs
def legs():
    P = K["P"]
    for n, (sx, sy) in LEGS.items():
        u, j, lo = P[f"Leg_{n}_Upper"], P[f"Joint_{n}"], P[f"Leg_{n}_Lower"]
        H = Vector((sx * HIP_X, sy * HIP_Y, HIP_Z))
        Kn = Vector((sx * KNEE_X, sy * KNEE_Y, KNEE_Z))
        A = Vector((sx * ANK_X, sy * ANK_Y, ANK_Z))
        d = (Kn - H).normalized()
        # ---- Upper: hip gearbox, thigh, red sleeve, ram, knee cap
        pl.cyl(u, 2.7, 2.8, (sx * 5.6, H.y, HIP_Z), "GunmetalDark", pl.AX_X, segs=10)
        pl.cog_joint(u, (sx * 7.35, H.y, HIP_Z), (1, 0, 0), 2.4, 0.55, teeth=10)
        pl.rod(u, H, Kn, 2.1, "Gunmetal", segs=8, r2=1.9, bevel=0.15)
        sleeve(u, H + (Kn - H) * 0.2, H + (Kn - H) * 0.68, 2.5, 2.3, "CogRed", rivets=6, rivet_r=0.22)
        out = Vector((0, sy, 0))
        out = (out - d * out.dot(d)).normalized()
        pl.piston(u, H + (Kn - H) * 0.14 + out * 2.9, H + (Kn - H) * 0.86 + out * 2.7, 0.38, "GunmetalDark")
        pl.cyl(u, 2.75, 1.0, Kn - d * 1.5, "GunmetalDark", pl.orient(d), segs=8)
        # ---- knee: two brass ring gears (side and front) around the glowing hub (Joint part)
        ring_gear(u, 4.1, 3.55, 2.55, 8, 0.75, Kn, (1, 0, 0))
        ring_gear(u, 4.1, 3.55, 2.55, 8, 0.75, Kn, (0, 1, 0))
        pl.ico(j, 3.0, Kn, subdiv=2)
        # ---- Lower: shin, red guard plate, ankle gear, foot
        sdir = (A - Kn).normalized()
        pl.cyl(lo, 2.6, 1.3, Kn + sdir * 1.6, "GunmetalDark", pl.orient(sdir), segs=8)
        pl.rod(lo, Kn + sdir * 1.0, A, 2.0, "Gunmetal", segs=8, r2=1.6, bevel=0.15)
        sleeve(lo, Kn + sdir * 2.6, Kn + sdir * 5.4, 2.3, 2.05, "GunmetalDark", band="Rust")
        mid = Kn + sdir * 4.0
        pl.riveted_plate(lo, 3.6, 2.3, 0.35, mid + Vector((sx * 2.2, 0, 0)), pl.basis(sdir, (sx, 0, 0)),
                         "CogRed", "Brass", spacing=1.4, chamfer=0.2, rivet_r=0.18, rivet_segs=4, bevel=0)
        pl.cyl(lo, 2.2, 1.0, (A.x, A.y, 2.1), "GunmetalDark", segs=10)
        pl.cog_joint(lo, (A.x + sx * 2.1, A.y, 2.2), (1, 0, 0), 1.5, 0.4, teeth=8)
        pl.taper_box(lo, (5.8, 6.6), (5.0, 5.6), 0.0, 1.5, "GunmetalDark", loc=(A.x, A.y + 0.2, 0))
        pl.box(lo, (5.9, 1.7, 1.3), (A.x, A.y - 3.0, 0.7), "Rust", bevel=0.25)
        pl.box(lo, (5.9, 6.7, 0.12), (A.x, A.y + 0.1, 0.06), "Grime", bevel=0)
        for i in range(3):
            pl.cyl(lo, 0.42, 0.9, (A.x + (i - 1) * 1.7, A.y - 4.0, 0.55), "Steel", pl.AX_Y, segs=4, r2=0.12, bevel=0)
        pl.bolt_row(lo, (A.x - 2.0, A.y + 1.8, 1.5), (A.x + 2.0, A.y + 1.8, 1.5), 3, (0, 0, 1), 0.25, "Brass", segs=4)


# ------------------------------------------------------------------ build / outputs
def build_all():
    start()
    torso()
    core()
    legs()
    return K["kit"]


def export(root):
    """FBX + palette + manifest entry under root/art/fbx (kept separate from the repo manifest)."""
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
    scratch = "/private/tmp/orbitfall-colossus_cog"
    repo = os.path.normpath(os.path.join(HERE, "..", ".."))
    main(scratch, repo, previews="--nopreview" not in a)
