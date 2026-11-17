"""Objective set pieces rebuilt in the Squad ("human") family (art/STYLE.md): generator, trajectory_console,
missile_silo, uplink_dish. Drop-in replacements for the Halcyon-style models made by setpieces.py.

Same part names / roles / parents / pivots as the old kit entries, same facing (Blender -Y front, Z up) and the same
origin convention (origin = base centre, silo Missile lowered 12.8 below ground). The game code depends on:
  generator  : Body, Switch (interact, prompt), Core (glow, pulses Transparency). Smoke emitter is placed by code at the
               stack mouth: Roblox (-1.2, 5.2, 0) -> Blender (1.2, 0, 5.2).
  console    : Body, Keyboard (interact, prompt), Screen (glow, Color set by code).
  silo       : Body, Door_L/Door_R (hinges at the rim, +-72 deg about the Blender Y axis), Lever_L/Lever_R (rotate about X at
               the stand cap), Missile (rest pose 12.8 below ground, rises +12.8).
  uplink     : Body, Terminal (interact), Dish (yawed about the vertical axis through its pivot).

Run headless:  Blender -b --factory-startup --python objectives_v2.py -- [--only key,key] [--out <scratch root>]
               [--no-render] [--no-export]
Outputs: <out>/art/fbx/<key>.fbx (+palette), <out>/entry/<key>.entry.json, <out>/img/<key>_new_{front,back}.png
"""
import json
import os
import sys
from math import pi, sin, cos, radians, sqrt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector

ROOT_DEFAULT = "/private/tmp/orbitfall-objectives"


# ------------------------------------------------------------------ small helpers
def face(n, up=(0, 0, 1)):
    """Euler for a flat panel whose local +Z is the outward normal n and local +Y is (about) up."""
    n = Vector(n).normalized()
    xd = Vector(up).cross(n)
    if xd.length < 1e-4:
        xd = Vector((1, 0, 0))
    return pl.basis(xd, n)


FRONT, BACK, RIGHT, LEFT = (0, -1, 0), (0, 1, 0), (1, 0, 0), (-1, 0, 0)


def ring_rect(hx, hy, c, z, cy=0.0, cx=0.0):
    return [(x + cx, y + cy, z) for x, y, _ in pl.chamfer_rect(hx, hy, c, z)]


def kit(key):
    return pl.Kit(key, palette="human", category="set_piece", reset=True)


def tube_path(part, pts, r, color, sides=6):
    pl.tube(part, pts, r, color, sides=sides)


