"""SET C: Halcyon weapons. Held in the right hand, pointing -Y, origin = grip. Each has a tiny "Muzzle" object at the tip.
run: blender -b --python weapons.py   (exports wpn_<name>.fbx for all, manifest entries, and wpn_lineup.png)"""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import kit
import halcyon as H
from halcyon import CYAN, METAL


def Y(px, r, y0, y1, x=0.0, z=0.0, r2=None, verts=14, bevel=0.03, seg=1):
    """Cylinder along Y from y0 to y1 (r2 = radius at the y-min / front end)."""
    px.cyl(r, abs(y1 - y0), (x, (y0 + y1) / 2, z), rot=(90, 0, 0), r2=r2, verts=verts, bevel=bevel, seg=seg)


def grip(a, y=0.05, tilt=-10, h=1.0, z=-0.15, color=None, w=0.36):
    (color or a.navy).box((w, 0.42, h), (0, y, z), rot=(tilt, 0, 0), bevel=0.1, seg=2)
    a.metal.box((w + 0.04, 0.46, 0.12), (0, y + 0.02, z - h / 2 + 0.05), rot=(tilt, 0, 0), bevel=0.03, seg=1)


def guard(a, y=-0.45, z=-0.1):
    a.metal.box((0.1, 0.5, 0.08), (0, y, z - 0.18), bevel=0.02, seg=1)
    a.metal.box((0.1, 0.08, 0.3), (0, y - 0.24, z - 0.05), bevel=0.02, seg=1)


def sight(a, y, z, px=None):
    (px or a.metal).box((0.1, 0.12, 0.2), (0, y, z), bevel=0.02, seg=1)


# ------------------------------------------------------------------------------------------------ weapons
def carbine(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a)
    guard(a)
    w.box((0.52, 1.7, 0.62), (0, -0.55, 0.5), bevel=0.12, seg=2)                              # receiver
    nv.box((0.34, 1.5, 0.14), (0, -0.55, 0.88), bevel=0.04, seg=1)                            # top rail
    nv.box((0.54, 1.1, 0.5), (0, -1.85, 0.46), bevel=0.1, seg=2)                              # handguard
    og.box((0.56, 0.14, 0.5), (0, -1.3, 0.46), bevel=0.03, seg=1)
    Y(mt, 0.11, -2.4, -3.1, z=0.5)                                                           # barrel
    Y(og, 0.17, -2.95, -3.2, z=0.5, verts=12)                                                # muzzle brake
    w.box((0.4, 1.2, 0.56), (0, 0.9, 0.32), rot=(-6, 0, 0), bevel=0.1, seg=2)               # stock
    nv.box((0.42, 0.18, 0.72), (0, 1.55, 0.28), bevel=0.05, seg=1)                            # butt pad
    og.box((0.3, 0.5, 0.85), (0, -0.55, -0.4), rot=(8, 0, 0), bevel=0.06, seg=1)             # magazine
    Y(nv, 0.17, -0.3, -1.1, z=1.05)                                                          # optic
    a.glass.cyl(0.12, 0.05, (0, -1.12, 1.05), rot=(90, 0, 0), verts=10, bevel=0)
    sight(a, -2.9, 0.78)
    return (0, -3.25, 0.5)


def shotgun(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, tilt=-14)
    guard(a)
    w.box((0.56, 1.5, 0.66), (0, -0.55, 0.45), bevel=0.14, seg=2)                              # receiver
    Y(mt, 0.2, -1.2, -3.6, z=0.55, verts=16)                                                 # fat barrel
    Y(nv, 0.17, -1.2, -3.2, z=0.05, verts=14)                                                # tube magazine
    Y(og, 0.22, -3.2, -3.35, z=0.05, verts=14)
    nv.box((0.5, 1.0, 0.4), (0, -2.0, 0.0), bevel=0.1, seg=2)                                 # pump
    og.box((0.52, 0.12, 0.42), (0, -1.55, 0.0), bevel=0.03, seg=1)
    og.box((0.52, 0.12, 0.42), (0, -2.45, 0.0), bevel=0.03, seg=1)
    Y(og, 0.24, -3.5, -3.7, z=0.55, verts=14)                                                # muzzle ring
    nv.box((0.44, 1.5, 0.66), (0, 0.95, 0.2), rot=(-12, 0, 0), bevel=0.12, seg=2)            # stock
    mt.box((0.46, 0.16, 0.8), (0, 1.75, 0.12), bevel=0.04, seg=1)
    mt.box((0.4, 0.5, 0.1), (0, -0.4, 0.82), bevel=0.02, seg=1)                               # ejection port
    og.ball(0.1, (0, -3.55, 0.86), segs=8)                                                   # bead sight
    mt.box((0.08, 0.08, 0.22), (0, -3.5, 0.77), bevel=0.0, seg=1)
    return (0, -3.72, 0.55)


