"""SET A (2..9): Orbitfall objective set pieces. run: ONLY=<name> blender -b --python setpieces.py   (default: all)
Each sits on the ground (origin = base centre), faces -Y, interactables are separate named objects."""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import kit
import halcyon as H
from halcyon import Frame, CYAN, AMBER, ALIEN, METAL
from kit import GUNMETAL, DARK, RUST, YELLOW

PIECES = {}


def piece(fn):
    PIECES[fn.__name__] = fn
    return fn


def Y(px, r, y0, y1, x=0.0, z=0.0, r2=None, verts=14, bevel=0.03, seg=1):
    px.cyl(r, abs(y1 - y0), (x, (y0 + y1) / 2, z), rot=(90, 0, 0), r2=r2, verts=verts, bevel=bevel, seg=seg)


def X(px, r, x0, x1, y=0.0, z=0.0, verts=14, bevel=0.03, seg=1):
    px.cyl(r, abs(x1 - x0), ((x0 + x1) / 2, y, z), rot=(0, 90, 0), verts=verts, bevel=bevel, seg=seg)


def ring(px, c, r, rt, n=18, axis="z", verts=6):
    """Ring of tube segments (radius r, tube radius rt) around centre c."""
    pts = []
    for i in range(n + 1):
        t = 2 * math.pi * i / n
        if axis == "z":
            pts.append((c[0] + math.cos(t) * r, c[1] + math.sin(t) * r, c[2]))
        elif axis == "y":
            pts.append((c[0] + math.cos(t) * r, c[1], c[2] + math.sin(t) * r))
        else:
            pts.append((c[0], c[1] + math.cos(t) * r, c[2] + math.sin(t) * r))
    for p, q in zip(pts[:-1], pts[1:]):
        px.tube(p, q, rt, verts=verts, bevel=0)


# ================================================================================ 2. generator
@piece
def generator():
    a = H.Asset("generator")
    wh, nv, og, mt, ndk, stl, wsh, nlt = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.white_sh, a.navy_lt
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    nv.box((5.8, 5.0, 0.5), (0, 0, 0.25), bevel=0.15, seg=2)                                  # skid base
    for s in (-1, 1):
        mt.box((0.55, 5.8, 0.28), (s * 2.3, 0, 0.14), bevel=0.08, seg=1)
        og.box((0.62, 0.5, 0.34), (s * 2.3, 2.9, 0.17), bevel=0.06, seg=1)
    wh.box((3.4, 3.0, 2.3), (0, 0.3, 1.65), bevel=0.32, seg=3)                                # housing
    og.box((3.5, 3.1, 0.5), (0, 0.3, 2.95), bevel=0.16, seg=2)
    nv.box((3.52, 3.12, 0.3), (0, 0.3, 1.2), bevel=0.08, seg=1)                               # waist band
    for yy in (0.0, 1.0):                                                                     # side vents
        for s in (-1, 1):
            nv.box((0.12, 0.7, 1.0), (s * 1.75, yy + 0.3, 1.9), bevel=0.03, seg=1)
            for zz in (1.6, 1.9, 2.2):
                mt.box((0.14, 0.7, 0.06), (s * 1.76, yy + 0.3, zz), bevel=0.0, seg=1)
    wh.box((2.6, 0.3, 1.0), (0, 1.9, 1.7), bevel=0.08, seg=1)                                 # rear radiator
    for k in range(5):
        mt.box((2.4, 0.2, 0.08), (0, 2.1, 1.35 + k * 0.17), bevel=0.0, seg=1)
    # fuel tanks (both sides) with straps
    for s in (-1, 1):
        Y(og, 0.8, -1.8, 1.9, x=s * 2.35, z=1.35, verts=18, bevel=0.2, seg=2)
        for yy in (-1.0, 0.9):
            Y(nv, 0.84, yy - 0.12, yy + 0.12, x=s * 2.35, z=1.35, verts=18, bevel=0.02)
        mt.cyl(0.25, 0.3, (s * 2.35, -0.3, 2.25), verts=10, bevel=0.04)                        # filler cap
        wh.box((0.5, 0.5, 0.06), (s * 2.35, 0.7, 2.18), bevel=0.0, seg=1)
    # exhaust stack + core turbine collar + antenna
    mt.cyl(0.32, 1.8, (1.1, 1.0, 3.9), verts=12, bevel=0.05)
    stl.cyl(0.4, 0.2, (1.1, 1.0, 4.9), verts=12, bevel=0.04)
    og.cyl(0.35, 0.14, (1.1, 1.0, 4.2), verts=12, bevel=0.02)
    nv.cyl(1.15, 0.5, (-0.4, 0.0, 3.4), verts=22, bevel=0.1, seg=2)                           # turbine collar
    ndk.cyl(0.85, 0.12, (-0.4, 0.0, 3.68), verts=20, bevel=0.0)
    for k in range(6):
        t = k * math.pi / 3
        nv.box((0.12, 1.5, 0.1), (-0.4, 0.0, 3.72), rot=(0, 0, math.degrees(t)), bevel=0.0, seg=1)
    stl.tube((-1.4, 1.2, 3.0), (-1.7, 1.5, 4.6), 0.04, verts=6, bevel=0)
    og.ball(0.1, (-1.7, 1.5, 4.65), segs=8)
    # cables: front-left bundle to the ground, loop with plug
    for (a0, a1, rr, c) in [((-1.3, -1.55, 0.6), (-1.9, -2.6, 0.12), 0.1, mt), ((-1.9, -2.6, 0.12), (-2.8, -3.0, 0.12), 0.1, mt),
                            ((-1.1, -1.55, 0.9), (-1.0, -2.4, 0.15), 0.1, nv), ((-1.0, -2.4, 0.15), (0.2, -3.0, 0.12), 0.1, nv),
                            ((1.2, -1.5, 0.7), (1.5, -2.2, 0.12), 0.08, og), ((1.5, -2.2, 0.12), (2.4, -2.4, 0.12), 0.08, og)]:
        c.tube(a0, a1, rr, verts=8, bevel=0)
    mt.box((0.4, 0.5, 0.35), (-2.8, -3.0, 0.2), bevel=0.06, seg=1)
    og.box((0.3, 0.2, 0.28), (-2.8, -3.3, 0.2), bevel=0.04, seg=1)
    mt.box((0.4, 0.5, 0.35), (2.4, -2.5, 0.2), bevel=0.06, seg=1)
    # front: recess for the switch panel + warning chevrons
    ndk.box((1.8, 0.1, 1.3), (0, -1.2, 1.65), bevel=0.03, seg=1)
    for k in range(6):
        (og if k % 2 == 0 else nv).box((0.4, 0.06, 0.18), (-1.25 + k * 0.5, -1.22, 0.62), rot=(0, 0, 0), bevel=0.0, seg=1)
    # switch panel (interact)
    SP = (0, -1.42, 1.65)
    a.limb("Switch", "interact", "Body", pivot=SP)
    nv.box((1.5, 0.28, 1.1), SP, bevel=0.07, seg=1)
    wh.box((1.3, 0.1, 0.9), (0, -1.58, 1.65), bevel=0.04, seg=1)
    ndk.box((1.1, 0.06, 0.34), (0, -1.65, 1.95), bevel=0.02, seg=1)
    for s in (-1, 0, 1):
        og.cyl(0.11, 0.1, (s * 0.38, -1.66, 1.45), rot=(90, 0, 0), verts=10, bevel=0.01)
        mt.box((0.08, 0.34, 0.1), (s * 0.38, -1.78, 1.45), bevel=0.01, seg=1)
    og.box((0.22, 0.3, 0.5), (0.45, -1.8, 1.75), rot=(-20, 0, 0), bevel=0.04, seg=1)      # big lever handle
    # glowing core ring on top
    core = a.glow("Core", CYAN, "glow", "Body", pivot=(-0.4, 0.0, 3.75))
    ring(core, (-0.4, 0.0, 3.76), 0.98, 0.1, n=20)
    return a, dict(target=(0, 0, 2.2), dist=15, height=6, yaw=-35, floor=12)