# ================================================================== 1. generator
def generator():
    k = kit("generator")
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Charcoal")
    sw = k.part("Switch", "interact", "Metal", pivot=(0, -1.42, 1.65), parent="Body", color="Charcoal")
    core = k.glow("Core", role="glow", pivot=(-0.4, 0.0, 3.75), parent="Body")   # amber, recessed in the turbine collar
    CY = 0.2                                                                       # housing centre y

    # --- sled skid: two runners with up-turned noses, deck plate, hazard bumper, rear tow ring
    runner = [(-3.0, 0.38), (-2.62, 0.0), (2.75, 0.0), (2.95, 0.28), (2.95, 0.58), (-3.0, 0.58)]
    for s in (-1, 1):
        pl.extrude(b, runner, 0.7, (s * 2.3, 0, 0), "CharcoalDark", plane='YZ', bevel=0.06)
    pl.taper_box(b, (5.2, 5.4), (5.0, 5.2), 0.5, 0.72, "CharcoalDark")
    pl.box(b, (4.7, 0.34, 0.36), (0, -2.72, 0.6), "Charcoal", bevel=0.06)
    pl.hazard_stripes(b, 4.4, 0.28, (0, -2.9, 0.6), rot=face(FRONT), stripes=9)
    tube_path(b, [(-0.55, 2.55, 0.66), (-0.55, 3.1, 0.66), (0.55, 3.1, 0.66), (0.55, 2.55, 0.66)], 0.07, "Orange")
    for s in (-1, 1):                                                              # grimy skid toes
        pl.box(b, (0.8, 0.5, 0.14), (s * 2.3, -3.0, 0.07), "Black", bevel=0)

    # --- housing: charcoal lower block, tan armoured cowl, orange top trim
    pl.loft(b, [ring_rect(1.76, 1.6, 0.4, 0.72, CY), ring_rect(1.72, 1.57, 0.38, 2.1, CY)], color="Charcoal", bevel=0.05)
    pl.loft(b, [ring_rect(1.84, 1.66, 0.45, 2.1, CY), ring_rect(1.5, 1.42, 0.4, 2.95, CY)], color="Tan", bevel=0.05)
    pl.box(b, (3.9, 3.5, 0.1), (0, CY, 0.78), "CharcoalDark", bevel=0)                  # grime plinth under the housing
    pl.box(b, (3.7, 0.16, 0.12), (0, -1.5, 2.07), "TanDark", bevel=0.02)
    # tan side plates on the sloped cowl (rivet border), stencil glyphs
    for s in (-1, 1):
        n = (s * 0.94, 0, 0.34)
        pl.riveted_plate(b, 2.1, 0.55, 0.07, (s * 1.67, CY, 2.53), face(n), "Tan", "Steel", spacing=0.5,
                         chamfer=0.18, bevel=0)
        pl.stencil_panel(b, 0.7, 0.4, (s * 1.62 + s * 0.04, CY - 0.9, 2.53), face(n), "CharcoalDark", "Stencil", t=0.05)
    # hazard apron under the control panel
    pl.hazard_stripes(b, 3.0, 0.3, (0, -1.42, 0.98), rot=face(FRONT), stripes=8)
    for s in (-1, 1):                                                              # corner brackets
        pl.box(b, (0.22, 0.22, 1.2), (s * 1.52, -1.38, 1.4), "CharcoalDark", bevel=0.03)
    # rear radiator + carry handles
    pl.vent_grille(b, 2.5, 1.15, 5, (0, CY + 1.62, 1.4), face(BACK), "CharcoalDark", "Black")
    tube_path(b, [(-1.0, 1.82, 2.0), (-1.0, 2.3, 2.0), (1.0, 2.3, 2.0), (1.0, 1.82, 2.0)], 0.07, "Orange")
    pl.stencil_panel(b, 1.2, 0.6, (0, CY + 1.45, 2.4), face((0, 0.93, 0.36)), "TanDark", "Charcoal", t=0.05)

    # --- fuel drums (olive), charcoal bands, orange filler caps
    for s in (-1, 1):
        dx = s * 2.4
        pl.cyl(b, 0.78, 3.5, (dx, 0.0, 1.5), "Olive", pl.AX_Y, segs=10)
        for yy in (-1.05, 1.05):
            pl.cyl(b, 0.82, 0.24, (dx, yy, 1.5), "CharcoalDark", pl.AX_Y, segs=10)
        pl.cyl(b, 0.6, 0.12, (dx, -1.78, 1.5), "Charcoal", pl.AX_Y, segs=10)          # front end plate
        pl.cyl(b, 0.28, 0.14, (dx, -1.86, 1.5), "Steel", pl.AX_Y, segs=8)
        pl.cyl(b, 0.3, 0.1, (dx, -0.5, 2.3), "Steel", segs=8)                          # filler neck
        pl.cyl(b, 0.2, 0.22, (dx, -0.5, 2.43), "Orange", segs=8)
        pl.box(b, (0.5, 0.5, 0.5), (dx, -1.5, 0.95), "CharcoalDark", bevel=0.04)       # cradle blocks
        pl.box(b, (0.5, 0.5, 0.5), (dx, 1.5, 0.95), "CharcoalDark", bevel=0.04)
        pl.stencil_panel(b, 0.9, 0.5, (dx + s * 0.78, 0.0, 1.55), face((s, 0, 0)), "Tan", "CharcoalDark", t=0.05)
        # pipe from drum nose to the housing
        pl.pipe(b, [(dx - s * 0.5, -1.9, 1.5), (dx - s * 0.5, -2.1, 1.1), (s * 1.0, -2.1, 1.1), (s * 1.0, -1.45, 1.1)],
                0.07, color="Black", joint="Charcoal")

    # --- turbine collar with the recessed glow core (Core part), spoke grille over it
    CX = -0.4
    pl.cyl(b, 1.4, 0.16, (CX, 0, 3.03), "Tan", segs=8)
    pl.lathe(b, [(0, 2.95), (1.16, 2.95), (1.16, 3.5), (1.02, 3.64), (0.9, 3.64), (0.9, 3.3), (0, 3.3)],
             (CX, 0, 0), "CharcoalDark", segs=8)
    pl.torus(b, 1.1, 0.07, (CX, 0, 3.66), "Steel", segs=8, csegs=4)
    for i in range(3):
        pl.box(b, (1.85, 0.12, 0.08), (CX, 0, 3.58), "Charcoal", rot=(0, 0, i * pi / 3), bevel=0)
    pl.cyl(b, 0.2, 0.14, (CX, 0, 3.58), "Steel", segs=8, bevel=0)
    for i in range(4):
        a = i * pi / 2 + pi / 4
        pl.box(b, (0.32, 0.32, 0.16), (CX + cos(a) * 1.08, sin(a) * 1.08, 3.66), "Orange", rot=(0, 0, a), bevel=0.02)
    pl.bolt_ring(b, (CX, 0, 3.64), (0, 0, 1), 1.0, 8, 0.045, "Steel")
    pl.cyl(core, 0.8, 0.14, (CX, 0, 3.4), segs=8, bevel=0)
    pl.cyl(core, 0.3, 0.5, (CX, 0, 3.55), segs=6, r2=0.2, bevel=0)

    # --- exhaust stack (smoke emitter sits at (1.2, 0, 5.2))
    pl.cyl(b, 0.55, 0.16, (1.2, 0, 3.03), "Steel", segs=8)
    pl.smokestack(b, (1.2, 0.0, 3.05), 0.3, 1.85, color="Charcoal", rim="Steel")
    pl.cyl(b, 0.4, 0.95, (1.2, 0.0, 3.6), "TanDark", segs=8)                           # heat shield
    pl.cyl(b, 0.43, 0.1, (1.2, 0.0, 4.15), "Orange", segs=8)
    pl.cyl(b, 0.22, 0.02, (1.2, 0.0, 4.92), "Black", segs=8, bevel=0)

    # --- antenna (rear left) with an orange bead
    pl.antenna(b, (-1.4, 1.25, 2.95), 1.5, color="Steel")
    pl.box(b, (0.14, 0.14, 0.14), (-1.4, 1.25, 4.5), "Orange", bevel=0)

    # --- ground cables with plugs
    tube_path(b, [(-1.2, -1.5, 1.05), (-1.45, -1.85, 0.84), (-1.7, -2.5, 0.84), (-1.8, -3.0, 0.5), (-1.95, -3.3, 0.12),
                  (-2.5, -3.5, 0.12)], 0.09, "Black")
    pl.box(b, (0.42, 0.55, 0.34), (-2.75, -3.5, 0.17), "Charcoal", bevel=0.05)
    pl.cyl(b, 0.2, 0.14, (-2.75, -3.8, 0.17), "Orange", pl.AX_Y, segs=8)
    tube_path(b, [(1.2, -1.5, 0.9), (1.4, -1.9, 0.84), (1.6, -2.5, 0.84), (1.8, -2.9, 0.4), (2.0, -3.15, 0.12)], 0.08, "Orange")
    pl.box(b, (0.4, 0.5, 0.32), (2.2, -3.2, 0.16), "Charcoal", bevel=0.05)

    # --- Switch: the obvious interact panel: raised box, tan face plate, display, 3 orange buttons, big lever, orange guard bars
    SP = (0, -1.42, 1.65)
    pl.box(sw, (1.9, 0.42, 1.28), (0, -1.6, 1.64), "Charcoal", bevel=0.06)
    pl.plate(sw, 1.64, 1.06, 0.08, (0, -1.84, 1.64), face(FRONT), "Tan", chamfer=0.12, bevel=0)
    pl.bolt_row(sw, (-0.72, -1.89, 2.1), (0.72, -1.89, 2.1), 4, FRONT, 0.045, "Steel")
    pl.bolt_row(sw, (-0.72, -1.89, 1.18), (0.72, -1.89, 1.18), 4, FRONT, 0.045, "Steel")
    pl.box(sw, (1.3, 0.05, 0.3), (0, -1.9, 1.9), "Visor", bevel=0)
    pl.box(sw, (1.1, 0.03, 0.08), (0, -1.93, 1.9), "Hazard", bevel=0)
    for x in (-0.5, 0.0, 0.5):
        pl.cyl(sw, 0.15, 0.06, (x, -1.9, 1.52), "Steel", pl.AX_Y, segs=8, bevel=0)
        pl.cyl(sw, 0.11, 0.1, (x, -1.94, 1.52), "Orange", pl.AX_Y, segs=8, bevel=0)
    pl.box(sw, (0.3, 0.05, 0.62), (0, -1.9, 1.28), "Black", bevel=0)                  # lever slot
    pl.rod(sw, (0, -1.93, 1.14), (0, -2.12, 1.42), 0.05, "Steel", segs=6)
    pl.box(sw, (0.5, 0.17, 0.17), (0, -2.14, 1.45), "Orange", bevel=0.03)
    pl.hazard_stripes(sw, 1.8, 0.14, (0, -1.82, 2.2), rot=face(FRONT), stripes=9)
    for s in (-1, 1):                                                                # guard bars
        pl.box(sw, (0.12, 0.34, 1.35), (s * 1.08, -1.8, 1.64), "Orange", bevel=0.03)
        pl.box(sw, (0.2, 0.2, 0.2), (s * 1.08, -1.62, 2.3), "Orange", bevel=0.03)
    return k, SP