def marksman(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, tilt=-8)
    guard(a)
    w.box((0.5, 2.0, 0.6), (0, -0.7, 0.5), bevel=0.12, seg=2)
    nv.box((0.5, 1.9, 0.5), (0, -2.9, 0.46), bevel=0.1, seg=2)                                # forend
    Y(mt, 0.11, -3.8, -5.6, z=0.5)                                                           # long barrel
    Y(nv, 0.15, -5.0, -5.5, z=0.5, verts=12)
    Y(og, 0.18, -5.5, -5.9, z=0.5, verts=12)                                                 # suppressor/brake
    w.box((0.4, 1.9, 0.62), (0, 1.15, 0.28), rot=(-7, 0, 0), bevel=0.12, seg=2)               # stock
    nv.box((0.42, 0.7, 0.34), (0, 1.1, 0.64), bevel=0.08, seg=1)                             # cheek riser
    nv.box((0.42, 0.18, 0.78), (0, 2.15, 0.24), bevel=0.05, seg=1)
    og.box((0.3, 0.45, 0.6), (0, -0.55, -0.3), rot=(8, 0, 0), bevel=0.06, seg=1)
    # scope
    Y(nv, 0.24, -0.6, -2.3, z=1.2, verts=16, bevel=0.05)
    Y(og, 0.28, -0.8, -0.95, z=1.2, verts=16)
    Y(og, 0.3, -2.1, -2.3, z=1.2, verts=16)
    a.glass.cyl(0.2, 0.05, (0, -2.32, 1.2), rot=(90, 0, 0), verts=14, bevel=0)
    mt.box((0.12, 0.3, 0.3), (0, -0.9, 0.95), bevel=0.02, seg=1)
    mt.box((0.12, 0.3, 0.3), (0, -2.0, 0.95), bevel=0.02, seg=1)
    # folded bipod
    for s in (-1, 1):
        mt.tube((s * 0.2, -3.4, 0.2), (s * 0.35, -4.3, -0.2), 0.05, verts=6, bevel=0)
    return (0, -5.95, 0.5)


def smg(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, tilt=-6, h=0.95)
    guard(a, y=-0.4)
    w.box((0.54, 1.5, 0.66), (0, -0.4, 0.45), bevel=0.14, seg=2)
    nv.box((0.36, 1.1, 0.14), (0, -0.4, 0.84), bevel=0.04, seg=1)
    og.box((0.56, 0.5, 0.4), (0, -1.3, 0.4), bevel=0.08, seg=1)                               # front shroud
    Y(nv, 0.2, -1.5, -2.5, z=0.5, verts=14, bevel=0.05)                                      # suppressor
    Y(og, 0.21, -1.9, -2.0, z=0.5, verts=14)
    nv.box((0.34, 0.32, 1.2), (0, -0.55, -0.55), rot=(2, 0, 0), bevel=0.06, seg=1)           # long mag
    og.box((0.36, 0.34, 0.2), (0, -0.55, -1.12), bevel=0.04, seg=1)
    mt.tube((0, 0.35, 0.55), (0, 1.3, 0.35), 0.07, verts=8, bevel=0)                          # wire stock
    mt.tube((0, 1.3, 0.35), (0, 1.3, -0.05), 0.07, verts=8, bevel=0)
    nv.box((0.34, 0.2, 0.5), (0, 1.3, 0.15), bevel=0.05, seg=1)
    sight(a, -1.3, 0.78)
    return (0, -2.55, 0.5)


def rocket_tube(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, y=-0.7, tilt=-6, z=-0.1)
    grip(a, y=-2.4, tilt=6, z=-0.05, h=0.9)                                                   # fore grip
    Y(w, 0.55, -4.3, 1.9, z=0.95, verts=20, bevel=0.1, seg=2)                                 # main tube
    Y(nv, 0.6, -4.4, -3.8, z=0.95, verts=20)                                                  # muzzle collar
    Y(og, 0.6, -3.7, -3.5, z=0.95, verts=20)
    Y(nv, 0.6, 0.9, 1.4, z=0.95, verts=20)
    Y(og, 0.6, 0.7, 0.8, z=0.95, verts=20)
    Y(mt, 0.5, 1.9, 2.6, z=0.95, verts=18, r2=0.4)                                            # rear venturi
    Y(og, 0.62, -1.2, -1.0, z=0.95, verts=20)
    nv.box((0.5, 1.6, 0.34), (0, -0.7, 0.34), bevel=0.1, seg=2)                               # grip block
    nv.box((0.32, 0.9, 0.3), (0, -1.5, 1.65), bevel=0.08, seg=1)                              # sight block
    a.glass.box((0.22, 0.08, 0.2), (0, -1.96, 1.74), bevel=0.02, seg=1)
    og.box((0.26, 0.3, 0.12), (0, -1.0, 1.55), bevel=0.03, seg=1)
    nv.box((0.4, 0.5, 0.2), (0, 0.9, 0.34), bevel=0.05, seg=1)
    # rocket tip visible in the muzzle
    og.cyl(0.35, 0.5, (0, -4.15, 0.95), rot=(90, 0, 0), r2=0.1, verts=14, bevel=0.03)
    return (0, -4.45, 0.95)