# ================================================================================ 3. trajectory_console
@piece
def trajectory_console():
    a = H.Asset("trajectory_console")
    wh, nv, og, mt, ndk, stl, nlt, gl = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.navy_lt, a.glass
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    nv.box((3.8, 2.8, 0.4), (0, 0, 0.2), bevel=0.12, seg=2)                                    # plinth
    wh.hull([(-1.8, -1.1, 0.4), (1.8, -1.1, 0.4), (-1.8, 1.1, 0.4), (1.8, 1.1, 0.4),
             (-1.85, -1.0, 1.05), (1.85, -1.0, 1.05), (-1.85, 1.0, 1.55), (1.85, 1.0, 1.55)], bevel=0.14, seg=2)   # desk wedge
    nv.box((3.9, 0.26, 0.22), (0, -1.12, 0.8), bevel=0.05, seg=1)
    og.box((3.9, 0.2, 0.12), (0, -1.1, 0.55), bevel=0.03, seg=1)
    # armrest wings
    for s in (-1, 1):
        nv.box((0.5, 2.2, 0.28), (s * 1.9, 0.0, 1.3), rot=(10, 0, 0), bevel=0.08, seg=1)
        og.cyl(0.16, 0.18, (s * 1.45, -0.4, 1.3), verts=10, bevel=0.03)                        # knobs
        og.cyl(0.16, 0.18, (s * 1.0, -0.25, 1.28), verts=10, bevel=0.03)
    # monitor on an arm
    nv.box((3.1, 0.34, 1.55), (0, 0.78, 2.0), rot=(-14, 0, 0), bevel=0.12, seg=2)              # bezel
    wh.box((3.2, 0.22, 0.2), (0, 0.9, 2.82), rot=(-14, 0, 0), bevel=0.06, seg=1)               # hood
    for s in (-1, 1):
        mt.box((0.3, 0.5, 0.9), (s * 1.2, 0.95, 1.55), bevel=0.05, seg=1)                      # support legs
    # side mini screens (unlit)
    for s in (-1, 1):
        nv.box((0.8, 0.12, 0.6), (s * 1.45, 0.1, 1.9), rot=(-20, s * 12, 0), bevel=0.04, seg=1)
        gl.box((0.62, 0.08, 0.44), (s * 1.45, -0.0, 1.93), rot=(-20, s * 12, 0), bevel=0.02, seg=1)
    # antenna + beacon light stalk
    stl.tube((1.6, 0.9, 1.6), (1.7, 1.0, 2.7), 0.04, verts=6, bevel=0)
    og.ball(0.1, (1.7, 1.0, 2.75), segs=8)
    mt.tube((-1.6, 0.9, 1.6), (-1.5, 0.9, 2.45), 0.05, verts=6, bevel=0)
    # keyboard (interact)
    KP = (0, -0.3, 1.18)
    a.limb("Keyboard", "interact", "Body", pivot=KP)
    ang = 16
    kf = Frame(loc=KP, rot=(ang, 0, 0))
    kf.box(nv, (2.3, 0.95, 0.16), (0, 0, 0), bevel=0.05, seg=1)
    for r_ in range(3):
        for c_ in range(8):
            (og if (r_ == 0 and c_ in (0, 7)) else nlt).box((0.22, 0.2, 0.1), (-0.9 + c_ * 0.26, -0.25 + r_ * 0.26, 0.1), bevel=0.02, seg=1) if False else None
    for r_ in range(3):
        for c_ in range(7):
            (og if (r_ == 2 and c_ == 6) else a.white).box((0.24, 0.22, 0.1), (-0.78 + c_ * 0.26, -0.28 + r_ * 0.27, 0.12), rot=(0, 0, 0), bevel=0.02, seg=1) if False else None
            kf.box(og if (r_ == 2 and c_ == 6) else a.white_sh, (0.22, 0.2, 0.1), (-0.78 + c_ * 0.26, -0.28 + r_ * 0.27, 0.1), bevel=0.02, seg=1)
    kf.box(og, (0.5, 0.2, 0.1), (0.8, -0.3, 0.1), bevel=0.02, seg=1)
    # glow screen
    s_ = a.glow("Screen", CYAN, "glow", "Body", pivot=(0, 0.62, 2.0))
    sf = Frame(loc=(0, 0.6, 2.0), rot=(-14, 0, 0))
    sf.box(s_, (2.7, 0.1, 1.15), (0, 0, 0), bevel=0.06, seg=1)
    a.use("Body")                                                                                 # dark grid + trajectory arc drawn over the glow
    for zz in (-0.3, 0.0, 0.3):
        sf.box(ndk, (2.5, 0.04, 0.03), (0, -0.07, zz), bevel=0.0, seg=1)
    for xx in (-0.9, -0.3, 0.3, 0.9):
        sf.box(ndk, (0.03, 0.04, 1.0), (xx, -0.07, 0), bevel=0.0, seg=1)
    for k in range(9):
        t = k / 8.0
        sf.box(og, (0.2, 0.05, 0.07), (-1.0 + 2.0 * t, -0.09, -0.4 + 4 * 0.2 * t * (1 - t) * 2.0), rot=(0, 0, 0), bevel=0.0, seg=1)
    sf.ball(og, 0.1, (1.05, -0.1, -0.4), segs=8)
    return a, dict(target=(0, 0, 1.4), dist=10, height=4, yaw=-32, floor=7)


