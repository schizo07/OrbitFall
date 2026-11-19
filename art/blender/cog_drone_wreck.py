"""Crashed Cog cargo drone (key cog_drone_wreck): the first thing the squad sees in the HAUL mission on Dustbowl Ridge.

Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md): a chamfered gunmetal hull with CogRed armour panels, two
lift fans in gear-rimmed ducts on side pylons, smokestacks, copper pipes and an open cargo cradle at the back.
Modelled in its crash pose: nose dug in (it sits ~1.8 studs below z = 0, so place it with no extra sink), rolled onto
its right side; the right pylon is snapped and its fan duct lies on the ground beside the hull. Front = -Y (Roblox -Z).
Parts: Body (Metal) + Glow (Neon embers in the stacks and the torn pylon, the dimmed eye lenses).

Headless:  Blender -b --python cog_drone_wreck.py -- --out <root>   (writes <root>/art/fbx/cog_drone_wreck.fbx + manifest)
"""
import os
import sys
from math import radians, pi, cos, sin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector, Matrix, Euler

KEY = "cog_drone_wreck"
HZ = 5.0  # hull centre height in the level pose
BURY = 2.6  # how far the nose sinks below the ground after the crash pose
PITCH, ROLL, YAW = 21.0, 11.0, 0.0


def ring_y(y, hx, hz, c, zc=HZ):
    """Chamfered rectangle ring in the XZ plane at y (loft rings run along Y)."""
    pts = [(-hx + c, -hz), (hx - c, -hz), (hx, -hz + c), (hx, hz - c), (hx - c, hz), (-hx + c, hz),
           (-hx, hz - c), (-hx, -hz + c)]
    return [(x, y, zc + z) for x, z in pts]


def facing(n, up=(0, 0, 1)):
    """Euler for a plate lying in local XY whose +Z faces n."""
    n = Vector(n).normalized()
    u = Vector(up)
    x = u.cross(n)
    if x.length < 1e-4:
        x = Vector((1, 0, 0))
    return pl.basis(x, n)


def hull(b, g):
    rings = [ring_y(-14.0, 2.0, 1.6, 0.6, HZ - 0.6), ring_y(-12.6, 3.4, 2.6, 1.0, HZ - 0.3),
             ring_y(-8.0, 4.6, 3.4, 1.4), ring_y(3.5, 4.6, 3.4, 1.4), ring_y(7.5, 4.0, 3.0, 1.2, HZ + 0.2)]
    pl.loft(b, rings, color="Gunmetal", bevel=0.18)
    # belly keel + skids (worn rust)
    pl.box(b, (3.2, 17.0, 0.9), (0, -2.0, HZ - 3.6), "Rust", bevel=0.25)
    for x in (-3.3, 3.3):
        pl.box(b, (0.8, 14.0, 0.7), (x, -1.5, HZ - 3.7), "RustDark", bevel=0.2)
    # dorsal spine
    pl.box(b, (2.2, 15.0, 0.8), (0, -2.5, HZ + 3.65), "GunmetalDark", bevel=0.25)

    # CogRed armour panels: flanks, nose cheeks, top
    for s in (-1, 1):
        n = (s, 0, 0)
        pl.riveted_plate(b, 9.5, 4.2, 0.35, (s * 4.72, -2.5, HZ + 0.2), facing(n), "CogRed", "Brass",
                         spacing=1.1, rivet_r=0.12, chamfer=0.18, bevel=0.08)
        pl.riveted_plate(b, 3.6, 2.6, 0.3, (s * 4.0, -10.5, HZ + 0.4), pl.basis((0, 1, 0), (s, -0.45, 0)),
                         "CogRed", "Brass", spacing=1.0, rivet_r=0.1, chamfer=0.2, bevel=0.06)
    pl.riveted_plate(b, 6.0, 8.0, 0.3, (0, -7.0, HZ + 3.5), facing((0, 0, 1), (0, 1, 0)), "CogRed", "Brass",
                     spacing=1.2, rivet_r=0.12, chamfer=0.15, bevel=0.06)
    # gear cluster on the left flank panel (a third of the way along, not centred)
    pl.gear_cluster(b, (-4.92, -5.0, HZ + 0.6), facing((-1, 0, 0)), R=1.3, t=0.22)

    # nose: faction mark + a slit visor whose lenses are going dim
    pl.cog_mark(b, g, (0, -14.05, HZ - 0.9), (0, -1, 0), r=1.0)
    pl.visor_slot(b, g, 3.0, 0.55, (0, -13.3, HZ + 0.9), (0, -0.9, 0.42), lenses=2)
    # rear bulkhead with an exhaust bell
    pl.box(b, (7.6, 0.6, 5.6), (0, 7.7, HZ + 0.1), "GunmetalDark", bevel=0.2)
    pl.lathe(b, [(1.0, 0), (1.5, 0.9), (1.7, 1.6), (1.4, 1.6), (0.0, 1.0)], (0, 8.0, HZ - 1.0), "Soot",
             rot=(-pi / 2, 0, 0), segs=12)
    pl.gear(b, 1.95, 1.7, 14, 0.3, (0, 8.1, HZ - 1.0), "Brass", rot=(-pi / 2, 0, 0))

    # two smokestacks on the back of the hull, embers still glowing
    for x in (-2.0, 2.0):
        pl.smokestack(b, (x, 3.8, HZ + 3.2), 0.75, 3.4, color="Gunmetal", rim="Rust", glow=g)
    # copper pipes from the stacks down to the fan pylons
    for s in (-1, 1):
        pl.pipe(b, [(s * 2.0, 3.0, HZ + 3.6), (s * 3.9, 2.4, HZ + 3.0), (s * 4.7, 0.6, HZ + 1.9)], 0.25)


