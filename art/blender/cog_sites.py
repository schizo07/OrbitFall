"""Hero pieces for the Dustbowl Ridge places (World/Places), Cogwork "Foundry Clockwork" style.

Each model uses the same frame as the part-built piece it replaces: origin on the ground under its centre (the skull:
its centre), front = -Y (Roblox -Z), so Places can PivotTo the CFrame it already builds.

  cog_relay_mast      Signal Mesa mast, ~74 tall: drum sections, gear collars, dish 1 at 54 toward the front (-Y),
                      dish 2 at 36 to the side (+X here = Roblox -X), cross arm at 66 (the beacon stays a part in code)
  cog_digger          quarry excavator on treads, boom + bucket reaching ~17 forward
  cog_crane           quarry rim crane: mast 22, jib 27 forward with the hook hanging at 25, counter-jib back
  cog_hauler_wreck    salt-pan six-wheel hauler, cab front, one rear wheel torn off, crate on the bed
  cog_walker_rib      graveyard: one armoured rib arch (span 25, height 27), gear at every joint
  cog_walker_rib_half the snapped rib: one side up to the crown with a torn end
  cog_walker_skull    the fallen walker's head (centred origin; Places tilts it onto its cheek)

Headless:  Blender -b --python cog_sites.py -- [--out <root>] [--only key,key] [--export] [--preview]
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

FRONT = (0, -1, 0)


def plate_on(b, w, h, loc, normal, color="CogRed", spacing=1.0, up=(0, 0, 1)):
    n = Vector(normal).normalized()
    x = Vector(up).cross(n)
    if x.length < 1e-4:
        x = Vector((1, 0, 0))
    pl.riveted_plate(b, w, h, 0.25, loc, pl.basis(x, n), color, "Brass", spacing=spacing, rivet_r=0.12,
                     chamfer=0.18, bevel=0.05)


def ring_gear(b, c, R, teeth, rot=(0, 0, 0), t=0.45):
    """Open toothed brass band (pl.gear is a solid disc)."""
    from mathutils import Euler
    m = Euler(rot).to_matrix()
    c = Vector(c)
    pl.torus(b, R, 0.3, c, "Brass", rot, segs=max(16, teeth), csegs=5)
    for i in range(teeth):
        a = i * 2 * pi / teeth
        d = m @ Vector((cos(a), sin(a), 0))
        e = (m.to_4x4() @ Euler((0, 0, a)).to_matrix().to_4x4()).to_euler()
        pl.box(b, (0.5, 0.45, t), c + d * (R + 0.32), "Brass", (e.x, e.y, e.z), bevel=0.03)


# ----------------------------------------------------------------------------------------------------------- mesa
def relay_mast():
    k = pl.Kit("cog_relay_mast", palette="cogwork", category="landmark", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    pl.loft(b, [[(x, y, 0) for x, y in pl.chamfer_rect(5.2, 5.2, 1.6)],
                [(x, y, 3.0) for x, y in pl.chamfer_rect(4.6, 4.6, 1.4)]], color="GunmetalDark", bevel=0.2)
    secs = [(3.0, 24.0, 2.3, 2.1), (24.0, 46.0, 1.8, 1.6), (46.0, 62.0, 1.4, 1.2), (62.0, 72.0, 0.85, 0.7)]
    for i, (z0, z1, r0, r1) in enumerate(secs):
        pl.cyl(b, r0, z1 - z0, (0, 0, (z0 + z1) / 2), "Gunmetal" if i % 2 == 0 else "Steel", segs=12, r2=r1, bevel=0.08)
        if i:
            pl.cog_joint(b, (0, 0, z0), (0, 0, 1), r0 + 0.9, 0.9, teeth=14)
    for z, r in ((6, 2.4), (13, 2.35), (19, 2.3), (30, 1.85), (38, 1.8), (52, 1.45), (57, 1.4)):
        pl.cyl(b, r, 1.2, (0, 0, z), "Hazard", segs=12, bevel=0)
    plate_on(b, 2.6, 6.0, (0, -2.25, 10.0), FRONT)
    pl.cog_mark(b, g, (0, -2.5, 10.0), FRONT, r=0.9)
    # four braces down to the plinth
    for i in range(4):
        a = i * pi / 2 + pi / 4
        pl.rod(b, (cos(a) * 4.8, sin(a) * 4.8, 2.6), (cos(a) * 1.9, sin(a) * 1.9, 11.0), 0.4, "GunmetalDark", segs=6)
    # ladder up the back
    for s in (-1, 1):
        pl.rod(b, (s * 0.6, 2.6, 3), (s * 0.6, 1.6, 62), 0.09, "GunmetalDark", segs=4)
    for z in range(4, 62, 2):
        y = 2.6 - (z - 3) / 59 * 1.0
        pl.rod(b, (-0.6, y, z), (0.6, y, z), 0.06, "GunmetalDark", segs=4)
    # dishes: big one forward at 54, small one to the side at 36; gear-rimmed (they turn)
    for h, d, dia in ((54.0, Vector((0, -1, 0.3)).normalized(), 9.0), (36.0, Vector((1, 0, 0.3)).normalized(), 6.4)):
        root = Vector((0, 0, h))
        c = root + Vector((d.x, d.y, 0)).normalized() * 3.4
        pl.rod(b, root, c, 0.4, "GunmetalDark", segs=6)
        rot = pl.orient(d)
        pl.lathe(b, [(0.0, -0.6), (dia * 0.25, -0.5), (dia * 0.45, -0.1), (dia * 0.5, 0.3), (dia * 0.46, 0.3),
                     (dia * 0.2, -0.2), (0.0, -0.25)], c, "Steel", rot, segs=16)
        ring_gear(b, c + d * 0.25, dia * 0.5 + 0.1, 18 if dia > 8 else 14, rot)
        pl.rod(b, c, c + d * 3.6, 0.2, "GunmetalDark", segs=5)
        pl.sphere(b, 0.5, c + d * 3.8, "Brass", segs=8)
    # cross arm with lamps
    pl.box(b, (11.0, 0.6, 0.6), (0, 0, 66), "GunmetalDark", bevel=0.1)
    for s in (-1, 1):
        pl.cyl(b, 0.45, 0.8, (s * 5.6, 0, 66.6), "Brass", segs=8)
    pl.antenna(b, (0, 0, 72), 0.6, r=0.25, color="GunmetalDark")
    return k


# ----------------------------------------------------------------------------------------------------------- quarry
def digger():
    k = pl.Kit("cog_digger", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    for s in (-1, 1):
        pl.tread_assembly(b, 11.0, 1.4, 2.8, (s * 3.4, 0, 1.4), wheels=5)
    pl.box(b, (6.2, 8.4, 1.4), (0, 0, 3.0), "GunmetalDark", bevel=0.2)
    ring_gear(b, (0, 0, 3.9), 3.3, 18)
    pl.cyl(b, 3.3, 0.8, (0, 0, 3.9), "Gunmetal", segs=16)
    # house: hazard-yellow armour over a gunmetal frame, boiler at the back
    pl.loft(b, [[(x, y + 0.6, 4.2) for x, y in pl.chamfer_rect(2.9, 3.4, 0.7)],
                [(x, y + 0.6, 6.8) for x, y in pl.chamfer_rect(2.7, 3.2, 0.7)]], color="Hazard", bevel=0.12)
    pl.steam_boiler(b, 1.3, 5.0, (0, 4.6, 6.0), pl.AX_X, color="Rust", band_color="Brass")
    pl.smokestack(b, (1.4, 3.8, 6.8), 0.45, 2.6, glow=g)
    # cab on the left front with a glass slot
    pl.box(b, (3.0, 3.2, 3.2), (-1.5, -1.6, 8.4), "Gunmetal", bevel=0.2)
    pl.box(b, (2.4, 0.2, 1.4), (-1.5, -3.25, 8.8), "Oil", bevel=0)
    pl.cog_eye(b, g, (-1.5, -3.3, 8.8), FRONT, r=0.35)
    # boom up and over, stick down to the bucket at y = -17
    p0, p1, p2 = Vector((0.8, -2.4, 6.2)), Vector((0.8, -10.5, 11.5)), Vector((0.8, -16.5, 5.4))
    pl.rod(b, p0, p1, 0.75, "Hazard", segs=8)
    pl.rod(b, p1, p2, 0.6, "Gunmetal", segs=8)
    for p in (p0, p1, p2):
        pl.cog_joint(b, p, (1, 0, 0), 0.9, 0.5, teeth=10)
    pl.piston(b, (0.8, -1.5, 5.2), (0.8, -8.0, 9.0), 0.35)
    pl.piston(b, (0.8, -9.5, 11.0), (0.8, -14.0, 6.8), 0.3)
    # bucket with teeth
    bk = Vector((0.8, -17.0, 4.6))
    pl.loft(b, [[(bk.x + x, bk.y + 0.0, bk.z + z) for x, z in ((-1.7, -1.2), (1.7, -1.2), (1.7, 1.2), (-1.7, 1.2))],
                [(bk.x + x, bk.y - 1.6, bk.z + z) for x, z in ((-1.7, -1.6), (1.7, -1.6), (1.7, 0.6), (-1.7, 0.6))]],
            color="GunmetalDark", bevel=0.1)
    for x in (-1.2, 0.0, 1.2):
        pl.spike(b, (bk.x + x, bk.y - 1.6, bk.z - 1.5), (0, -0.6, -1), 0.8, 0.25, "Steel")
    return k


def crane():
    k = pl.Kit("cog_crane", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    pl.box(b, (7.0, 7.0, 1.6), (0, 0, 0.8), "GunmetalDark", bevel=0.25)
    ring_gear(b, (0, 0, 1.9), 2.8, 18)
    pl.cyl(b, 2.8, 1.0, (0, 0, 2.1), "Gunmetal", segs=16)
    # lattice mast: four chords + zig-zag lacing
    pts = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
    for x, y in pts:
        pl.rod(b, (2.2 * x, 2.2 * y, 2.4), (0.9 * x, 0.9 * y, 21.0), 0.3, "Hazard", segs=6)
    for i in range(6):
        z0, z1 = 2.4 + i * 3.1, 2.4 + (i + 1) * 3.1
        f0, f1 = 2.2 - (z0 - 2.4) / 18.6 * 1.3, 2.2 - (z1 - 2.4) / 18.6 * 1.3
        for j in range(4):
            (xa, ya), (xb, yb) = pts[j], pts[(j + 1) % 4]
            pl.rod(b, (xa * f0, ya * f0, z0), (xb * f1, yb * f1, z1), 0.13, "GunmetalDark", segs=4)
    # operator cab on the side, slewing ring at the top
    pl.box(b, (3.6, 3.6, 3.2), (-3.2, 1.2, 4.0), "Hazard", bevel=0.2)
    pl.box(b, (2.6, 0.2, 1.4), (-3.2, -0.65, 4.4), "Oil", bevel=0)
    pl.cog_joint(b, (0, 0.5, 21.6), (0, 0, 1), 1.6, 0.7, teeth=12)
    # jib forward (-Y) to 27, counter-jib back with its weight, tie rods to the apex
    top, apex, tip, back = Vector((0, 0.5, 22.2)), Vector((0, 0.5, 27.5)), Vector((0, -27.0, 24.2)), Vector((0, 10.0, 21.0))
    for s in (-1, 1):
        pl.rod(b, top + Vector((s * 0.6, 0, 0)), tip + Vector((s * 0.3, 0, 0)), 0.32, "Hazard", segs=6)
    pl.rod(b, top + Vector((0, 0, -0.9)), tip + Vector((0, 0, -0.6)), 0.25, "GunmetalDark", segs=5)
    pl.rod(b, top, back, 0.5, "GunmetalDark", segs=6)
    pl.box(b, (3.8, 3.2, 2.6), back + Vector((0, 0.5, -1.0)), "GunmetalDark", bevel=0.2)
    pl.rod(b, top, apex, 0.45, "GunmetalDark", segs=6)
    pl.rod(b, apex, tip, 0.1, "Oil", segs=4)
    pl.rod(b, apex, back, 0.1, "Oil", segs=4)
    # hook block hanging over the belt
    hk = Vector((0, -25.0, 9.6))
    pl.rod(b, Vector((0, -25.0, 24.0)), hk, 0.1, "Oil", segs=4)
    pl.box(b, (1.4, 1.4, 2.2), hk - Vector((0, 0, 1.0)), "Hazard", bevel=0.1)
    pl.torus(b, 0.55, 0.16, hk - Vector((0, 0, 2.6)), "Steel", (pi / 2, 0, 0), segs=10, csegs=4)
    pl.lamp(b, g, (0, -27.0, 24.9), (0, 0, 1), r=0.3)
    return k


# ----------------------------------------------------------------------------------------------------------- salt pan
def hauler_wreck():
    k = pl.Kit("cog_hauler_wreck", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    # chassis rails + wheels (rear right one missing, it lies beside the truck)
    for s in (-1, 1):
        pl.box(b, (1.2, 22.0, 1.6), (s * 3.2, 0, 2.6), "GunmetalDark", bevel=0.2)
    for y in (-7, 0, 7):
        for s in (-1, 1):
            if y == 7 and s == -1:
                continue
            pl.cyl(b, 2.2, 1.8, (s * 4.9, y, 2.2), "Tread", pl.AX_X, segs=14, bevel=0.15)
            pl.gear(b, 1.3, 1.0, 10, 0.3, (s * 5.85, y, 2.2), "Brass", pl.AX_X)
    pl.cyl(b, 2.2, 1.8, (-8.6, 10.0, 0.9), "Tread", (0, 0, 0), segs=14, bevel=0.15)  # the torn-off wheel, lying flat
    pl.gear(b, 1.3, 1.0, 10, 0.3, (-8.6, 10.0, 1.85), "Brass")
    pl.box(b, (8.0, 22.0, 1.0), (0, 0, 3.9), "Gunmetal", bevel=0.2)
    # cab: chamfered block with a boiler hood and a dark slit window
    pl.loft(b, [[(x, y - 8.0, 4.4) for x, y in pl.chamfer_rect(3.8, 3.5, 0.9)],
                [(x, y - 8.2, 9.6) for x, y in pl.chamfer_rect(3.5, 3.1, 0.9)]], color="Gunmetal", bevel=0.15)
    plate_on(b, 6.6, 3.2, (0, -11.55, 6.4), FRONT)
    pl.visor_slot(b, g, 5.0, 0.9, (0, -11.3, 8.4), FRONT, lenses=0)
    pl.cog_mark(b, g, (0, -11.85, 5.4), FRONT, r=0.8)
    pl.steam_boiler(b, 2.0, 5.6, (0, -8.0, 10.6), pl.AX_X, color="Rust", band_color="Brass")
    pl.smokestack(b, (2.6, -5.6, 9.6), 0.5, 3.0, glow=g)
    # cargo bed sides (one panel bent out) and a crate still on it
    pl.box(b, (0.4, 13.0, 2.4), (3.8, 3.5, 5.6), "CogRed", bevel=0.08)
    pl.box(b, (0.4, 13.0, 2.4), (-4.6, 3.5, 5.0), "CogRed", (0, radians(-30), 0), bevel=0.08)
    pl.hazard_stripes(b, 7.6, 1.0, (0, 10.6, 5.0), pl.basis((1, 0, 0), (0, 1, 0)), stripes=6, c1="Hazard", c2="Oil",
                      t=0.12)
    pl.crate(b, (5.6, 6.4, 4.6), (0.4, 4.4, 4.4), color="Rust", trim="GunmetalDark", latch="Brass", mark="Ivory",
             rot=(0, radians(-8), radians(14)))
    return k


# ----------------------------------------------------------------------------------------------------------- graveyard
RIB_RX, RIB_RY, RIB_N = 12.5, 27.0, 8


def _rib(b, k0, k1, torn=False):
    """Armoured rib segments k0..k1-1 of a half-ellipse arch in the XZ plane (x = +-RIB_RX at the feet)."""
    pts = [Vector((RIB_RX * cos(pi * i / RIB_N), 0, RIB_RY * sin(pi * i / RIB_N))) for i in range(RIB_N + 1)]
    for i in range(k0, k1):
        a, c = pts[i], pts[i + 1]
        t = (c - a)
        f = (i + 0.5) / RIB_N
        w = 2.8 - 1.0 * sin(f * pi)
        rot = pl.basis(t, (0, 1, 0))
        pl.box(b, (t.length * 1.04, w, 3.0), (a + c) / 2, "Gunmetal", rot, bevel=0.3)
        out = Vector((cos(pi * f) / RIB_RX, 0, sin(pi * f) / RIB_RY)).normalized()
        if i % 2 == 0:
            pl.riveted_plate(b, t.length * 0.8, 2.4, 0.25, (a + c) / 2 + out * (w / 2 + 0.1), pl.basis(t, out),
                             "CogRed", "Brass", spacing=1.1, rivet_r=0.12, chamfer=0.2, bevel=0.05)
    for i in range(max(k0, 1), min(k1, RIB_N) + (0 if torn else 0)):
        if i == k0:
            continue
        pl.cog_joint(b, pts[i], (0, 1, 0), 1.7, 3.4, teeth=12)
    if torn:
        e = pts[k1]
        for dx, dz, ln in ((0.6, 0.4, 1.6), (-0.5, -0.3, 1.1), (0.1, 0.8, 1.3)):
            pl.box(b, (ln, 0.8, 0.7), e + Vector((dx, 0, dz)), "GunmetalDark", (0.3 * dz, 0.4, 0.2 * dx), bevel=0.08)
    # feet sockets (buried a little)
    for i in (k0, k1):
        if i in (0, RIB_N):
            pl.box(b, (3.4, 3.8, 1.6), pts[i] + Vector((0, 0, 0.2)), "GunmetalDark", bevel=0.2)


def walker_rib():
    k = pl.Kit("cog_walker_rib", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    _rib(b, 0, RIB_N)
    return k


def walker_rib_half():
    k = pl.Kit("cog_walker_rib_half", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    _rib(b, 0, RIB_N // 2 + 1, torn=True)
    return k


def walker_skull():
    k = pl.Kit("cog_walker_skull", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    # head shell along Y (face at -Y), centred on the origin
    rings = [[(x, -8.0, z) for x, z in pl.chamfer_rect(5.2, 4.0, 1.6)],
             [(x, -6.0, z) for x, z in pl.chamfer_rect(7.6, 6.4, 2.2)],
             [(x, 4.0, z) for x, z in pl.chamfer_rect(7.6, 6.6, 2.4)],
             [(x, 7.0, z) for x, z in pl.chamfer_rect(5.4, 5.0, 1.8)]]
    pl.loft(b, rings, color="Gunmetal", bevel=0.25)
    plate_on(b, 9.0, 6.0, (0, -1.0, 6.65), (0, 0, 1), up=(0, 1, 0))
    for s in (-1, 1):
        plate_on(b, 8.0, 4.4, (s * 7.65, -0.5, 0.8), (s, 0, 0))
    pl.gear_cluster(b, (7.9, 0.5, 1.0), pl.basis((0, 1, 0), (1, 0, 0)), R=1.4, t=0.25)
    # visor with two big lenses: one still lit
    pl.visor_slot(b, g, 9.0, 2.0, (0, -7.9, 1.6), FRONT, lenses=0, color="Oil")
    for x, lit in ((3.0, True), (-3.0, False)):
        pl.cyl(b, 1.7, 0.8, (x, -8.2, 1.6), "GunmetalDark", pl.AX_Y, segs=14)
        pl.cyl(g if lit else b, 1.2, 0.3, (x, -8.65, 1.6), "Lens", pl.AX_Y, segs=12, bevel=0)
    pl.cog_mark(b, g, (0, -8.1, 4.6), FRONT, r=1.2)
    # jaw plate hanging open, neck gear at the back, a bent antenna
    pl.box(b, (9.0, 6.0, 1.8), (0, -4.0, -5.8), "GunmetalDark", (radians(22), 0, 0), bevel=0.25)
    pl.cog_joint(b, (0, 7.6, 0), (0, 1, 0), 3.2, 1.2, teeth=16)
    pl.rod(b, (4.0, 0.0, 6.6), (6.0, 1.0, 13.0), 0.25, "GunmetalDark", segs=5)
    pl.rod(b, (6.0, 1.0, 13.0), (8.0, 1.0, 14.5), 0.2, "GunmetalDark", segs=5)
    pl.pipe(b, [(-6.0, 7.0, -3.0), (-6.5, 9.5, -3.5), (-5.0, 11.0, -4.0)], 0.5)
    return k


BUILDERS = {
    "cog_relay_mast": relay_mast, "cog_digger": digger, "cog_crane": crane, "cog_hauler_wreck": hauler_wreck,
    "cog_walker_rib": walker_rib, "cog_walker_rib_half": walker_rib_half, "cog_walker_skull": walker_skull,
}
CENTRED = {"cog_walker_skull"}


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = a[a.index("--out") + 1] if "--out" in a else os.path.normpath(os.path.join(HERE, "..", ".."))
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = "FBX_SCALE_ALL"
    keys = a[a.index("--only") + 1].split(",") if "--only" in a else list(BUILDERS)
    for key in keys:
        k = BUILDERS[key]()
        k.build()
        k.report()
        if "--export" in a:
            k.export_fbx()
            k.write_manifest()
        if "--preview" in a:
            k.preview(size=700, direction=(0.75, -1.0, 0.5))


if __name__ == "__main__":
    main()