# ================================================================================ 4. missile_silo
@piece
def missile_silo():
    a = H.Asset("missile_silo")
    wh, nv, og, mt, ndk, stl, scr, nlt, wsh = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.scorch, a.navy_lt, a.white_sh
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    R_, HZ = 7.0, 0.5
    wh.cyl(R_, 0.4, (0, 0, 0.2), verts=32, bevel=0.1, seg=1)                                   # foundation ring
    scr.cyl(5.6, 0.12, (0, 0, 0.42), verts=28, bevel=0.0)                                      # pit plate (dark)
    for k in range(8):                                                                          # radial grate bars
        t = k * 180 / 8
        nlt.box((11.0, 0.18, 0.06), (0, 0, 0.5), rot=(0, 0, t), bevel=0.0, seg=1)
    ring(ndk, (0, 0, 0.5), 3.6, 0.1, n=16, verts=4)
    og.cyl(1.1, 0.1, (0, 0, 0.52), verts=16, bevel=0.0)
    # armoured collar: hazard blocks all around
    N = 22
    for k in range(N):
        t = 2 * math.pi * k / N
        px_, py_ = math.cos(t) * 6.35, math.sin(t) * 6.35
        c = og if k % 2 == 0 else nv
        c.box((1.2, 0.9, 0.5), (px_, py_, 0.62), rot=(0, 0, math.degrees(t) + 90), bevel=0.1, seg=1)
    ring(mt, (0, 0, 0.5), 5.7, 0.14, n=24, verts=4)
    # hinge blocks and hydraulic pistons
    for s in (-1, 1):
        nv.box((1.4, 2.6, 0.9), (s * 5.7, 0.0, 0.7), bevel=0.15, seg=2)
        for yy in (-1.5, 1.5):
            stl.tube((s * 5.0, yy, 0.55), (s * 4.0, yy, 0.65), 0.1, verts=8, bevel=0)
            mt.cyl(0.18, 0.5, (s * 6.3, yy, 0.9), rot=(90, 0, 0), verts=10, bevel=0.03)
    # lever stands (static) + warning plates
    for s, n in ((1, "L"), (-1, "R")):
        sx = s * 3.4
        nv.cyl(0.55, 0.22, (sx, -8.2, 0.11), verts=14, bevel=0.04)
        wh.box((0.5, 0.5, 0.9), (sx, -8.2, 0.65), bevel=0.1, seg=1)
        og.box((0.62, 0.62, 0.14), (sx, -8.2, 1.13), bevel=0.04, seg=1)
        ndk.box((0.7, 0.1, 0.5), (sx, -8.52, 0.7), bevel=0.02, seg=1)
        for k in range(3):
            (og if k % 2 == 0 else nv).box((0.8, 0.14, 0.3), (sx, -9.0 + 0.0, 0.15), bevel=0.0, seg=1) if False else None
    # ground slab connecting levers to the ring
    nv.box((9.0, 2.2, 0.2), (0, -8.2, 0.1), bevel=0.06, seg=1)
    for k in range(9):
        (og if k % 2 == 0 else wsh).box((0.9, 2.0, 0.22), (-4.0 + k * 1.0, -8.2, 0.11), bevel=0.0, seg=1)
    # cable run
    for (p, q) in [((-3.4, -7.8, 0.3), (-3.0, -6.6, 0.3)), ((3.4, -7.8, 0.3), (3.0, -6.6, 0.3))]:
        mt.tube(p, q, 0.12, verts=8, bevel=0)

    # door leaves: half discs, origin at the hinge on the ring's rim
    def leaf(name, s):
        hx = s * 5.5
        a.limb(name, "door", "Body", pivot=(hx, 0, 0.62))
        pts = []
        for k in range(13):
            t = math.radians(-90 + k * 15)
            pts += [(s * math.cos(t) * 5.45, math.sin(t) * 5.45, 0.58), (s * math.cos(t) * 5.45, math.sin(t) * 5.45, 0.9)]
        wh.hull(pts, bevel=0.1, seg=2)
        for k in range(1, 4):                                                                   # stiffener ribs
            nv.box((0.4, 10.4 * math.sin(math.acos(k * 1.3 / 5.45)), 0.1), (s * k * 1.3, 0, 0.92), bevel=0.02, seg=1)
        nv.cyl(1.4, 0.1, (s * 2.9, 0, 0.93), verts=18, bevel=0.0)
        og.cyl(0.75, 0.12, (s * 2.9, 0, 0.94), verts=16, bevel=0.0)
        for k in range(5):                                                                      # hazard stripes at the seam
            (og if k % 2 == 0 else nv).box((0.5, 1.5, 0.12), (s * 0.3, -3.2 + k * 1.6, 0.92), bevel=0.0, seg=1)
        for k in range(5):
            og.box((0.7, 0.35, 0.12), (s * 4.7, -2.2 + k * 1.1, 0.92), rot=(0, 0, 28 * s), bevel=0.0, seg=1) if False else None
        wh.box((0.6, 2.4, 0.18), (s * 5.2, 0, 0.9), bevel=0.04, seg=1)                          # hinge strap
    leaf("Door_L", 1)
    leaf("Door_R", -1)

    # levers (origin at pivot, which sits on the stand's cap)
    for s, n in ((1, "L"), (-1, "R")):
        pv = (s * 3.4, -8.2, 1.2)
        a.limb("Lever_" + n, "interact", "Body", pivot=pv)
        nv.cyl(0.2, 0.28, pv, rot=(0, 90, 0), verts=12, bevel=0.04)                              # pivot hub
        lf = Frame(loc=pv, rot=(0, 0, 0))
        mt.tube((pv[0], pv[1], pv[2]), (pv[0], pv[1] + 0.0, pv[2] + 1.5), 0.1, verts=8, bevel=0)
        og.ball(0.3, (pv[0], pv[1], pv[2] + 1.62), segs=12)
        nv.box((0.5, 0.2, 0.26), (pv[0], pv[1] + 0.12, pv[2] + 0.5), bevel=0.04, seg=1)

    # the missile: fat cartoon, base at the origin (lowered under the pit plate), 12 tall
    DZ = -12.8
    a.limb("Missile", "missile", "Body", pivot=(0, 0, DZ))
    Z = lambda z: z + DZ
    wh.cyl(1.55, 6.0, (0, 0, Z(4.2)), verts=16, bevel=0.15, seg=1)
    wh.cyl(1.55, 2.8, (0, 0, Z(8.6)), r2=0.7, verts=16, bevel=0.12, seg=1)                       # ogive
    og.cyl(0.7, 1.4, (0, 0, Z(10.7)), r2=0.1, verts=16, bevel=0.05, seg=1)                        # nose tip
    og.cyl(1.62, 0.8, (0, 0, Z(6.6)), verts=16, bevel=0.04)
    nv.cyl(1.6, 0.4, (0, 0, Z(5.6)), verts=16, bevel=0.03)
    nv.cyl(1.6, 0.4, (0, 0, Z(7.6)), verts=16, bevel=0.03)
    og.cyl(1.6, 0.5, (0, 0, Z(1.7)), verts=16, bevel=0.04)
    mt.cyl(1.0, 0.8, (0, 0, Z(0.4)), r2=1.3, verts=18, bevel=0.06)                               # nozzle
    ndk.cyl(0.8, 0.1, (0, 0, Z(0.0)), verts=16, bevel=0)
    for k in range(4):                                                                           # fins
        t = k * 90 + 45
        ff = Frame(loc=(0, 0, 0), rot=(0, 0, t))
        ff.hull(og, [(1.4, -0.12, Z(0.4)), (1.4, 0.12, Z(0.4)), (1.4, -0.12, Z(3.4)), (1.4, 0.12, Z(3.4)),
                     (3.3, -0.08, Z(0.4)), (3.3, 0.08, Z(0.4))], bevel=0.04, seg=1)
    for k in range(3):
        Frame(rot=(0, 0, k * 120)).cyl(nv, 0.4, 0.14, (0, -1.55, Z(4.4)), rot=(90, 0, 0), verts=10, bevel=0.0)
    a.pose_open = dict(angles={"Door_L": (0, 72, 0), "Door_R": (0, -72, 0), "Lever_L": (-28, 0, 0), "Lever_R": (-28, 0, 0)}, offsets={"Missile": (0, 0, 13.1)})
    a.extras = dict(pose_open={"Door_L": "rotate +72 deg about Y (hinge)", "Door_R": "rotate -72 deg about Y (hinge)", "Lever_L/R": "rotate -28 deg about X (pivot)",
                               "Missile": "raise by +12.8 studs on Y (Roblox) to stand at the pit plate"},
                    note="Rest pose = doors closed, Missile fully lowered (base 12.8 below ground). Size excludes Missile.")
    return a, dict(target=(0, -0.5, 4.5), dist=38, height=15, yaw=-28, floor=24, pose=True)