def fan(b, g, c, tilt=0.0):
    """Lift fan: a gunmetal duct with a toothed brass rim and a gear-shaped rotor inside (axis = local Z)."""
    rot = Euler((0, tilt, 0))
    pl.torus(b, 3.3, 0.6, c, "Gunmetal", rot, segs=20, csegs=6)
    ring_gear(b, c, rot)
    rotor(b, c, rot)
    m = rot.to_matrix()
    for a in (0, pi / 2, pi, 3 * pi / 2):  # stator spokes
        d = m @ Vector((cos(a), sin(a), 0))
        pl.rod(b, Vector(c) + d * 0.8, Vector(c) + d * 3.0, 0.16, "GunmetalDark", segs=6)


def ring_gear(b, c, rot, R=3.95, teeth=20):
    """Toothed brass band around a duct (open in the middle, unlike pl.gear)."""
    m = rot.to_matrix()
    c = Vector(c)
    pl.torus(b, R, 0.32, c, "Brass", rot, segs=24, csegs=5)
    for i in range(teeth):
        a = i * 2 * pi / teeth
        d = m @ Vector((cos(a), sin(a), 0))
        e = (m.to_4x4() @ Euler((0, 0, a)).to_matrix().to_4x4()).to_euler()
        pl.box(b, (0.55, 0.5, 0.45), c + d * (R + 0.35), "Brass", (e.x, e.y, e.z), bevel=0.04)


def rotor(b, c, rot, bent=False):
    """Four broad brass blades on a small gear hub with a CogRed cap."""
    m = rot.to_matrix()
    c = Vector(c)
    pl.gear(b, 1.1, 0.85, 8, 0.4, c, "Brass", rot)
    pl.cyl(b, 0.55, 0.7, c, "CogRed", rot, segs=10)
    for i in range(4):
        a = i * pi / 2 + 0.3
        d = m @ Vector((cos(a), sin(a), 0))
        twist = Euler((radians(28), 0, a + pi / 2))
        if bent and i == 1:
            twist = Euler((radians(60), radians(25), a + pi / 2))
        br = (m.to_4x4() @ twist.to_matrix().to_4x4()).to_euler()
        pl.box(b, (1.0, 2.0, 0.16), c + d * 1.9, "Brass", (br.x, br.y, br.z), bevel=0.05)


def pylons(b, g):
    # left pylon intact: arm out to a tilted fan
    pl.box(b, (5.2, 2.2, 1.2), (-6.8, -0.5, HZ + 0.6), "GunmetalDark", bevel=0.25)
    pl.cog_joint(b, (-8.9, -0.5, HZ + 0.6), (1, 0, 0), 1.0, 0.5)
    fan(b, g, (-12.2, -0.5, HZ + 0.9), tilt=radians(-14))
    # right pylon snapped: short jagged stub, torn cable, embers inside the break
    pl.box(b, (2.4, 2.2, 1.2), (5.7, -0.5, HZ + 0.6), "GunmetalDark", bevel=0.25)
    for dy, dz, ln in ((-0.7, 0.35, 1.2), (0.0, -0.3, 0.8), (0.6, 0.3, 1.5)):
        pl.box(b, (ln, 0.5, 0.45), (6.9 + ln / 2 - 0.3, -0.5 + dy, HZ + 0.6 + dz), "Gunmetal",
               rot=(0.2 * dy, 0.3 * dz, 0.15), bevel=0.08)
    pl.box(g, (0.2, 1.4, 0.7), (6.95, -0.5, HZ + 0.6), bevel=0)
    pl.cable(b, (6.9, 0.2, HZ + 0.3), (8.6, 1.4, HZ - 1.6), r=0.14, sag=0.6, color="Copper")