def gatling(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, y=0.1, tilt=-8, h=1.0)
    grip(a, y=-1.2, tilt=0, z=-0.15, h=0.9)                                                   # fore grip
    w.box((1.1, 1.8, 1.0), (0, -0.2, 0.75), bevel=0.2, seg=2)                                 # motor housing
    nv.box((1.14, 0.5, 1.04), (0, 0.8, 0.75), bevel=0.14, seg=2)
    og.box((0.6, 0.9, 0.3), (0, 0.0, 1.38), bevel=0.08, seg=1)                                # carry handle bar
    for s in (-1, 1):
        mt.tube((s * 0.3, 0.55, 1.5), (s * 0.3, -0.35, 1.5), 0.07, verts=8, bevel=0)
    nv.box((1.0, 1.0, 1.1), (0, 0.25, -0.65), bevel=0.14, seg=2)                              # ammo drum block
    og.cyl(0.55, 1.0, (0, 0.25, -0.62), rot=(0, 90, 0), verts=16, bevel=0.08, seg=1)
    nv.box((0.4, 1.0, 0.36), (0, -0.7, -0.15), bevel=0.08, seg=1)
    # shroud + muzzle ring (static)
    Y(nv, 0.62, -1.2, -1.7, z=0.75, verts=18, bevel=0.06)
    Y(og, 0.64, -1.7, -1.85, z=0.75, verts=18)
    Y(nv, 0.58, -4.2, -4.4, z=0.75, verts=18, bevel=0.05)                                     # front sight ring
    # spinning barrel assembly: origin on the spin axis
    a.limb("Barrels", "spin", "Body", pivot=(0, -2.9, 0.75))
    for k in range(6):
        ang = 2 * math.pi * k / 6
        x, z = math.cos(ang) * 0.34, 0.75 + math.sin(ang) * 0.34
        Y(mt, 0.11, -2.0, -4.2, x=x, z=z, verts=10, bevel=0.02)
        Y(nv, 0.14, -4.0, -4.2, x=x, z=z, verts=10, bevel=0.02)
    Y(og, 0.5, -1.85, -2.05, z=0.75, verts=16)
    Y(nv, 0.5, -2.8, -3.0, z=0.75, verts=16)
    Y(og, 0.5, -3.55, -3.7, z=0.75, verts=16)
    Y(nv, 0.2, -1.85, -4.25, z=0.75, verts=10, bevel=0.02)                                    # centre spindle
    return (0, -4.45, 0.75)


def rail_lance(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, tilt=-12)
    guard(a)
    nv.box((0.6, 2.2, 0.56), (0, -0.7, 0.42), bevel=0.12, seg=2)                              # spine
    w.box((0.74, 1.4, 0.7), (0, -0.4, 0.62), bevel=0.15, seg=2)                               # power block
    og.box((0.76, 0.16, 0.72), (0, -1.15, 0.62), bevel=0.03, seg=1)
    # twin rails
    for s in (-1, 1):
        w.box((0.16, 4.2, 0.2), (s * 0.3, -3.5, 0.88), bevel=0.05, seg=1)
        nv.box((0.12, 4.2, 0.12), (s * 0.3, -3.5, 0.72), bevel=0.03, seg=1)
    nv.box((0.5, 3.8, 0.12), (0, -3.5, 0.38), bevel=0.04, seg=1)
    for yy in (-2.0, -3.0, -4.0, -5.0):
        nv.box((0.8, 0.22, 0.4), (0, yy, 0.65), bevel=0.06, seg=1)                            # coil housings
    nv.box((0.8, 0.3, 0.46), (0, -5.5, 0.65), bevel=0.06, seg=1)
    og.box((0.36, 0.5, 0.3), (0, -2.5, 1.18), bevel=0.06, seg=1)
    nv.box((0.42, 1.3, 0.5), (0, 0.9, 0.34), rot=(-8, 0, 0), bevel=0.1, seg=2)               # stock
    og.box((0.44, 0.18, 0.64), (0, 1.55, 0.3), bevel=0.04, seg=1)
    mt.box((0.3, 0.3, 0.5), (0, -0.7, -0.3), bevel=0.06, seg=1)
    co = a.glow("Coils", CYAN, "glow", "Body", pivot=(0, -3.5, 0.65))                         # glowing coil rings
    for yy in (-2.35, -3.35, -4.35, -5.2):
        co.box((0.84, 0.12, 0.44), (0, yy, 0.65), bevel=0.05, seg=1)
    co.box((0.14, 3.4, 0.08), (0, -3.6, 1.0), bevel=0.02, seg=1)
    return (0, -5.75, 0.65)