# ================================================================================ 5. uplink_dish
@piece
def uplink_dish():
    a = H.Asset("uplink_dish")
    wh, nv, og, mt, ndk, stl, nlt, gl, slate = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.navy_lt, a.glass, a.slate
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    # tripod
    for k in range(3):
        t = math.radians(90 + k * 120)
        fx, fy = math.cos(t) * 2.6, math.sin(t) * 2.6
        nv.tube((fx, fy, 0.25), (fx * 0.18, fy * 0.18, 2.9), 0.18, r2=0.14, verts=10, bevel=0)
        mt.cyl(0.5, 0.25, (fx, fy, 0.125), verts=12, bevel=0.05)
        og.cyl(0.3, 0.12, (fx, fy, 0.3), verts=10, bevel=0.02)
        stl.tube((fx * 0.55, fy * 0.55, 1.5), (math.cos(t + 2.1) * 1.4, math.sin(t + 2.1) * 1.4, 1.5), 0.05, verts=6, bevel=0) if False else None
    for k in range(3):
        t1, t2 = math.radians(90 + k * 120), math.radians(90 + (k + 1) * 120)
        stl.tube((math.cos(t1) * 1.5, math.sin(t1) * 1.5, 1.4), (math.cos(t2) * 1.5, math.sin(t2) * 1.5, 1.4), 0.05, verts=6, bevel=0)
    nv.cyl(0.7, 0.5, (0, 0, 2.95), verts=16, bevel=0.08, seg=2)                                 # hub
    wh.tube((0, 0, 3.0), (0, 1.5, 4.2), 0.42, verts=14, bevel=0)                                  # raked mast
    og.cyl(0.46, 0.14, (0, 0, 3.0), verts=14, bevel=0.02)
    # yoke: low bar + two arms reaching outside the dish rim
    nv.box((6.2, 0.55, 0.4), (0, 1.5, 4.3), bevel=0.1, seg=1)
    for s in (-1, 1):
        wh.box((0.4, 0.6, 1.9), (s * 2.95, 1.1, 5.1), bevel=0.1, seg=1)
        og.cyl(0.3, 0.3, (s * 2.7, 0.55, 5.2), rot=(0, 90, 0), verts=12, bevel=0.03)
        mt.cyl(0.12, 0.7, (s * 2.35, 0.55, 5.2), rot=(0, 90, 0), verts=8, bevel=0.0)
        nv.box((0.4, 0.7, 0.4), (s * 2.95, 0.85, 4.2), bevel=0.05, seg=1)
    # terminal (interact) on a pedestal beside the tripod
    TP = (3.4, -1.6, 0.0)
    a.limb("Terminal", "interact", "Body", pivot=TP)
    tf = Frame(loc=TP, rot=(0, 0, -25))
    tf.box(nv, (1.5, 1.2, 0.35), (0, 0, 0.18), bevel=0.1, seg=1)
    tf.box(wh, (1.1, 0.9, 0.7), (0, 0.0, 0.7), bevel=0.14, seg=2)
    tf.hull(wh, [(-0.7, -0.5, 1.0), (0.7, -0.5, 1.0), (-0.7, 0.4, 1.6), (0.7, 0.4, 1.6), (-0.7, -0.5, 1.1), (0.7, -0.5, 1.1)], bevel=0.08, seg=1)
    tf.box(ndk, (1.1, 0.1, 0.7), (0, -0.28, 1.35), rot=(-30, 0, 0), bevel=0.03, seg=1)
    tf.box(gl, (0.9, 0.06, 0.5), (0, -0.33, 1.34), rot=(-30, 0, 0), bevel=0.02, seg=1)
    tf.box(og, (1.0, 0.4, 0.1), (0, -0.55, 0.98), bevel=0.03, seg=1)
    tf.tube(stl, (0.5, 0.2, 1.6), (0.6, 0.3, 2.3), 0.04, verts=6, bevel=0)
    tf.ball(og, 0.09, (0.6, 0.3, 2.35), segs=8)
    # the dish: origin at the elevation pivot
    DP = (0, 0.55, 5.2)
    a.limb("Dish", "dish", "Body", pivot=DP)
    f = Frame(loc=DP, rot=(-25, 0, 0))                                                           # tilted up toward the sky
    sec = lambda y, r: (y, r, r, 0.0, 2.0)
    f.loft(wh, [sec(0.7, 0.15), sec(0.45, 1.1), sec(0.0, 2.0), sec(-0.5, 2.45), sec(-0.52, 2.3), sec(-0.1, 1.85), sec(0.35, 0.95), sec(0.55, 0.15)], n=22)
    f.loft(slate, [sec(-0.12, 1.84), sec(0.30, 0.95), sec(0.5, 0.2)], n=22, cap0=True, cap1=True) if False else None
    for i in range(24):                                                                          # rim band
        t1, t2 = 2 * math.pi * i / 24, 2 * math.pi * (i + 1) / 24
        f.tube(nv, (math.cos(t1) * 2.42, -0.5, math.sin(t1) * 2.42), (math.cos(t2) * 2.42, -0.5, math.sin(t2) * 2.42), 0.1, verts=6, bevel=0)
    ring(og, (0, -0.52, 0), 2.35, 0.07, n=24, axis="y") if False else None
    f.cyl(og, 0.55, 0.2, (0, 0.55, 0), rot=(90, 0, 0), verts=14, bevel=0.03)                     # hub boss
    for k in range(4):                                                                           # feed arms
        t = math.radians(k * 90 + 45)
        f.tube(stl, (math.cos(t) * 2.3, -0.5, math.sin(t) * 2.3), (0, -2.4, 0), 0.06, verts=6, bevel=0)
    f.cyl(nv, 0.28, 0.5, (0, -2.5, 0), rot=(90, 0, 0), verts=12, bevel=0.04)
    f.ball(gl, 0.22, (0, -2.8, 0), segs=10)
    f.cyl(og, 0.3, 0.12, (0, -2.28, 0), rot=(90, 0, 0), verts=12, bevel=0.02)
    f.box(nv, (0.25, 0.9, 0.5), (0, 0.9, 0), bevel=0.05, seg=1)                                  # back counterweight
    return a, dict(target=(0.6, 0, 3.6), dist=19, height=6, yaw=-35, floor=12)