# ================================================================== 2. trajectory_console
def trajectory_console():
    k = kit("trajectory_console")
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Charcoal")
    kb = k.part("Keyboard", "interact", "Metal", pivot=(0, -0.3, 1.18), parent="Body", color="CharcoalDark")
    sc = k.glow("Screen", rgb="4fd8ff", role="glow", pivot=(0, 0.62, 2.0), parent="Body")

    # plinth, feet
    pl.taper_box(b, (4.0, 2.8), (3.8, 2.6), 0.0, 0.42, "CharcoalDark")
    for x in (-1.7, 1.7):
        for y in (-1.15, 1.15):
            pl.box(b, (0.5, 0.5, 0.08), (x, y, 0.04), "Black", bevel=0)
    # desk: side profile (y, z); keyboard rides the sloped part, monitor stands on the rear block
    prof = [(-1.25, 0.4), (1.25, 0.4), (1.25, 1.55), (0.65, 1.55), (0.65, 1.38), (-1.25, 0.83)]
    pl.extrude(b, prof, 3.5, (0, 0, 0), "Charcoal", plane='YZ', bevel=0.06)
    # tan armour cheeks (inset copy of the profile) with rivets and glyphs
    cheek = [(-1.1, 0.55), (1.1, 0.55), (1.1, 1.45), (0.78, 1.45), (0.78, 1.28), (-1.1, 0.8)]
    for s in (-1, 1):
        pl.extrude(b, cheek, 0.1, (s * 1.78, 0, 0), "Tan", plane='YZ', bevel=0)
        pl.bolt_row(b, (s * 1.85, -0.95, 0.65), (s * 1.85, 0.95, 0.65), 4, (s, 0, 0), 0.045, "Steel")
        pl.stencil_panel(b, 0.8, 0.4, (s * 1.84, 0.25, 1.1), face((s, 0, 0)), "CharcoalDark", "Stencil", t=0.04)
        # orange side handle
        tube_path(b, [(s * 1.78, -0.95, 0.95), (s * 2.1, -0.95, 0.95), (s * 2.1, -0.05, 0.95), (s * 1.78, -0.05, 0.95)],
                  0.06, "Orange")
    # front lower face: hazard band + vents
    pl.hazard_stripes(b, 3.0, 0.3, (0, -1.26, 0.6), rot=face(FRONT), stripes=8)
    pl.box(b, (3.6, 0.06, 0.1), (0, -1.27, 0.86), "TanDark", bevel=0)
    pl.vent_grille(b, 1.0, 0.5, 4, (-1.05, 1.27, 0.95), face(BACK), "CharcoalDark", "Black")
    pl.vent_grille(b, 1.0, 0.5, 4, (1.05, 1.27, 0.95), face(BACK), "CharcoalDark", "Black")

    # monitor: tilted frame at the Screen pivot, glow plate recessed 0.1 behind the bezel front
    rx = radians(-14)
    O = Vector((0, 0.62, 2.0))
    f = pl.frame(O, (rx, 0, 0))

    def mb(size, local, color, bevel=None):
        return pl.box(b, size, f(local), color, (rx, 0, 0), bevel)
    mb((3.3, 0.36, 0.22), (0, 0.04, 0.695), "Charcoal")
    mb((3.3, 0.36, 0.22), (0, 0.04, -0.695), "Charcoal")
    mb((0.3, 0.36, 1.2), (-1.5, 0.04, 0), "Charcoal")
    mb((0.3, 0.36, 1.2), (1.5, 0.04, 0), "Charcoal")
    mb((3.1, 0.4, 1.5), (0, 0.4, 0), "CharcoalDark")
    mb((3.5, 0.62, 0.1), (0, -0.14, 0.9), "Tan", 0.03)                                   # sun hood
    for s in (-1, 1):
        mb((0.14, 0.5, 0.3), (s * 1.64, -0.1, 0.78), "Tan", 0.02)
    pl.box(sc, (2.7, 0.08, 1.15), O, rot=(rx, 0, 0), bevel=0)
    # screen grid + trajectory arc ticks drawn in the body part, just in front of the glow plate
    for xx in (-0.9, -0.3, 0.3, 0.9):
        pl.box(b, (0.03, 0.03, 1.1), f((xx, -0.07, 0)), "Visor", (rx, 0, 0), 0)
    for zz in (-0.3, 0.1, 0.5):
        pl.box(b, (2.6, 0.03, 0.03), f((0, -0.07, zz)), "Visor", (rx, 0, 0), 0)
    for i in range(7):
        t = i / 6
        pl.box(b, (0.22, 0.04, 0.07), f((-1.0 + 2.0 * t, -0.085, -0.42 + 1.9 * t * (1 - t))), "Orange", (rx, 0, 0), 0)
    # neck / struts under the monitor
    pl.box(b, (2.6, 0.6, 0.35), (0, 0.78, 1.4), "CharcoalDark", bevel=0.05)
    for s in (-1, 1):
        pl.box(b, (0.3, 0.5, 0.5), (s * 1.2, 0.95, 1.6), "Charcoal", bevel=0.04)
    # small unlit side displays on the rear block, tucked behind the bezel corners
    for s in (-1, 1):
        pl.box(b, (0.7, 0.12, 0.5), (s * 1.0, 1.12, 1.78), "Charcoal", rot=(radians(-18), 0, 0), bevel=0.03)
        pl.box(b, (0.54, 0.08, 0.36), (s * 1.0, 1.06, 1.79), "Visor", rot=(radians(-18), 0, 0), bevel=0)
    # antenna + orange tip, small stencil on the rear
    pl.antenna(b, (1.55, 1.0, 1.55), 1.35, color="Steel")
    pl.box(b, (0.13, 0.13, 0.13), (1.55, 1.0, 2.9), "Orange", bevel=0)
    pl.stencil_panel(b, 1.0, 0.5, (0, 1.27, 1.2), face(BACK), "Tan", "CharcoalDark", t=0.05)

    # keyboard (Keyboard part): tilted deck, tan keys, big orange EXECUTE bar, hazard lip, orange guard handles
    ang = radians(16)
    KP = (0, -0.3, 1.18)
    kf = pl.frame(KP, (ang, 0, 0))
    pl.box(kb, (2.5, 1.0, 0.16), KP, "CharcoalDark", (ang, 0, 0), 0.04)
    for r_ in range(3):
        for c_ in range(5):
            pl.box(kb, (0.26, 0.22, 0.1), kf((-0.88 + c_ * 0.3, -0.3 + r_ * 0.3, 0.12)), "Tan", (ang, 0, 0), 0)
    pl.box(kb, (0.5, 0.8, 0.14), kf((0.88, -0.02, 0.12)), "Orange", (ang, 0, 0), 0.03)
    pl.box(kb, (0.58, 0.08, 0.1), kf((0.88, -0.5, 0.11)), "Hazard", (ang, 0, 0), 0)
    pl.box(kb, (2.45, 0.1, 0.1), kf((0, -0.52, 0.1)), "TanDark", (ang, 0, 0), 0)
    for s in (-1, 1):
        pl.box(kb, (0.1, 0.9, 0.12), kf((s * 1.27, 0, 0.08)), "Orange", (ang, 0, 0), 0.02)
    return k, KP


