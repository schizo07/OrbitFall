"""Refinery set pieces for Dustbowl Ridge (World/Places buildRefinery), Cogwork "Foundry Clockwork" style.

  cog_smokestack  ~62 tall riveted stack on a plinth, furnace block with a glowing grate feeding it, ladder, copper pipes.
                  The landmark you navigate by. Origin = base centre on the ground; furnace on +X (Roblox -X).
  cog_tank_a      upright storage tank with a dome, hazard band, ladder, valve wheel.
  cog_tank_b      spherical tank on four legs with a gear-rimmed equator band.

Headless:  Blender -b --python cog_refinery.py -- [--out <root>] [--only key,key] [--export] [--preview]
"""
import os
import sys
from math import radians, pi, cos, sin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector

ATTACH = {}


def flange(b, z, r, color="GunmetalDark", h=1.2, bolts=12):
    pl.cyl(b, r, h, (0, 0, z), color, segs=16, bevel=0.15)
    for i in range(bolts):
        a = i * 2 * pi / bolts
        pl.bolt(b, (cos(a) * r, sin(a) * r, z), (cos(a), sin(a), 0), 0.22, "Brass")


def ladder(b, x0, y0, z0, z1, side=(0, -1, 0), w=1.4, color="GunmetalDark"):
    """Rails + rungs standing off a surface at (x0, y0); side = outward direction of the rails' plane."""
    s = Vector(side)
    t = Vector((-s.y, s.x, 0)) * (w / 2)
    o = Vector((x0, y0, 0))
    for k in (-1, 1):
        pl.rod(b, o + t * k + Vector((0, 0, z0)), o + t * k + Vector((0, 0, z1)), 0.12, color, segs=5)
    n = int((z1 - z0) / 1.1)
    for i in range(1, n):
        z = z0 + i * 1.1
        pl.rod(b, o - t + Vector((0, 0, z)), o + t + Vector((0, 0, z)), 0.08, color, segs=4)