# ================================================================================ 6. extraction_pad
@piece
def extraction_pad():
    a = H.Asset("extraction_pad")
    wh, nv, og, mt, ndk, stl, nlt, wsh = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.navy_lt, a.white_sh
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    R_ = 8.0
    hexpts = lambda r, z: [(math.cos(math.radians(60 * k)) * r, math.sin(math.radians(60 * k)) * r, z) for k in range(6)]
    nv.hull(hexpts(R_, 0.0) + hexpts(R_ - 0.15, 0.5), bevel=0.12, seg=2)                         # slab
    wsh.hull(hexpts(R_ - 1.4, 0.5) + hexpts(R_ - 1.5, 0.56), bevel=0.02, seg=1)                  # inner deck plate
    # hazard edge: alternating blocks along each side
    for k in range(6):
        a0, a1 = math.radians(60 * k), math.radians(60 * (k + 1))
        p0 = (math.cos(a0) * (R_ - 0.7), math.sin(a0) * (R_ - 0.7))
        p1 = (math.cos(a1) * (R_ - 0.7), math.sin(a1) * (R_ - 0.7))
        ang = math.degrees(math.atan2(p1[1] - p0[1], p1[0] - p0[0]))
        L = math.hypot(p1[0] - p0[0], p1[1] - p0[1])
        n = 7
        for i in range(n):
            t = (i + 0.5) / n
            c = og if i % 2 == 0 else ndk
            c.box((L / n * 0.98, 0.9, 0.12), (p0[0] + (p1[0] - p0[0]) * t, p0[1] + (p1[1] - p0[1]) * t, 0.56), rot=(0, 0, ang), bevel=0.0, seg=1)
    # circle + H
    ring(og, (0, 0, 0.58), 4.6, 0.16, n=36, verts=6)
    ring(wh, (0, 0, 0.58), 4.1, 0.08, n=36, verts=6)
    for (x, y, w_, h_) in [(-1.3, 0, 0.7, 4.4), (1.3, 0, 0.7, 4.4), (0, 0, 2.0, 0.7)]:
        og.box((w_, h_, 0.12), (x, y, 0.58), bevel=0.04, seg=1)
    # tie-down rings, grating stripes
    for k in range(6):
        t = math.radians(60 * k + 30)
        mt.cyl(0.35, 0.14, (math.cos(t) * 6.0, math.sin(t) * 6.0, 0.57), verts=12, bevel=0.03)
        nlt.cyl(0.2, 0.15, (math.cos(t) * 6.0, math.sin(t) * 6.0, 0.58), verts=10, bevel=0.0)
    for k in range(5):
        for s in (-1, 1):
            nlt.box((0.5, 2.4, 0.04), (s * 2.9 + (k - 2) * 0.0, -1.0 + (k - 2) * 0.0, 0.56), bevel=0.0, seg=1) if False else None
    # four light posts at the corners (poles in Body, lamp heads are glow objects)
    posts = [(1, 60), (2, 120), (3, 240), (4, 300)]
    for n, ang in posts:
        t = math.radians(ang)
        px_, py_ = math.cos(t) * (R_ - 1.1), math.sin(t) * (R_ - 1.1)
        nv.cyl(0.55, 0.3, (px_, py_, 0.65), verts=12, bevel=0.06)
        mt.cyl(0.2, 2.4, (px_, py_, 1.8), verts=10, bevel=0.03)
        og.cyl(0.26, 0.15, (px_, py_, 1.2), verts=10, bevel=0.02)
        wh.cyl(0.42, 0.2, (px_, py_, 3.0), verts=12, bevel=0.04)
        og.cyl(0.46, 0.1, (px_, py_, 3.15), verts=12, bevel=0.0)
    for n, ang in posts:
        t = math.radians(ang)
        px_, py_ = math.cos(t) * (R_ - 1.1), math.sin(t) * (R_ - 1.1)
        g = a.glow("Light_%d" % n, CYAN, "glow", "Body", pivot=(px_, py_, 3.45))
        g.cyl(0.34, 0.5, (px_, py_, 3.45), verts=14, bevel=0.08, seg=1)
    return a, dict(target=(0, 0, 0.8), dist=30, height=14, yaw=-30, floor=22)