# ================================================================== 3. missile_silo
def missile_silo():
    k = kit("missile_silo")
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Concrete")
    dl = k.part("Door_L", "door", "Metal", pivot=(5.5, 0, 0.62), parent="Body", color="Charcoal")
    dr = k.part("Door_R", "door", "Metal", pivot=(-5.5, 0, 0.62), parent="Body", color="Charcoal")
    ll = k.part("Lever_L", "interact", "Metal", pivot=(3.4, -8.2, 1.2), parent="Body", color="Charcoal")
    lr = k.part("Lever_R", "interact", "Metal", pivot=(-3.4, -8.2, 1.2), parent="Body", color="Charcoal")
    ms = k.part("Missile", "missile", "Metal", pivot=(0, 0, -12.8), parent="Body", color="Olive")

    # --- foundation ring and pit
    pl.cyl(b, 7.0, 0.4, (0, 0, 0.2), "Concrete", segs=16, bevel=0.08)
    pl.cyl(b, 5.75, 0.08, (0, 0, 0.42), "ConcreteDark", segs=16, bevel=0)
    pl.cyl(b, 5.6, 0.14, (0, 0, 0.45), "CharcoalDark", segs=16, bevel=0)
    for i in range(6):                                                                # radial grate bars
        pl.box(b, (11.0, 0.2, 0.06), (0, 0, 0.53), "Steel", rot=(0, 0, i * pi / 6), bevel=0)
    pl.torus(b, 3.6, 0.07, (0, 0, 0.54), "Steel", segs=16, csegs=4)
    pl.cyl(b, 1.9, 0.16, (0, 0, 0.52), "Black", segs=12, bevel=0)                    # launch mount
    pl.torus(b, 2.0, 0.11, (0, 0, 0.6), "Hazard", segs=12, csegs=4)
    # seat ring the doors close onto
    pl.torus(b, 5.7, 0.15, (0, 0, 0.5), "Steel", segs=16, csegs=4)

    # --- armoured collar: chunky blocks, tan caps, a few orange
    N = 16
    for kk in range(N):
        t = 2 * pi * (kk + 0.5) / N
        if abs(sin(t)) < 0.3:                                                         # keep the hinge corners clear
            continue
        px, py = cos(t) * 6.4, sin(t) * 6.4
        rot = (0, 0, t + pi / 2)
        pl.box(b, (1.8, 0.95, 0.5), (px, py, 0.62), "CharcoalDark", rot, 0.07)
        pl.box(b, (1.5, 0.7, 0.1), (px, py, 0.9), "Orange" if kk % 4 == 1 else "Tan", rot, 0)

    # --- hinge blocks (outer knuckles; the door barrel sits between them)
    for s in (-1, 1):
        for yy in (-1.8, 1.8):
            pl.box(b, (1.5, 1.2, 0.95), (s * 5.85, yy, 0.78), "Charcoal", bevel=0.12)
            pl.box(b, (1.5, 1.2, 0.1), (s * 5.85, yy, 1.28), "Tan", bevel=0.02)
            pl.cyl(b, 0.3, 1.2, (s * 5.5, yy, 0.62), "Steel", pl.AX_Y, segs=8)
            pl.cyl(b, 0.33, 0.1, (s * 5.5, yy + (0.6 if yy > 0 else -0.6), 0.62), "Orange", pl.AX_Y, segs=8)

    # --- lever stands on the ground slab
    pl.box(b, (9.2, 2.3, 0.2), (0, -8.2, 0.1), "CharcoalDark", bevel=0.06)
    pl.hazard_stripes(b, 8.8, 0.6, (0, -8.95, 0.215), stripes=12)
    pl.stencil_panel(b, 1.2, 0.7, (0, -7.55, 0.21), (0, 0, 0), "Tan", "CharcoalDark", t=0.03)
    for s in (-1, 1):
        sx = s * 3.4
        pl.cyl(b, 0.65, 0.22, (sx, -8.2, 0.31), "Charcoal", segs=8)
        pl.box(b, (0.55, 0.55, 0.7), (sx, -8.2, 0.55), "Tan", bevel=0.08)
        pl.box(b, (0.85, 0.85, 0.14), (sx, -8.2, 0.97), "Orange", bevel=0.04)
        for xo in (-0.3, 0.3):                                                         # clevis cheeks
            pl.box(b, (0.08, 0.5, 0.5), (sx + xo, -8.2, 1.2), "Steel", bevel=0)
        # travel quadrant plate (pulled = tipped toward the silo = +Y)
        arc = [(0.0, 0.0)] + [(1.45 * sin(radians(a)), 1.45 * cos(radians(a))) for a in (-60, -30, 0, 30, 60)]
        pl.extrude(b, arc, 0.08, (sx + 0.46, -8.2, 1.2), "Tan", plane='YZ', bevel=0)
        for a in (-35, 0, 35):
            pl.box(b, (0.1, 0.09, 0.28), (sx + 0.52, -8.2 + 1.2 * sin(radians(a)), 1.2 + 1.2 * cos(radians(a))),
                   "Orange" if a else "Black", rot=(radians(-a), 0, 0), bevel=0)
        pl.box(b, (0.5, 0.06, 0.4), (sx, -8.55, 0.55), "Visor", bevel=0)               # warning label
    # cable conduits slab -> ring
    for s in (-1, 1):
        pl.tube(b, [(s * 3.0, -7.75, 0.28), (s * 2.9, -7.4, 0.3), (s * 2.5, -6.9, 0.3)], 0.11, "Black", sides=6)

    # --- door leaves: half-polygon plates, hinge at the rim; tan armour, hazard seam, glyphs, orange handle
    def leaf(part, s):
        n = 8
        arc = [(s * cos(radians(-90 + i * 180 / n)) * 5.45, sin(radians(-90 + i * 180 / n)) * 5.45) for i in range(n + 1)]
        pl.extrude(part, arc, 0.3, (0, 0, 0.73), "Charcoal", plane='XY', bevel=0.08)
        r2 = 4.7
        tan = [(s * 0.55, -sqrt(r2 * r2 - 0.55 ** 2))] + \
              [(s * cos(radians(-90 + i * 180 / n)) * r2, sin(radians(-90 + i * 180 / n)) * r2) for i in range(1, n)] + \
              [(s * 0.55, sqrt(r2 * r2 - 0.55 ** 2))]
        pl.extrude(part, tan, 0.1, (0, 0, 0.93), "Tan", plane='XY', bevel=0)
        for x in (1.6, 3.5):                                                            # stiffener ribs
            L = 2 * sqrt(r2 * r2 - x * x) * 0.92
            pl.box(part, (0.22, L, 0.1), (s * x, 0, 1.03), "CharcoalDark", bevel=0.02)
        pl.hazard_stripes(part, 6.4, 0.45, (s * 0.31, 0, 0.9 + 0.015), rot=(0, 0, pi / 2), stripes=9)
        pl.stencil_panel(part, 1.5, 0.95, (s * 2.55, -0.0, 1.03), (0, 0, 0), "CharcoalDark", "Stencil", t=0.04)
        pl.cyl(part, 0.55, 0.05, (s * 2.55, 2.2, 1.0), "Orange", segs=8, bevel=0)
        pl.cyl(part, 0.55, 0.05, (s * 2.55, -2.2, 1.0), "Orange", segs=8, bevel=0)
        # grab handle + latch bars at the seam
        pl.box(part, (0.14, 1.3, 0.12), (s * 4.5, 0, 1.2), "Orange", bevel=0.03)
        for yy in (-0.6, 0.6):
            pl.box(part, (0.14, 0.14, 0.2), (s * 4.5, yy, 1.1), "Charcoal", bevel=0)
        for yy in (-2.6, 2.6):
            pl.box(part, (0.5, 0.35, 0.14), (s * 0.3, yy, 1.0), "Steel", bevel=0.03)
        # hinge barrel + strap
        pl.cyl(part, 0.26, 2.0, (s * 5.5, 0, 0.62), "Steel", pl.AX_Y, segs=8)
        pl.box(part, (1.1, 1.8, 0.14), (s * 4.95, 0, 0.86), "Charcoal", bevel=0.03)
        pl.bolt_row(part, (s * 4.7, -0.7, 0.96), (s * 4.7, 0.7, 0.96), 3, (0, 0, 1), 0.05, "Steel")
    leaf(dl, 1)
    leaf(dr, -1)

    # --- levers: hub on the clevis, steel arm, orange knob (the interactive bit)
    for part, s in ((ll, 1), (lr, -1)):
        pv = (s * 3.4, -8.2, 1.2)
        pl.cyl(part, 0.2, 0.42, pv, "Steel", pl.AX_X, segs=8, bevel=0)
        pl.rod(part, pv, (pv[0], pv[1], pv[2] + 1.45), 0.1, "Charcoal", segs=8)
        pl.box(part, (0.34, 0.34, 0.3), (pv[0], pv[1], pv[2] + 0.55), "Tan", bevel=0.05)
        pl.cyl(part, 0.32, 0.4, (pv[0], pv[1], pv[2] + 1.7), "Orange", segs=8, r2=0.28)
        pl.cyl(part, 0.12, 0.05, (pv[0], pv[1] - 0.3, pv[2] + 1.7), "Black", pl.AX_Y, segs=6, bevel=0)

    # --- the missile (olive ordnance), base 12.8 below ground
    DZ = -12.8
    Z = lambda z: z + DZ
    pl.cyl(ms, 1.5, 2.5, (0, 0, Z(2.15)), "Olive", segs=10)
    pl.cyl(ms, 1.58, 0.35, (0, 0, Z(3.5)), "CharcoalDark", segs=10)
    pl.cyl(ms, 1.5, 3.2, (0, 0, Z(5.25)), "Olive", segs=10)
    pl.cyl(ms, 1.57, 0.34, (0, 0, Z(6.1)), "Orange", segs=10)
    pl.cyl(ms, 1.58, 0.32, (0, 0, Z(6.95)), "CharcoalDark", segs=10)
    pl.cyl(ms, 1.5, 2.8, (0, 0, Z(8.6)), "Tan", segs=10, r2=0.7, bevel=0.05)
    pl.cyl(ms, 0.7, 1.4, (0, 0, Z(10.7)), "Orange", segs=10, r2=0.1, bevel=0.03)
    pl.lathe(ms, [(0, Z(0.25)), (0.7, Z(0.25)), (0.95, Z(0.0)), (1.25, Z(0.0)), (1.1, Z(0.95)), (1.3, Z(1.1)), (1.3, Z(1.4)),
                  (0, Z(1.4))], (0, 0, 0), "Charcoal", segs=10)                       # engine bell
    pl.cyl(ms, 0.66, 0.04, (0, 0, Z(0.27)), "Black", segs=10, bevel=0)
    for kk in range(4):                                                                  # swept fins
        az = radians(kk * 90 + 45)
        prof = [(1.3, 0.4), (3.2, 0.4), (3.2, 1.3), (1.3, 3.4)]
        pl.extrude(ms, [(x, Z(z)) for x, z in prof], 0.16, (0, 0, 0), "CharcoalDark", (0, 0, az), plane='XZ', bevel=0.02)
        tip = [(2.85, 0.4), (3.2, 0.4), (3.2, 1.3), (2.95, 1.05)]
        pl.extrude(ms, [(x, Z(z)) for x, z in tip], 0.2, (0, 0, 0), "Orange", (0, 0, az), plane='XZ', bevel=0)
    # stencil panels, umbilical hatch, lifting lugs, rivet rows
    fl = 1.43
    pl.stencil_panel(ms, 1.0, 1.5, (0, -fl - 0.02, Z(4.9)), face(FRONT), "Tan", "CharcoalDark", t=0.04)
    for a in (0, pi, pi / 2):
        pl.box(ms, (0.3, 0.3, 0.2), (cos(a) * 1.6, sin(a) * 1.6, Z(7.25)), "Orange", rot=(0, 0, a), bevel=0.02)

    k.pose = "silo"
    return k, None