def pistol(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    grip(a, tilt=-14, h=0.95, color=nv, w=0.4)
    guard(a, y=-0.45, z=-0.1)
    w.box((0.46, 1.5, 0.46), (0, -0.7, 0.3), bevel=0.1, seg=2)                                # slide
    mt.box((0.4, 1.4, 0.18), (0, -0.7, 0.0), bevel=0.04, seg=1)
    Y(mt, 0.09, -1.45, -1.9, z=0.3, verts=10)
    og.box((0.48, 0.12, 0.48), (0, -0.15, 0.3), bevel=0.03, seg=1)
    og.box((0.48, 0.5, 0.1), (0, -0.9, 0.58), bevel=0.03, seg=1)
    sight(a, -1.3, 0.62)
    return (0, -1.95, 0.3)


# ---- grenades / beacon: centre of mass at the grip, "Muzzle" marks the throw-forward point
def frag_grenade(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    og.ball(0.5, (0, 0, 0), scale=(0.9, 1.0, 1.05), segs=14)                                  # body
    nv.cyl(0.5, 0.12, (0, 0, 0.0), rot=(90, 0, 0), verts=14, bevel=0.02, seg=1)
    for z in (-0.3, 0.3):
        nv.cyl(0.46 if abs(z) < 0.31 else 0.4, 0.1, (0, 0, z), verts=14, bevel=0.02, seg=1)
    mt.cyl(0.18, 0.22, (0, 0, 0.58), verts=10, bevel=0.03, seg=1)                             # fuze
    nv.box((0.12, 0.7, 0.1), (0, 0.15, 0.7), bevel=0.02, seg=1)                               # safety lever (spoon)
    mt.tube((0.0, -0.22, 0.62), (0, -0.55, 0.5), 0.035, verts=6, bevel=0)                    # pin
    mt.ball(0.09, (0, -0.6, 0.45), scale=(0.5, 1, 1), segs=8)
    return (0, -0.55, 0.0)


def impact_grenade(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    Y(w, 0.38, -0.55, 0.55, verts=16, bevel=0.1, seg=2)
    Y(og, 0.4, -0.15, 0.1, verts=16)
    Y(nv, 0.39, 0.3, 0.52, verts=16)
    og.cyl(0.38, 0.5, (0, -0.8, 0), rot=(90, 0, 0), r2=0.12, verts=16, bevel=0.04)            # nose cone contact fuze
    mt.ball(0.1, (0, -1.08, 0), segs=8)
    for s in (-1, 1):
        nv.box((0.08, 0.35, 0.34), (s * 0.4, 0.55, 0), rot=(0, 0, s * -10), bevel=0.02, seg=1)
        nv.box((0.34, 0.35, 0.08), (0, 0.55, s * 0.4), bevel=0.02, seg=1)
    return (0, -1.1, 0.0)


def stun_grenade(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    Y(w, 0.36, -0.45, 0.45, verts=16, bevel=0.08, seg=2)
    Y(nv, 0.4, -0.7, -0.45, verts=16, bevel=0.06)                                             # end caps
    Y(nv, 0.4, 0.45, 0.7, verts=16, bevel=0.06)
    og.box((0.1, 0.7, 0.14), (0, -0.0, 0.42), bevel=0.02, seg=1)
    mt.cyl(0.14, 0.2, (0, 0, 0.45), verts=8, bevel=0.02, seg=1)
    g = a.glow("Glow", CYAN, "glow", "Body", pivot=(0, 0, 0))                                 # glowing band
    Y(g, 0.4, -0.12, 0.12, verts=16, bevel=0.02)
    return (0, -0.72, 0.0)


def beacon(a):
    w, nv, og, mt = a.white, a.navy, a.orange, a.metal
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    Y(mt, 0.12, -1.7, -0.5, verts=8, bevel=0.02, r2=0.02)                                     # spike
    Y(w, 0.2, -0.55, 0.4, verts=12, bevel=0.05, seg=1)                                        # shaft
    Y(og, 0.24, -0.6, -0.35, verts=12)
    Y(nv, 0.24, -0.0, 0.2, verts=12)
    Y(og, 0.24, 0.3, 0.45, verts=12)
    nv.box((0.5, 0.5, 0.1), (0, -0.4, 0.2), bevel=0.02, seg=1)                                # foot plate (step)
    nv.cyl(0.35, 0.18, (0, 0.55, 0), rot=(90, 0, 0), verts=14, bevel=0.04, seg=1)             # head socket
    for k in range(3):
        ang = 2 * math.pi * k / 3 + 0.5
        mt.tube((math.cos(ang) * 0.3, 0.6, math.sin(ang) * 0.3), (math.cos(ang) * 0.36, 0.95, math.sin(ang) * 0.36), 0.04, verts=6, bevel=0)
    h = a.glow("Head", CYAN, "glow", "Body", pivot=(0, 1.0, 0))                               # glowing head
    h.ball(0.38, (0, 1.0, 0), segs=14)
    return (0, -1.72, 0.0)


WEAPONS = [("carbine", carbine), ("shotgun", shotgun), ("marksman", marksman), ("smg", smg), ("rocket_tube", rocket_tube),
           ("gatling", gatling), ("rail_lance", rail_lance), ("pistol", pistol),
           ("frag_grenade", frag_grenade), ("impact_grenade", impact_grenade), ("stun_grenade", stun_grenade), ("beacon", beacon)]


def make(name, fn, ox=0.0, oy=0.0):
    a = H.Asset("wpn_" + name, fbx="wpn_" + name, kind="weapon")
    tip = fn(a)
    m = a.solid("Muzzle", METAL, "SmoothPlastic", "muzzle", parent="Body", pivot=tip)
    m.box((0.1, 0.1, 0.1), tip, bevel=0.0, seg=1)
    a.build(ox, oy)
    return a


def render_singles():
    """One image per weapon (side view, muzzle left) -> images/wpn_<name>.png. No FBX export."""
    from mathutils import Vector
    for name, fn in WEAPONS:
        kit.reset()
        make(name, fn)
        objs = [o for o in bpy.data.objects if o.type == "MESH" and not o.name.startswith("_")]
        pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
        lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
        hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
        lift = 0.6 - lo.z
        for o in objs:
            if o.parent is None:
                o.location.z += lift
        c = (lo + hi) / 2
        span = max(hi.y - lo.y, (hi.z - lo.z) * 1.6)
        kit.stage(target=(c.x, c.y, (hi.z - lo.z) / 2 + 0.6), dist=40, height=0, yaw=90, size=(900, 600),
                  floor=(max(4, hi.x - lo.x + 2), span + 2), ortho=span * 1.35, boost=1.2)
        bpy.data.objects.remove(bpy.data.objects["_Floor"])  # plain backdrop for the gallery
        kit.render("wpn_" + name)


def main():
    if os.environ.get("SINGLES"):  # SINGLES=1 blender -b --python weapons.py
        render_singles()
        return
    only = os.environ.get("ONLY")
    if not only:
        for name, fn in WEAPONS:
            kit.reset()
            a = make(name, fn)
            tot = a.over(total=3000)
            if "NOEXPORT" not in os.environ:
                a.write_manifest("wpn_" + name, notes="Right-hand grip at origin, pointing -Y. Muzzle = tip object.")
                a.export()
    kit.reset()
    # lineup: side view, muzzles point left; rows stacked in Z, columns along Y
    pos = {"marksman": (0, 0), "rail_lance": (1, 0), "rocket_tube": (2, 0), "gatling": (3, 0),
           "carbine": (0, 1), "shotgun": (1, 1), "smg": (2, 1), "pistol": (3, 1),
           "frag_grenade": (0, 2), "impact_grenade": (1, 2), "stun_grenade": (2, 2), "beacon": (3, 2)}
    for name, fn in WEAPONS:
        row, col = pos[name]
        a = make(name, fn, oy=(col - 1) * 10.5 + [1.5, 1.0, 0.0][col])
        for L in a.limbs.values():
            L.obj.location.z += (3 - row) * 3.7 + 1.4
    kit.stage(target=(0, 1.0, 6.2), dist=60, height=4, yaw=90, lens=50, size=(1400, 760), floor=(8, 40), ortho=34, boost=1.2)
    kit.render("wpn_lineup")


main()