# ================================================================================ 7. skiff
@piece
def skiff():
    a = H.Asset("skiff")
    wh, nv, og, mt, ndk, stl, nlt, gl, wsh = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.navy_lt, a.glass, a.white_sh
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    F = Frame()
    SEC = [(-11.0, .6, .6, 2.6, 2.2), (-10.4, 1.6, 1.3, 2.7, 2.8), (-8.6, 2.6, 2.0, 3.0, 3.4), (-5.0, 3.1, 2.4, 3.2, 3.9),
           (0.0, 3.2, 2.5, 3.3, 4.2), (5.0, 3.0, 2.4, 3.3, 4.2), (9.0, 2.5, 2.1, 3.2, 3.8), (10.8, 2.1, 1.8, 3.1, 3.5)]
    F.loft(wh, SEC, n=24)
    F.cutbox(wh, (3.3, 3.4, 2.6), (0, 10.3, 2.75))                                              # rear bay
    F.loft(nv, [(-9.5, 1.6, .7, 1.8, 3.0), (-6, 2.7, .9, 1.9, 3.4), (0, 3.0, 1.0, 1.95, 3.6), (6, 2.7, .9, 1.95, 3.4), (10.5, 2.2, .8, 2.0, 3.2)], n=18)
    F.loft(og, [(-10.35, 1.6, 1.3, 2.7, 2.8), (-10.0, 1.9, 1.55, 2.78, 3.0)], n=24) if False else None
    og.cyl(0.1, 0.1, (0, -10.9, 2.6), verts=6, bevel=0) if False else None
    # nose band + stripes
    F.box(og, (4.0, 0.3, 0.5), (0, -10.2, 3.0), bevel=0.05, seg=1, rot=(-8, 0, 0)) if False else None
    for s in (-1, 1):
        F.box(og, (0.16, 9.0, 0.6), (s * 3.12, -2.0, 3.2), bevel=0.05, seg=1)
        F.box(nv, (0.18, 5.0, 0.32), (s * 3.12, 5.0, 3.2), bevel=0.04, seg=1)
        for k in range(5):                                                                       # portholes
            F.box(nv, (0.2, 1.0, 0.9), (s * 3.15, -6.5 + k * 1.6, 4.1), bevel=0.2, seg=1) if False else None
            F.cyl(nv, 0.5, 0.2, (s * 3.14, -6.4 + k * 1.7, 4.1), rot=(0, 90, 0), verts=10, bevel=0.0)
            F.cyl(gl, 0.38, 0.24, (s * 3.15, -6.4 + k * 1.7, 4.1), rot=(0, 90, 0), verts=10, bevel=0.0)
    # roof: dorsal fin + hatch
    F.loft(nv, [(-2.0, 0.6, .35, 5.5, 3.0), (-1.2, 1.4, .45, 5.55, 4), (4.0, 1.4, .45, 5.55, 4), (5.0, 0.7, .35, 5.5, 3.0)], n=14)
    F.box(og, (1.6, 2.2, 0.14), (0, 1.2, 6.0), bevel=0.05, seg=1)
    # canopy (big glass wedge, friendly)
    F.hull(gl, [(-1.4, -10.2, 3.4), (1.4, -10.2, 3.4), (-0.9, -9.7, 4.9), (0.9, -9.7, 4.9),
                (-2.7, -6.6, 4.6), (2.7, -6.6, 4.6), (-2.0, -6.8, 5.9), (2.0, -6.8, 5.9)], bevel=0.25, seg=2)
    for s in (-1, 1):
        F.tube(nv, (s * 0.9, -9.7, 4.95), (s * 2.0, -6.8, 5.95), 0.14, verts=6, bevel=0)
        F.tube(nv, (s * 1.4, -10.2, 3.4), (s * 2.7, -6.6, 4.6), 0.14, verts=6, bevel=0)
    F.tube(nv, (0, -9.8, 4.9), (0, -6.8, 5.95), 0.12, verts=6, bevel=0)
    F.box(nv, (5.6, 0.4, 0.4), (0, -6.5, 5.0), bevel=0.08, seg=1)
    # stub wings with engine nacelles
    for s in (-1, 1):
        F.hull(wh, [(s * 2.8, -2.5, 3.4), (s * 2.8, 3.5, 3.4), (s * 2.8, -2.5, 2.5), (s * 2.8, 3.5, 2.5),
                    (s * 5.6, -0.5, 3.3), (s * 5.6, 3.2, 3.3), (s * 5.6, -0.5, 2.8), (s * 5.6, 3.2, 2.8)], bevel=0.12, seg=2)
        F.hull(og, [(s * 5.0, -0.45, 3.3), (s * 5.0, 3.0, 3.3), (s * 5.0, -0.45, 2.8), (s * 5.0, 3.0, 2.8),
                    (s * 5.62, -0.5, 3.32), (s * 5.62, 3.22, 3.32), (s * 5.62, -0.5, 2.78), (s * 5.62, 3.22, 2.78)], bevel=0.03, seg=1)
        Y(wh, 1.0, -1.8, 5.2, x=s * 4.4, z=2.2, verts=18, bevel=0.2, seg=2)                       # nacelle
        Y(og, 1.04, -1.6, -1.2, x=s * 4.4, z=2.2, verts=18)
        Y(nv, 1.06, -0.2, 0.2, x=s * 4.4, z=2.2, verts=18)
        Y(mt, 0.96, 5.0, 5.7, x=s * 4.4, z=2.2, verts=18, r2=0.8)                                  # nozzle
        ndk.cyl(0.82, 0.1, (s * 4.4, -1.85, 2.2), rot=(90, 0, 0), verts=14, bevel=0.0)             # intake
        # tail fins
        F.hull(wh, [(s * 1.9, 6.5, 5.0), (s * 1.9, 10.6, 5.0), (s * 2.1, 6.5, 6.0), (s * 2.1, 10.6, 5.0),
                    (s * 1.6, 7.4, 6.9), (s * 1.6, 9.8, 6.9), (s * 1.9, 7.4, 6.9), (s * 1.9, 9.8, 6.9)], bevel=0.08, seg=1) if False else None
        fin = Frame(loc=(s * 2.1, 8.4, 4.8), rot=(0, s * 12, 0))
        fin.hull(wh, [(-.2, -2.0, 0), (.2, -2.0, 0), (-.2, 2.2, 0), (.2, 2.2, 0), (-.12, 0.8, 2.6), (.12, 0.8, 2.6), (-.12, 2.0, 2.6), (.12, 2.0, 2.6)], bevel=0.06, seg=1)
        fin.box(og, (0.34, 1.3, 0.5), (0, 1.4, 2.4), bevel=0.06, seg=1)
        # landing legs with skid shoes
        for yy in (-5.5, 3.0):
            nv.tube((s * 2.4, yy, 1.4), (s * 2.7, yy + 0.4, 0.3), 0.25, verts=10, bevel=0)
            mt.cyl(0.35, 0.25, (s * 2.7, yy + 0.4, 0.15), verts=12, bevel=0.05)
            og.cyl(0.28, 0.12, (s * 2.55, yy + 0.2, 0.9), verts=10, bevel=0.02)
        mt.box((0.6, 9.0, 0.3), (s * 2.7, -0.9, 0.15), bevel=0.1, seg=1)
    # bay interior
    F.box(ndk, (3.3, 3.2, 0.15), (0, 10.0, 1.52), bevel=0.0)
    F.box(ndk, (3.0, 0.1, 2.3), (0, 8.7, 2.75), bevel=0.0)
    F.box(og, (0.4, 0.5, 0.5), (-1.0, 9.0, 1.9), bevel=0.08, seg=1)
    F.box(nv, (0.4, 0.5, 0.5), (0.9, 9.0, 1.9), bevel=0.08, seg=1)
    og.box((3.5, 0.2, 0.2), (0, 10.95, 3.95), bevel=0.03, seg=1)
    stl.tube((0.9, -6.0, 5.9), (1.3, -6.5, 7.0), 0.04, verts=6, bevel=0) if False else None
    # open rear ramp
    HP = (0, 10.8, 1.55)
    a.limb("Ramp", "ramp", "Body", pivot=HP)
    rf = Frame(loc=HP, rot=(-21, 0, 0))
    rf.box(wh, (3.0, 4.2, 0.22), (0, 2.1, -0.1), bevel=0.06, seg=1)
    for s in (-1, 1):
        rf.box(og, (0.2, 4.2, 0.32), (s * 1.55, 2.1, 0.05), bevel=0.04, seg=1)
    for k in range(6):
        rf.box(nv, (2.6, 0.12, 0.06), (0, 0.5 + k * 0.62, 0.05), bevel=0.0, seg=1)
    rf.box(mt, (3.1, 0.3, 0.3), (0, 4.15, -0.15), bevel=0.05, seg=1)
    # engine glows
    for s, n in ((1, "L"), (-1, "R")):
        g = a.glow("Engine_" + n, CYAN, "glow", "Body", pivot=(s * 4.4, 5.8, 2.2))
        g.cyl(0.72, 0.35, (s * 4.4, 5.9, 2.2), rot=(90, 0, 0), r2=0.5, verts=16, bevel=0.04)
    a.pose_closed = dict(angles={"Ramp": (111, 0, 0)})
    return a, dict(target=(0, 0, 2.8), dist=46, height=14, yaw=-140, floor=(34, 40))