# ================================================================== 4. uplink_dish
def uplink_dish():
    k = kit("uplink_dish")
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Charcoal")
    tm = k.part("Terminal", "interact", "Metal", pivot=(3.4, -1.6, 0.0), parent="Body", color="Charcoal")
    ds = k.part("Dish", "dish", "Metal", pivot=(0, 0.55, 5.2), parent="Body", color="Tan")
    AX = (0.0, 0.55)                                                                    # vertical axis of the mount

    # --- tripod outriggers, pads with jacks, mast base
    for kk in range(3):
        t = radians(90 + kk * 120)
        fx, fy = AX[0] + cos(t) * 2.55, AX[1] + sin(t) * 2.55
        pl.rod(b, (AX[0] + cos(t) * 0.6, AX[1] + sin(t) * 0.6, 2.3), (fx, fy, 0.32), 0.2, "Charcoal", segs=8, r2=0.17)
        pl.rod(b, (AX[0] + cos(t) * 0.5, AX[1] + sin(t) * 0.5, 0.95), (fx * 0.8 + AX[0] * 0.2, fy * 0.8 + AX[1] * 0.2, 0.75),
               0.09, "Steel", segs=6)
        pl.cyl(b, 0.62, 0.22, (fx, fy, 0.11), "CharcoalDark", segs=8)                    # pad
        pl.cyl(b, 0.25, 0.4, (fx, fy, 0.4), "Steel", segs=8)                              # jack
        pl.cyl(b, 0.32, 0.12, (fx, fy, 0.7), "Orange", segs=8)
        pl.box(b, (0.1, 0.5, 0.1), (fx, fy, 0.62), "Orange", rot=(0, 0, t), bevel=0)      # jack handle
        pl.hazard_stripes(b, 0.55, 0.14, (fx + cos(t) * 0.0, fy - 0.0, 0.235), rot=(0, 0, t), stripes=3)
    pl.cyl(b, 1.35, 0.3, (AX[0], AX[1], 0.15), "CharcoalDark", segs=8)                    # hub skid plate
    pl.taper_box(b, (1.6, 1.6), (1.2, 1.2), 0.3, 1.2, "Charcoal", loc=(AX[0], AX[1], 0))
    # mast: octagonal tower, tan collars
    pl.cyl(b, 0.55, 3.3, (AX[0], AX[1], 2.85), "Charcoal", segs=8, r2=0.45)
    for z, r in ((1.3, 0.64), (2.4, 0.58), (3.5, 0.52)):
        pl.cyl(b, r, 0.28, (AX[0], AX[1], z), "Tan", segs=8)
        pl.cyl(b, r + 0.03, 0.06, (AX[0], AX[1], z + 0.17), "CharcoalDark", segs=8)
    pl.cyl(b, 0.9, 0.16, (AX[0], AX[1], 4.5), "CharcoalDark", segs=8)                    # slew ring seat
    pl.torus(b, 0.88, 0.06, (AX[0], AX[1], 4.6), "Steel", segs=8, csegs=4)
    # equipment cabinet (tan armoured) at the back with vents + stencil, cable runs
    pl.box(b, (1.7, 0.9, 1.5), (AX[0], AX[1] + 1.1, 1.0), "Tan", bevel=0.1)
    pl.box(b, (1.8, 1.0, 0.14), (AX[0], AX[1] + 1.1, 1.78), "CharcoalDark", bevel=0.03)
    pl.vent_grille(b, 1.0, 0.7, 4, (AX[0] - 0.35, AX[1] + 1.57, 1.0), face(BACK), "CharcoalDark", "Black")
    pl.stencil_panel(b, 0.5, 0.5, (AX[0] + 0.55, AX[1] + 1.57, 1.2), face(BACK), "CharcoalDark", "Stencil", t=0.04)
    for s in (-1, 1):
        pl.box(b, (0.14, 0.3, 0.14), (AX[0] + s * 0.95, AX[1] + 1.1, 1.4), "Orange", bevel=0.02)
        pl.bolt_row(b, (AX[0] - 0.65, AX[1] + 0.64, 0.55), (AX[0] + 0.65, AX[1] + 0.64, 0.55), 4, (0, -1, 0), 0.05, "Steel")
    pl.pipe(b, [(AX[0] - 0.6, AX[1] + 0.7, 1.7), (AX[0] - 0.5, AX[1] + 0.5, 2.4), (AX[0] - 0.42, AX[1] + 0.2, 3.4)], 0.07,
            color="Black", joint="Charcoal")
    pl.antenna(b, (AX[0] + 0.7, AX[1] + 1.1, 1.85), 1.2, color="Steel")
    pl.box(b, (0.12, 0.12, 0.12), (AX[0] + 0.7, AX[1] + 1.1, 3.05), "Orange", bevel=0)

    # --- Terminal (interact): kiosk on a plinth facing the dish side, with a big socket, orange handles, hazard lip
    TP = (3.4, -1.6, 0.0)
    ty = radians(-25)
    TS = 1.2                                                                             # terminal scale (reads from 40 studs)
    tf0 = pl.frame(TP, (0, 0, ty))
    T = lambda p: tf0(Vector(p) * TS)
    sz = lambda v: tuple(x * TS for x in v)

    def tb(size, local, color, bevel=None, rot=None):
        return pl.box(tm, sz(size), T(local), color, (0, 0, ty) if rot is None else rot, bevel)
    pl.taper_box(tm, sz((1.6, 1.3)), sz((1.4, 1.1)), 0.0, 0.34 * TS, "CharcoalDark", loc=TP, rot=(0, 0, ty))
    tb((1.2, 0.95, 0.75), (0, 0.0, 0.7), "Charcoal", 0.07)
    sl = pl.Matrix.Rotation(ty, 3, 'Z') @ pl.Matrix.Rotation(radians(25), 3, 'X')      # sloped panel frame
    PC = Vector(T((0, -0.52, 1.28)))
    pl.plate(tm, 1.0 * TS, 0.7 * TS, 0.08, PC, sl.to_euler(), "Tan", chamfer=0.14, bevel=0)
    nrm = sl @ Vector((0, 0, 1))
    pf = lambda p: PC + sl @ (Vector(p) * TS)
    pl.cyl(tm, 0.26 * TS, 0.1, pf((0, 0.05, 0.08 / TS)), "Steel", pl.orient(nrm), segs=8, bevel=0)      # socket housing
    pl.cyl(tm, 0.17 * TS, 0.12, pf((0, 0.05, 0.1 / TS)), "Black", pl.orient(nrm), segs=8, bevel=0)
    pl.torus(tm, 0.27 * TS, 0.05, pf((0, 0.05, 0.12 / TS)), "Orange", pl.orient(nrm), segs=8, csegs=4)
    for xx in (-0.5, 0.5):
        pl.cyl(tm, 0.06 * TS, 0.05, pf((xx, -0.2, 0.08 / TS)), "Orange", pl.orient(nrm), segs=6, bevel=0)
    pl.stencil_panel(tm, 0.42 * TS, 0.22 * TS, pf((-0.28, 0.27, 0.07 / TS)), sl.to_euler(), "CharcoalDark", "Stencil", t=0.04)
    pl.box(tm, sz((0.9, 0.1, 0.1)), pf((0, -0.33, 0.07 / TS)), "Hazard", sl.to_euler(), 0)
    tb((1.3, 0.5, 0.1), (0, -0.2, 1.62), "TanDark", 0.02, rot=(radians(12), 0, ty))             # hood
    for s in (-1, 1):                                                                              # side handles
        tube_path(tm, [T((s * 0.62, -0.25, 0.5)), T((s * 0.9, -0.25, 0.5)), T((s * 0.9, 0.25, 0.5)), T((s * 0.62, 0.25, 0.5))],
                  0.055, "Orange")
    pl.antenna(tm, T((0.4, 0.3, 1.07)), 1.0, color="Steel")
    pl.box(tm, (0.13, 0.13, 0.13), T((0.4, 0.3, 1.07 + 1.0 / TS)), "Orange", rot=(0, 0, ty), bevel=0)
    tb((1.1, 0.14, 0.34), (0, -0.52, 0.4), "TanDark", 0.02)
    pl.hazard_stripes(tm, 1.0 * TS, 0.2 * TS, T((0, -0.53, 0.38)), face(Vector(T((0, -1, 0))) - Vector(TP)), stripes=6)

    # --- Dish: slewing drum + yoke + faceted tan bowl on a hub + feed horn on struts (yaws about the vertical axis at (0, 0.55))
    pl.cyl(ds, 0.8, 0.4, (AX[0], AX[1], 4.85), "CharcoalDark", segs=8)
    pl.cyl(ds, 0.92, 0.1, (AX[0], AX[1], 4.72), "Steel", segs=8)
    pl.bolt_ring(ds, (AX[0], AX[1], 5.05), (0, 0, 1), 0.62, 8, 0.05, "Steel")
    pl.box(ds, (0.14, 0.16, 0.14), (AX[0], AX[1] - 0.86, 4.78), "Orange", bevel=0)        # index mark
    OZ, OY = 5.35, 0.95
    rx = radians(45)
    bf = pl.frame((0, OY, OZ), (rx, 0, 0))
    hub = Vector(bf((0, 0, -0.5)))
    for s in (-1, 1):                                                                   # yoke cheeks + trunnion caps
        pl.box(ds, (0.3, 1.5, 1.1), (s * 0.82, 1.1, 5.0), "Tan", bevel=0.06)
        pl.box(ds, (0.2, 1.2, 0.3), (s * 0.82, 0.95, 4.75), "Charcoal", bevel=0.03)
        pl.cyl(ds, 0.26, 0.24, (s * 1.0, hub.y, hub.z), "Steel", pl.AX_X, segs=8)
        pl.cyl(ds, 0.18, 0.1, (s * 1.16, hub.y, hub.z), "Orange", pl.AX_X, segs=8, bevel=0)
        pl.bolt_row(ds, (s * 0.99, 0.65, 5.35), (s * 0.99, 1.45, 5.35), 3, (s, 0, 0), 0.05, "Steel")
    prof = [(0.0, -0.3), (0.55, -0.26), (1.25, -0.04), (1.95, 0.45), (2.4, 1.05), (2.4, 1.14), (1.95, 0.55), (1.25, 0.1),
            (0.55, -0.12), (0.0, -0.1)]
    pl.lathe(ds, prof, (0, OY, OZ), "Tan", (rx, 0, 0), segs=12)
    pl.torus(ds, 2.43, 0.075, bf((0, 0, 1.12)), "CharcoalDark", (rx, 0, 0), segs=12, csegs=4)
    for i in range(6):                                                                   # panel seams on the dish face
        a = i * pi / 3 + pi / 6
        pts = [bf((cos(a) * r, sin(a) * r, 0.1 + 0.9 * (r / 2.4) ** 2 + 0.02)) for r in (0.4, 0.9, 1.4, 1.9, 2.35)]
        pl.tube(ds, pts, 0.03, "TanDark", sides=4)
    pl.cyl(ds, 0.5, 0.45, bf((0, 0, -0.5)), "CharcoalDark", (rx, 0, 0), segs=8)             # motor hub
    pl.box(ds, (0.7, 0.6, 0.5), bf((0, 0.0, -0.78)), "Charcoal", (rx, 0, 0), 0.05)
    for i in range(4):                                                                   # feed struts
        a = radians(45 + 90 * i)
        pl.rod(ds, bf((cos(a) * 2.3, sin(a) * 2.3, 1.1)), bf((0, 0, 2.75)), 0.055, "Steel", segs=6)
    pl.cyl(ds, 0.3, 0.55, bf((0, 0, 2.85)), "Charcoal", (rx, 0, 0), segs=8)
    pl.cyl(ds, 0.36, 0.14, bf((0, 0, 3.14)), "Orange", (rx, 0, 0), segs=8)
    pl.cyl(ds, 0.2, 0.05, bf((0, 0, 2.55)), "Steel", (rx, 0, 0), segs=8, bevel=0)
    return k, None