def cargo(b, g):
    """Open cargo cradle behind the hull: frame rods, one bent, one crate still strapped in."""
    y0, y1 = 8.0, 17.0
    corners = [(-3.6, HZ + 2.6), (3.6, HZ + 2.6), (3.6, HZ - 2.6), (-3.6, HZ - 2.6)]
    for i, (x, z) in enumerate(corners):
        if i == 1:  # top right rail bent down at the end
            pl.rod(b, (x, y0, z), (x, 13.5, z), 0.5, "Gunmetal", segs=8)
            pl.rod(b, (x, 13.5, z), (x + 1.2, 16.0, z - 2.4), 0.5, "Gunmetal", segs=8)
        else:
            pl.rod(b, (x, y0, z), (x, y1, z), 0.5, "Gunmetal", segs=8)
    for y, skip in ((12.0, -1), (17.0, 1)):
        for i in range(4):
            if i == skip:
                continue
            (xa, za), (xb, zb) = corners[i], corners[(i + 1) % 4]
            pl.box(b, (abs(xb - xa) + 0.9, 0.9, abs(zb - za) + 0.9), ((xa + xb) / 2, y, (za + zb) / 2), "GunmetalDark", bevel=0.15)
    pl.box(b, (7.0, 9.0, 0.4), (0, 12.5, HZ - 2.7), "Grime", bevel=0.1)
    pl.hazard_stripes(b, 7.2, 0.9, (0, 17.05, HZ - 2.2), facing((0, 1, 0)), stripes=6, c1="Hazard", c2="Oil", t=0.12)
    pl.crate(b, (5.0, 4.2, 4.0), (0.2, 10.6, HZ - 2.5), color="Rust", trim="GunmetalDark", latch="Brass",
             mark="Ivory", rot=(0, 0, radians(6)))


def fallen_fan(b, g):
    """The snapped-off right fan, half buried beside the hull (world coordinates, after the crash pose)."""
    c = Vector((13.5, 4.0, 1.4))
    rot = Euler((radians(62), radians(10), radians(25)))
    pl.torus(b, 3.3, 0.6, c, "Gunmetal", rot, segs=20, csegs=6)
    ring_gear(b, c, rot)
    rotor(b, c, rot, bent=True)
    m = rot.to_matrix()
    pl.box(b, (2.6, 2.0, 1.1), c + m @ Vector((-4.4, 0, 0)), "GunmetalDark", rot, bevel=0.2)  # torn pylon end
    # loose panels in the dirt
    pl.riveted_plate(b, 3.0, 2.2, 0.25, (8.5, 11.0, 0.15), (radians(4), radians(-6), radians(30)), "CogRed",
                     "Brass", spacing=1.0, rivet_r=0.1, chamfer=0.2, bevel=0.05)


def build():
    k = pl.Kit(KEY, palette="cogwork", category="landmark", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    g = k.glow("Glow", role="glow", parent="Body")
    hull(b, g)
    pylons(b, g)
    cargo(b, g)
    # crash pose: pitch the nose down, roll onto the right side, then sink the nose into the ground
    bpy.context.view_layer.update()
    R = (Euler((radians(PITCH), radians(ROLL), radians(YAW)))).to_matrix().to_4x4()
    for p in k.parts:
        for ob in p.pieces:
            ob.matrix_world = R @ ob.matrix_world
    bpy.context.view_layer.update()
    # spots for the game (smoke, sparks, the flight-log panel), posed like the hull
    R3 = R.to_3x3()
    for name, p in (("StackL", (-2.0, 3.8, HZ + 6.8)), ("StackR", (2.0, 3.8, HZ + 6.8)),
                    ("Break", (7.0, -0.5, HZ + 0.6)), ("FlightLog", (-4.9, -9.6, HZ - 0.4))):
        k.attachment(name, R3 @ Vector(p))
    print("FLIGHTLOG_NORMAL_ROBLOX", pl.to_roblox(R3 @ Vector((-1, 0, 0))))
    k.ground()
    k.shift((0, 0, -BURY))
    fallen_fan(b, g)
    k.center()
    k.build()
    return k


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = a[a.index("--out") + 1] if "--out" in a else os.path.normpath(os.path.join(HERE, "..", ".."))
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = "FBX_SCALE_ALL"
    k = build()
    k.report()
    for n, pt, v in k.attachments:
        print("ATTACH", n, pl.to_roblox(v))
    if "--export" in a:
        k.export_fbx()
        k.write_manifest()
    return k


if __name__ == "__main__":
    main()