# ================================================================================ 8. fabricator (cog palette)
@piece
def fabricator():
    a = H.Asset("fabricator", kind="enemy_building", faction="cog")
    metal = a.colour("metal", GUNMETAL, "Metal")
    plates = a.colour("plates", RUST)
    dark = a.colour("dark", DARK)
    trim = a.colour("trim", YELLOW)
    a.limb("Body", "body", None, pivot=(0, 0, 0))
    dark.box((16.4, 12.4, 0.6), (0, 0, 0.3), bevel=0.2, seg=2)                                    # foundation
    metal.box((15.0, 11.0, 6.0), (0, 0.2, 3.6), bevel=0.45, seg=3)                                # main hall
    plates.box((15.2, 0.3, 1.0), (0, -5.32, 1.3), bevel=0.1, seg=1)                                 # kick plates
    for s in (-1, 1):
        plates.box((0.3, 10.0, 1.0), (s * 7.55, 0.2, 1.3), bevel=0.1, seg=1)
    # sawtooth roof
    for k in range(3):
        y0 = -3.6 + k * 3.6
        metal.hull([(-7.4, y0 - 1.6, 6.5), (7.4, y0 - 1.6, 6.5), (-7.4, y0 + 1.6, 6.5), (7.4, y0 + 1.6, 6.5),
                    (-7.4, y0 + 1.6, 8.0), (7.4, y0 + 1.6, 8.0)], bevel=0.12, seg=2)
        plates.box((14.8, 0.2, 1.1), (0, y0 - 1.58, 7.25), bevel=0.03, seg=1) if False else None
        trim.box((14.9, 0.3, 0.2), (0, y0 + 1.5, 8.0), bevel=0.04, seg=1)
        dark.box((14.0, 0.15, 0.5), (0, y0 - 1.65, 6.95), bevel=0.02, seg=1)
    # big gate with hazard frame
    dark.box((5.8, 0.5, 4.2), (0, -5.55, 2.9), bevel=0.15, seg=2)
    dark.cyl(2.9, 0.5, (0, -5.55, 5.0), rot=(90, 0, 0), verts=22, bevel=0.1, seg=1)
    for k in range(9):
        (trim if k % 2 == 0 else dark).box((0.6, 0.35, 0.3), (-3.1 + k * 0.8, -5.82, 0.85), bevel=0.0, seg=1) if False else None
    for s in (-1, 1):
        for k in range(5):
            (trim if k % 2 == 0 else dark).box((0.35, 0.3, 0.8), (s * 3.15, -5.8, 1.0 + k * 0.85), bevel=0.02, seg=1)
    for k in range(7):
        t = math.radians(-90 + 180 * (k + 0.5) / 7)
        (trim if k % 2 == 0 else dark).box((0.6, 0.3, 0.5), (math.sin(t) * 3.1, -5.8, 5.0 + math.cos(t) * 3.1), rot=(0, math.degrees(t), 0), bevel=0.02, seg=1)
    plates.box((5.0, 0.2, 3.6), (0, -5.82, 2.7), bevel=0.05, seg=1) if False else None
    for k in range(6):                                                                              # door slats
        metal.box((5.2, 0.2, 0.18), (0, -5.82, 1.2 + k * 0.5), bevel=0.0, seg=1)
    # gear emblem on the facade
    plates.gear(1.7, 1.35, 12, 0.35, (0, -5.5, 8.0 - 0.9), rot=(90, 0, 0), bevel=0.05) if False else None
    for s in (-1, 1):
        plates.gear(1.5, 1.2, 12, 0.35, (s * 5.2, -5.55, 5.2), rot=(90, 0, 0), bevel=0.05)
        dark.cyl(0.4, 0.45, (s * 5.2, -5.55, 5.2), rot=(90, 0, 0), verts=10, bevel=0.04)
    plates.box((3.0, 0.3, 0.7), (0, -5.5, 6.4), bevel=0.08, seg=1)
    for k in range(5):
        trim.box((0.3, 0.32, 0.5), (-1.0 + k * 0.5, -5.5, 6.4), rot=(0, 0, 0), bevel=0.0, seg=1) if k % 2 == 0 else None
    # rivets on the facade
    plates.rivets([(-6.4 + k * 1.6, -5.5, 4.2) for k in range(9) if abs(-6.4 + k * 1.6) > 3.5], r=0.12, normal=(0, -1, 0))
    # chimneys
    for (x, y) in [(-5.2, 2.8), (-2.8, 3.2)]:
        dark.cyl(1.0, 3.4, (x, y, 8.3), r2=0.85, verts=16, bevel=0.1, seg=2)
        trim.cyl(1.02, 0.25, (x, y, 7.5), verts=16, bevel=0.03)
        plates.cyl(1.15, 0.3, (x, y, 10.0), verts=16, bevel=0.06)
    # side pipes + brackets
    for s in (-1, 1):
        dark.tube((s * 7.7, -4.4, 3.2), (s * 7.7, 4.8, 3.2), 0.4, verts=12, bevel=0)
        dark.tube((s * 7.7, -4.4, 4.4), (s * 7.7, 4.8, 4.4), 0.28, verts=10, bevel=0)
        for yy in (-3.0, 0.0, 3.0):
            trim.box((0.3, 0.3, 1.8), (s * 7.6, yy, 3.8), bevel=0.04, seg=1)
    # conveyor belt out front with a half-built bot
    dark.box((4.0, 6.0, 0.7), (0, -8.6, 0.95), bevel=0.15, seg=2)
    for k in range(8):
        metal.cyl(0.25, 3.6, (0, -6.0 - k * 0.75, 1.35), rot=(0, 90, 0), verts=10, bevel=0.03)
    for s in (-1, 1):
        trim.box((0.25, 6.0, 0.3), (s * 2.0, -8.6, 1.4), bevel=0.04, seg=1)
    metal.box((1.6, 1.3, 1.2), (0, -9.0, 2.2), bevel=0.25, seg=2)                                   # half-built robot torso
    plates.box((1.7, 0.4, 0.8), (0, -9.5, 2.3), bevel=0.1, seg=1)
    dark.ball(0.55, (0, -9.0, 3.4), segs=10)
    # the weak Vent: glowing grille on a roof collar
    VP = (4.4, -2.2, 8.15)
    dark.box((3.0, 3.0, 0.7), (VP[0], VP[1], 7.8), bevel=0.15, seg=2)
    trim.box((3.2, 0.2, 0.2), (VP[0], VP[1] - 1.55, 8.05), bevel=0.02, seg=1)
    trim.box((3.2, 0.2, 0.2), (VP[0], VP[1] + 1.55, 8.05), bevel=0.02, seg=1)
    for k in range(5):
        dark.box((2.2, 0.12, 0.2), (VP[0], VP[1] - 0.8 + k * 0.4, 8.5), bevel=0.0, seg=1)           # grille bars over the glow
    v = a.glow("Vent", AMBER, "weak", "Body", pivot=VP)
    v.box((2.2, 2.2, 0.35), VP, bevel=0.08, seg=1)
    return a, dict(target=(0, -2.0, 4.2), dist=44, height=18, yaw=-32, floor=(26, 30))