BUILDERS = {"generator": generator, "trajectory_console": trajectory_console, "missile_silo": missile_silo,
            "uplink_dish": uplink_dish}

EXTRA = {
    "generator": {},
    "trajectory_console": {},
    "missile_silo": {
        "pose_open": {"Door_L": "rotate +72 deg about Y (hinge)", "Door_R": "rotate -72 deg about Y (hinge)",
                      "Lever_L/R": "rotate -28 deg about X (pivot)",
                      "Missile": "raise by +12.8 studs on Y (Roblox) to stand at the pit plate"},
        "note": "Rest pose = doors closed, Missile fully lowered (base 12.8 below ground). Size excludes Missile.",
    },
    "uplink_dish": {},
}


# ------------------------------------------------------------------ export / preview
def entry_for(k):
    e = k.manifest_entry()
    e["kind"] = "setpiece"
    e["rigVersion"] = 2
    e["fbx"] = f"art/fbx/new/{k.key}.fbx"
    e["texture"] = f"art/fbx/new/palette_{k.palette_name}.png"
    e["triangles_total"] = sum(p.tris for p in k.parts)
    e["source"] = "art/blender/objectives_v2.py"
    e.update(EXTRA.get(k.key, {}))
    return e


def relink(k):
    img = bpy.data.images.get(f"palette_{k.palette_name}")
    for p in k.parts:
        for n in p.obj.data.materials[0].node_tree.nodes:
            if n.type == 'TEX_IMAGE':
                n.image = img