def smokestack():
    k = pl.Kit("cog_smokestack", palette="cogwork", category="landmark", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    # plinth
    pl.loft(b, [[(x, y, 0) for x, y in pl.chamfer_rect(7.2, 7.2, 2.0)],
                [(x, y, 3.0) for x, y in pl.chamfer_rect(6.6, 6.6, 1.8)]], color="GunmetalDark", bevel=0.2)
    pl.bolt_ring(b, (0, 0, 3.0), (0, 0, 1), 5.6, 16, r=0.28, color="Brass")
    # stack: three tapering riveted sections with flanges
    secs = [(3.0, 17.0, 4.3, 4.0, "Gunmetal"), (17.0, 39.0, 3.5, 3.2, "Gunmetal"), (39.0, 58.0, 2.8, 2.5, "Rust")]
    for z0, z1, r0, r1, col in secs:
        pl.cyl(b, r0, z1 - z0, (0, 0, (z0 + z1) / 2), col, segs=16, r2=r1, bevel=0.1)
        flange(b, z0 + 0.6, r0 + 0.35)
    flange(b, 57.6, 2.85)
    # flared rim with embers deep inside the mouth
    pl.lathe(b, [(2.6, 58.0), (3.6, 60.2), (3.3, 60.6), (2.2, 59.6), (0.0, 59.6)], (0, 0, 0), "RustDark", segs=16)
    pl.cyl(g, 2.0, 0.1, (0, 0, 59.7), segs=14, bevel=0)
    # four riveted braces from the plinth corners up to the first flange
    for x, y in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
        pl.rod(b, (5.6 * x, 5.6 * y, 2.6), (3.0 * x, 3.0 * y, 16.0), 0.55, "GunmetalDark", segs=6)
        pl.bolt(b, (5.6 * x, 5.6 * y, 3.0), (0, 0, 1), 0.35, "Brass")
    # CogRed armour band with the faction mark on the lower section, hazard bands up high
    pl.cyl(b, 4.45, 4.0, (0, 0, 10.0), "CogRed", segs=16, bevel=0.1)
    pl.cog_mark(b, g, (0, -4.45, 10.0), (0, -1, 0), r=1.5)
    for z, r in ((30.0, 3.45), (49.0, 2.75)):
        pl.cyl(b, r, 1.6, (0, 0, z), "Hazard", segs=16, bevel=0)
    # brass gear rims at the two lower joints (the stack's turning damper collars)
    for z, r in ((17.6, 4.15), (39.6, 3.35)):
        pl.gear(b, r + 0.55, r + 0.2, 22, 0.6, (0, 0, z), "Brass")
    # ladder up the back, cage hoops
    ladder(b, 0, 4.9, 3.0, 57.0, side=(0, 1, 0))
    for z in range(8, 57, 4):
        pl.torus(b, 1.15, 0.08, (0, 5.3, z), "GunmetalDark", segs=10, csegs=4, arc=pi)
    # furnace block on +X: a firebox with a glowing grate, a boiler drum on top, pipes into the stack
    fx = 10.5
    pl.loft(b, [[(fx + x, y, 0) for x, y in pl.chamfer_rect(4.0, 3.4, 0.8)],
                [(fx + x, y, 6.0) for x, y in pl.chamfer_rect(3.8, 3.2, 0.8)]], color="GunmetalDark", bevel=0.15)
    pl.riveted_plate(b, 6.4, 4.4, 0.25, (fx, -3.45, 3.4), pl.basis((1, 0, 0), (0, -1, 0)), "CogRed", "Brass",
                     spacing=1.0, rivet_r=0.12, chamfer=0.15, bevel=0.05)
    pl.vent_grille(b, 3.6, 2.2, 4, (fx, -3.7, 2.6), pl.basis((1, 0, 0), (0, -1, 0)), "Gunmetal", "Soot", glow=g,
                   depth=0.5)
    pl.steam_boiler(b, 1.8, 6.0, (fx, 0, 7.8), pl.AX_Y, color="Rust", band_color="Brass", bands=3)
    pl.smokestack(b, (fx + 2.2, 1.6, 6.0), 0.55, 4.0, glow=g)
    pl.pipe(b, [(fx - 3.9, 0.0, 4.0), (fx - 5.0, 0.0, 4.0), (4.2, 0.0, 6.0)], 0.6)
    pl.pipe(b, [(fx - 1.0, -1.4, 9.3), (fx - 1.0, -1.4, 13.0), (3.8, -1.4, 15.0)], 0.45)
    pl.gauge(b, (fx + 4.05, 0.0, 4.4), (1, 0, 0), 0.6)
    pl.handwheel(b, (fx + 4.05, -1.6, 2.6), (1, 0, 0), 0.7)
    ATTACH["cog_smokestack"] = [("Top", (0, 0, 60.5)), ("Furnace", (fx, -4.2, 2.6))]
    for n, p in ATTACH["cog_smokestack"]:
        k.attachment(n, p)
    return k


def tank_a():
    k = pl.Kit("cog_tank_a", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    pl.cyl(b, 5.3, 0.8, (0, 0, 0.4), "GunmetalDark", segs=18, bevel=0.15)
    pl.cyl(b, 4.6, 9.6, (0, 0, 5.6), "Steel", segs=18, bevel=0.1)
    pl.lathe(b, [(4.6, 10.4), (4.2, 11.8), (3.0, 13.0), (1.2, 13.6), (0.0, 13.7)], (0, 0, 0), "Steel", segs=18)
    pl.cyl(b, 4.75, 1.0, (0, 0, 5.4), "Hazard", segs=18, bevel=0)
    for z in (2.0, 9.4):
        pl.cyl(b, 4.72, 0.35, (0, 0, z), "GunmetalDark", segs=18, bevel=0)
    pl.riveted_plate(b, 3.6, 3.0, 0.2, (0, -4.62, 7.6), pl.basis((1, 0, 0), (0, -1, 0)), "CogRed", "Brass",
                     spacing=0.9, rivet_r=0.1, chamfer=0.2, bevel=0.04)
    pl.gear_cluster(b, (0, -4.83, 7.6), pl.basis((1, 0, 0), (0, -1, 0)), R=0.8, t=0.14)
    ladder(b, 4.95, 0, 0.8, 12.0, side=(1, 0, 0))
    pl.cyl(b, 0.9, 1.6, (0, 0, 14.3), "Gunmetal", segs=10)
    pl.handwheel(b, (0, 0, 15.3), (0, 0, 1), 0.8)
    pl.pipe(b, [(-4.6, 0, 2.0), (-6.6, 0, 2.0), (-6.6, 0, 0.3)], 0.5)
    return k


def tank_b():
    k = pl.Kit("cog_tank_b", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    pl.sphere(b, 5.5, (0, 0, 9.2), "Steel", segs=20)
    pl.cyl(b, 5.62, 1.0, (0, 0, 9.2), "Hazard", segs=20, bevel=0)
    pl.gear(b, 6.3, 5.9, 24, 0.5, (0, 0, 9.9), "Brass")
    for x, y in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
        pl.rod(b, (3.9 * x, 3.9 * y, 0.0), (2.9 * x, 2.9 * y, 7.4), 0.45, "GunmetalDark", segs=8)
        pl.cyl(b, 0.9, 0.5, (3.9 * x, 3.9 * y, 0.25), "GunmetalDark", segs=8)
    for (xa, ya), (xb, yb) in (((1, 1), (-1, 1)), ((-1, 1), (-1, -1)), ((-1, -1), (1, -1)), ((1, -1), (1, 1))):
        pl.rod(b, (3.6 * xa, 3.6 * ya, 2.2), (3.6 * xb, 3.6 * yb, 2.2), 0.2, "GunmetalDark", segs=6)
    pl.cyl(b, 0.7, 2.0, (0, 0, 15.3), "Gunmetal", segs=10)
    pl.cyl(b, 1.0, 0.4, (0, 0, 16.3), "Brass", segs=10)
    pl.pipe(b, [(0, -2.0, 4.2), (0, -2.0, 1.2), (0, -6.5, 1.2)], 0.45)
    return k


BUILDERS = {"cog_smokestack": smokestack, "cog_tank_a": tank_a, "cog_tank_b": tank_b}


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = a[a.index("--out") + 1] if "--out" in a else os.path.normpath(os.path.join(HERE, "..", ".."))
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = "FBX_SCALE_ALL"
    keys = a[a.index("--only") + 1].split(",") if "--only" in a else list(BUILDERS)
    for key in keys:
        k = BUILDERS[key]()
        # origin stays on the stack / tank axis (Places positions them by it)
        k.build()
        k.report()
        for n, pt, v in k.attachments:
            print("ATTACH", key, n, pl.to_roblox(v))
        if "--export" in a:
            k.export_fbx()
            k.write_manifest()
        if "--preview" in a:
            k.preview(size=900, direction=(0.7, -1.0, 0.45))


if __name__ == "__main__":
    main()