# ================================================================================ 9. sample_pod
@piece
def sample_pod():
    a = H.Asset("sample_pod")
    wh, nv, og, mt, ndk, stl, nlt, wsh = a.white, a.navy, a.orange, a.metal, a.navy_dk, a.steel, a.navy_lt, a.white_sh
    a.limb("Casing", "body", None, pivot=(0, 0, 0))
    nv.cyl(0.55, 0.22, (0, 0, 0.11), verts=16, bevel=0.05, seg=2)                                    # base
    og.cyl(0.46, 0.12, (0, 0, 0.27), verts=16, bevel=0.02)
    wh.cyl(0.4, 0.2, (0, 0, 0.45), verts=14, bevel=0.04)
    for k in range(4):                                                                                  # cage ribs
        t = math.radians(k * 90 + 45)
        stl.tube((math.cos(t) * 0.38, math.sin(t) * 0.38, 0.5), (math.cos(t) * 0.38, math.sin(t) * 0.38, 1.15), 0.06, verts=8, bevel=0)
    for z in (0.62, 1.03):
        ring(nv, (0, 0, z), 0.4, 0.05, n=14, verts=6)
    nv.cyl(0.46, 0.18, (0, 0, 1.3), verts=16, bevel=0.04, seg=1)
    og.cyl(0.34, 0.14, (0, 0, 1.46), verts=14, bevel=0.02)
    wh.cyl(0.2, 0.12, (0, 0, 1.58), verts=12, bevel=0.03)
    ring(og, (0, 0, 1.7), 0.2, 0.04, n=12, axis="y", verts=6)                                          # carry handle
    for s in (-1, 1):
        ndk.box((0.1, 0.1, 0.18), (s * 0.4, 0, 1.38), bevel=0.0, seg=1) if False else None
    g = a.glow("Glow", ALIEN, "glow", "Casing", pivot=(0, 0, 0.82))
    g.ball(0.33, (0, 0, 0.82), scale=(1, 1, 1.35), segs=14)
    return a, dict(target=(0, 0, 0.85), dist=5.0, height=1.6, yaw=-30, floor=3, boost=0.6)


_orig_box, _orig_cyl = kit._box, kit._cyl
LOW = {"fabricator", "skiff", "missile_silo", "extraction_pad"}


def run_one(name):
    kit.reset()
    if name in LOW:      # drop the tiny bevels on small parts to save triangles
        kit._box = lambda size, bevel, seg, taper: _orig_box(size, 0 if bevel < 0.07 else bevel, seg, taper)
        kit._cyl = lambda r, h, r2, verts, bevel, seg, cap_bevel_only=True: _orig_cyl(r, h, r2, verts, 0 if bevel < 0.07 else bevel, seg)
    else:
        kit._box, kit._cyl = _orig_box, _orig_cyl
    a, st = PIECES[name]()
    a.build()
    a.over()
    st = dict(st)
    pose = st.pop("pose", False)
    st.setdefault("size", (1000, 800))
    st.setdefault("lens", 50)
    boost = st.pop("boost", 1.2)
    kit.stage(boost=boost, **st)
    if pose:
        a.pose(**a.pose_open)
    elif hasattr(a, "pose_closed") and False:
        a.pose(**a.pose_closed)
    kit.render("set_" + name)
    if pose or hasattr(a, "pose_closed"):
        a.unpose()
    if "NOEXPORT" not in os.environ:
        ex = getattr(a, "extras", {})
        a.write_manifest(name, **ex)
        a.export()


def main():
    only = os.environ.get("ONLY")
    for n in ([only] if only else list(PIECES)):
        run_one(n)


main()