def render(k, root, shots):
    import env_set1
    imgdir = os.path.join(root, "img")
    os.makedirs(imgdir, exist_ok=True)
    out = {}
    relink(k)
    if k.key == "missile_silo":
        return render_silo(k, imgdir)
    for name, cam in shots:
        out[name] = env_set1.stage(os.path.join(imgdir, f"{k.key}_new_{name}.png"), [k], size=(900, 900), cam_dir=cam)
    return out


def render_silo(k, imgdir):
    import env_set1
    P = {p.name: p.obj for p in k.parts}
    out = {}
    # closed / rest: missile hidden (it is under the ground), framed on the ground-level pieces
    P["Missile"].hide_render = True
    for name, cam in (("front", (0.35, -1.0, 0.45)), ("back", (-0.35, 1.0, 0.45))):
        out[name] = env_set1.stage(os.path.join(imgdir, f"missile_silo_new_{name}.png"), [k], size=(900, 900), cam_dir=cam,
                                   zoom=2.1, target=(7.0, -1.2, 1.5))
    # open pose: doors up, missile raised (the old setpieces pose_open)
    P["Missile"].hide_render = False
    P["Missile"].location.z += 12.8
    P["Door_L"].rotation_euler = (0, radians(72), 0)
    P["Door_R"].rotation_euler = (0, radians(-72), 0)
    for ob in (P["Lever_L"], P["Lever_R"]):
        ob.rotation_euler = (radians(28), 0, 0)
    bpy.context.view_layer.update()
    out["open"] = env_set1.stage(os.path.join(imgdir, "missile_silo_new_open.png"), [k], size=(900, 900),
                                 cam_dir=(0.45, -1.0, 0.35), zoom=1.0)
    return out


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = ROOT_DEFAULT
    only = None
    if "--out" in argv:
        root = os.path.abspath(argv[argv.index("--out") + 1])
    if "--only" in argv:
        only = argv[argv.index("--only") + 1].split(",")
    do_render = "--no-render" not in argv
    do_export = "--no-export" not in argv
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'          # 1 BU = 1 stud in Roblox
    for key, fn in BUILDERS.items():
        if only and key not in only:
            continue
        k, _ = fn()
        k.build()
        k.report()
        # render() imports env_set1, which reloads parts_lib and resets FBX_SETTINGS: set the scale before every export
        pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'
        if do_export:
            k.export_fbx()
            os.makedirs(os.path.join(root, "entry"), exist_ok=True)
            with open(os.path.join(root, "entry", f"{key}.entry.json"), "w", encoding="utf-8") as f:
                json.dump(entry_for(k), f, indent=2)
        if do_render:
            print("RENDERED", render(k, root, (("front", (0.35, -1.0, 0.42)), ("back", (-0.35, 1.0, 0.42)))))
        print("TRIS", key, sum(p.tris for p in k.parts))


if __name__ == "__main__":
    main()
