"""SET A1: courier_wreck - crashed Halcyon courier dropship (nose-down, rolled, broken in two, wing snapped, hatch open)."""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
import halcyon as H
from halcyon import Frame


def petals(Fr, px, px2, y0, d, rim, specs):
    """Torn skin petals around a break at y0, growing in direction d (+1/-1)."""
    cz, rx, rz = rim
    for k, (ang, w, ln, bend) in enumerate(specs):
        cx_, cz_ = math.cos(ang) * rx * 0.93, cz + math.sin(ang) * rz * 0.93
        ox_, oz_ = math.cos(ang), math.sin(ang)
        tg = (-oz_, ox_)
        tx, tz = cx_ + ox_ * bend, cz_ + oz_ * bend
        pts = [(cx_ + tg[0] * w, y0, cz_ + tg[1] * w), (cx_ - tg[0] * w, y0, cz_ - tg[1] * w),
               (tx + tg[0] * w * .3, y0 + d * ln, tz + tg[1] * w * .3), (tx - tg[0] * w * .7, y0 + d * ln * .6, tz - tg[1] * w * .7)]
        pts2 = [(p[0] + ox_ * 0.14, p[1], p[2] + oz_ * 0.14) for p in pts]
        Fr.hull(px if k % 2 == 0 else px2, pts + pts2, bevel=0.025, seg=1)


def build(ox=0.0, oy=0.0):
    a = H.Asset("courier_wreck")
    wh, nv, og, mt = a.white, a.navy, a.orange, a.metal
    wsh, ndk, soot, scr, stl, gl, nlt = a.white_sh, a.navy_dk, a.soot, a.scorch, a.steel, a.glass, a.navy_lt

    # wreck attitude: nose digging in, rolled onto the hatch side (+X), tail swung and lifted
    F = Frame(loc=(0, 1.0, 0.5), rot=(6.0, 6.5, -3))
    Rr = F.about((0, 3.35, 2.65), rot=(5, -5, 11), loc=(0.35, 0.45, 0.55))     # broken-off tail section

    SEC = [(-8.6, .45, .45, 2.0, 2.4), (-8.0, 1.1, .95, 2.1, 2.8), (-7.0, 1.7, 1.4, 2.3, 3.1),
           (-5.6, 2.1, 1.7, 2.5, 3.9), (-3.5, 2.3, 1.85, 2.6, 4.3), (0.0, 2.35, 1.9, 2.65, 4.6), (3.0, 2.32, 1.87, 2.65, 4.6)]
    pad = lambda s, k: (s[0], s[1] * k, s[2] * k, s[3], s[4])
    TAIL = [(3.7, 2.3, 1.85, 2.65, 4.6), (5.0, 2.2, 1.78, 2.63, 4.3), (7.0, 1.9, 1.55, 2.6, 3.8)]

    # ================= Hull =================
    a.limb("Hull", "body", None, pivot=(0, 0, 0))
    F.loft(wh, SEC[3:], n=18)
    F.cutbox(wh, (1.5, 2.3, 2.6), (-2.3, -4.5, 2.35))                                   # hatch pocket
    Rr.loft(wh, TAIL, n=18)
    F.loft(soot, [pad(s, 1.004) for s in SEC[:4]], n=18)                                 # burnt nose
    F.loft(soot, [(2.2, 2.34, 1.9, 2.65, 4.6), (3.0, 2.325, 1.875, 2.65, 4.6)], n=18)   # scorched break edge
    F.loft(nv, [(-7.0, 1.4, .65, 1.5, 3.0), (-5.0, 2.0, .8, 1.75, 3.2), (-2.0, 2.3, .9, 1.78, 3.2), (3.0, 2.3, .9, 1.78, 3.2)], n=14)
    Rr.loft(nv, [(3.7, 2.3, .9, 1.78, 3.2), (5.8, 2.0, .8, 1.8, 3.2)], n=14)
    # break: dark bulkhead plugs inside a white rim, exposed ribs, torn petals, cables across the gap
    F.loft(ndk, [(3.0, 1.95, 1.55, 2.65, 3.6), (3.07, 1.95, 1.55, 2.65, 3.6)], n=18)
    Rr.loft(ndk, [(3.63, 1.95, 1.55, 2.65, 3.6), (3.7, 1.95, 1.55, 2.65, 3.6)], n=18)
    petals(F, wh, wsh, 3.0, 1, (2.65, 2.32, 1.87), [(0.5, .55, .9, .15), (2.2, .6, .6, .2), (3.6, .5, 1.1, .1), (5.4, .6, .7, .2)])
    petals(Rr, wh, wsh, 3.7, -1, (2.65, 2.3, 1.85), [(1.2, .6, .8, .2), (2.9, .5, 1.0, .1), (4.4, .6, .6, .2), (6.0, .5, .9, .1)])
    for Fr, y0, d in ((F, 3.07, 1), (Rr, 3.63, -1)):
        for k in range(6):
            t1 = 2 * math.pi * k / 6 + 0.2
            t2 = t1 + 2 * math.pi / 6 * 0.8
            if k % 2:
                continue
            L1 = 0.25 + (k % 3) * 0.12
            p1 = (math.cos(t1) * 1.8, y0, 2.65 + math.sin(t1) * 1.45)
            p2 = (math.cos(t1) * 1.8, y0 + d * L1, 2.65 + math.sin(t1) * 1.45)
            p3 = (math.cos(t2) * 1.8, y0 + d * L1, 2.65 + math.sin(t2) * 1.45)
            Fr.tube(stl if k % 2 else mt, p1, p2, 0.06, verts=6, bevel=0)
            Fr.tube(stl if k % 2 else mt, p2, p3, 0.06, verts=6, bevel=0)
    for (p, q, c) in [((0.4, 3.07, 3.5), (0.2, 3.63, 3.4), og), ((-0.6, 3.07, 2.4), (-0.7, 3.63, 2.3), mt), ((0.9, 3.07, 1.9), (1.0, 3.63, 2.0), mt),
                      ((-1.2, 3.07, 3.2), (-1.0, 3.63, 3.0), nv)]:
        c.tube(F.P(p), Rr.P(q), 0.08, verts=6, bevel=0)
    F.ball(ndk, 0.5, (-0.2, 3.3, 2.0), scale=(1.5, 0.4, 1.2), segs=8)

    # cockpit canopy: glass wedge in a navy frame
    F.hull(gl, [(-.85, -7.8, 3.0), (.85, -7.8, 3.0), (-.55, -7.3, 3.95), (.55, -7.3, 3.95),
                (-1.7, -4.8, 3.9), (1.7, -4.8, 3.9), (-1.25, -4.9, 5.0), (1.25, -4.9, 5.0)], bevel=0.12, seg=2)
    for s_ in (-1, 1):
        F.tube(nv, (s_ * .56, -7.28, 3.98), (s_ * 1.26, -4.9, 5.02), 0.1, verts=6, bevel=0)
        F.tube(nv, (s_ * .86, -7.8, 3.0), (s_ * 1.72, -4.8, 3.9), 0.1, verts=6, bevel=0)
    F.tube(nv, (0, -7.4, 3.95), (0, -4.9, 5.05), 0.09, verts=6, bevel=0)
    F.box(nv, (3.6, 0.3, 0.3), (0, -4.7, 4.3), bevel=0.06, seg=1)
    F.box(wsh, (0.9, 1.0, 0.1), (0.9, -6.2, 4.15), rot=(-20, 0, 15), bevel=0.03, seg=1)            # glass shard

    # side windows (+X side) + stripes
    for yy in (-5.2, 0.0, 1.7):
        F.box(nv, (0.2, 1.3, 1.0), (2.3, yy, 3.4), bevel=0.06, seg=1)
        F.box(gl, (0.24, 1.0, 0.7), (2.3, yy, 3.4), bevel=0.06, seg=1)
    F.box(og, (0.14, 5.0, 0.4), (-2.37, 0.6, 2.6), bevel=0.04, seg=1)
    F.box(og, (0.14, 3.0, 0.4), (2.37, -3.0, 2.6), bevel=0.04, seg=1)
    Rr.box(og, (0.14, 2.6, 0.4), (-2.3, 5.4, 2.6), bevel=0.04, seg=1)
    F.box(og, (2.6, 0.25, 0.14), (0, -7.55, 2.3), bevel=0.04, seg=1, rot=(-12, 0, 0))               # nose band
    # dorsal spine, roof hatch, panel lines
    F.loft(nv, [(-3.4, 1.0, .5, 4.1, 3.0), (-2.6, 1.5, .6, 4.0, 4), (1.8, 1.5, .6, 4.0, 4), (2.6, 1.1, .5, 4.1, 3.0)], n=14)   # roof armour
    F.box(nv, (0.55, 5.2, 0.3), (0, -0.6, 4.66), bevel=0.1, seg=1, taper=(0.8, 1))
    F.box(og, (1.5, 1.3, 0.12), (0, 0.4, 4.58), bevel=0.04, seg=1)
    for yy in (-2.2, 2.0):
        F.box(nlt, (3.0, 0.07, 0.05), (0, yy, 4.62), bevel=0.0, seg=1)
    # soot streaks on the flanks / behind the break
    F.hull(soot, [(-2.37, 1.2, 3.0), (-2.37, 3.0, 3.7), (-2.37, 3.0, 2.8), (-2.31, 1.6, 3.9), (-2.31, 2.6, 3.9), (-2.31, 1.0, 2.5)], bevel=0.0, seg=1)
    Rr.hull(soot, [(-2.33, 4.0, 2.2), (-2.33, 5.6, 3.9), (-2.33, 5.9, 2.4), (-2.28, 4.4, 3.7), (-2.28, 5.2, 4.2)], bevel=0.0, seg=1)
    Rr.hull(soot, [(0.6, 4.4, 4.45), (1.9, 6.0, 4.35), (1.4, 4.8, 4.5), (2.0, 5.2, 3.9)], bevel=0.0, seg=1)

    # hatch: recessed cell with a dark back wall and bench inside; door lowered as a ramp
    F.box(ndk, (0.1, 2.2, 2.5), (-1.61, -4.5, 2.35), bevel=0.0)
    F.box(nv, (0.5, 1.9, 0.5), (-1.92, -4.5, 1.45), bevel=0.08, seg=1)
    F.box(og, (0.4, 0.9, 0.9), (-1.92, -4.1, 2.0), bevel=0.1, seg=1)
    F.box(nv, (0.14, 2.5, 0.16), (-2.44, -4.5, 3.7), bevel=0.03, seg=1)
    F.box(nv, (0.14, 2.5, 0.16), (-2.4, -4.5, 1.0), bevel=0.03, seg=1)
    hinge = F.sub((-2.5, -4.5, 1.02), (0, -125, 0))
    hinge.box(wh, (0.16, 2.35, 2.75), (0, 0, 1.4), bevel=0.05, seg=1)
    hinge.box(nv, (0.2, 1.7, 1.2), (0, 0, 1.6), bevel=0.05, seg=1)
    hinge.box(og, (0.22, 2.35, 0.3), (0, 0, 2.7), bevel=0.05, seg=1)
    hinge.box(gl, (0.22, 1.2, 0.7), (0, 0, 1.6), bevel=0.05, seg=1)
    for zz in (0.4, 0.9, 1.4):
        hinge.box(mt, (0.24, 2.2, 0.08), (0, 0, zz), bevel=0.0, seg=1)

    # tail fins (one intact, one snapped) and engines, on the broken tail section
    base = Rr.sub((1.3, 5.3, 4.1), (0, 14, 0))
    base.hull(wh, [(-.16, -.7, 0), (.16, -.7, 0), (-.16, 1.7, 0), (.16, 1.7, 0), (-.1, 0.9, 1.5), (.1, 0.9, 1.5), (-.1, 1.5, 1.5), (.1, 1.5, 1.5)], bevel=0.05, seg=1)
    base.box(og, (0.34, 0.8, 0.38), (0, 1.1, 1.38), bevel=0.05, seg=1)
    base = Rr.sub((-1.3, 5.3, 4.1), (0, -14, 0))
    base.hull(wh, [(-.16, -.7, 0), (.16, -.7, 0), (-.16, 1.7, 0), (.16, 1.7, 0), (-.1, 0.1, 0.55), (.1, 0.1, 0.55), (-.1, 0.9, 0.95), (.1, 0.9, 0.95)], bevel=0.03, seg=1)
    base.tube(stl, (0, 0.5, 0.5), (0.1, 0.4, 1.5), 0.05, verts=6, bevel=0)
    Rr.cyl(mt, 0.78, 1.5, (1.0, 7.6, 1.45), rot=(90, 0, 0), r2=0.64, verts=16, bevel=0.1, seg=1)
    Rr.cyl(scr, 0.62, 0.2, (1.0, 8.4, 1.45), rot=(90, 0, 0), verts=16, bevel=0.03, seg=1)
    Rr.cyl(nv, 0.9, 0.35, (1.0, 6.9, 1.45), rot=(90, 0, 0), verts=16, bevel=0.1, seg=1)
    Rr.cyl(mt, 0.78, 1.5, (-1.2, 8.6, 0.25), rot=(78, 22, 0), r2=0.64, verts=16, bevel=0.1, seg=1)   # torn-off engine lying behind
    Rr.cyl(scr, 0.62, 0.2, (-1.3, 9.3, 0.2), rot=(78, 22, 0), verts=16, bevel=0.03, seg=1)
    Rr.tube(mt, (-1.0, 7.0, 1.9), (-1.1, 7.8, 0.6), 0.09, verts=6, bevel=0)
    Rr.tube(stl, (-1.3, 7.0, 1.7), (-1.2, 7.7, 0.5), 0.06, verts=6, bevel=0)

    # ---- wings: intact on -X, stump on +X
    def wing(Fr, side, span, torn=False):
        x0, x1 = 2.0 * side, (2.0 + span) * side
        Fr.hull(wh, [(x0, -2.0, 3.15), (x0, 2.7, 3.15), (x0, -2.0, 2.15), (x0, 2.7, 2.15),
                     (x1, 0.2, 3.1), (x1, 2.5, 3.1), (x1, 0.2, 2.65), (x1, 2.5, 2.65)], bevel=0.1, seg=1)
        Fr.hull(nv, [(x0, -2.0, 2.15), (x0, 2.7, 2.15), (x1, 0.2, 2.65), (x1, 2.5, 2.65),
                     (x0, -2.0, 2.4), (x0, 2.7, 2.4), (x1, 0.2, 2.75), (x1, 2.5, 2.75)], bevel=0.03, seg=1)
        if not torn:
            Fr.hull(og, [(x1, 0.18, 3.12), (x1, 2.52, 3.12), (x1, 0.18, 2.62), (x1, 2.52, 2.62),
                         (x1 - 0.5 * side, 0.4, 3.12), (x1 - 0.5 * side, 2.4, 3.12), (x1 - 0.5 * side, 0.4, 2.62), (x1 - 0.5 * side, 2.4, 2.62)], bevel=0.05, seg=1)

    wing(F, -1, 2.25)
    F.cyl(mt, 0.62, 2.8, (-3.5, 0.9, 2.1), rot=(90, 0, 0), r2=0.5, verts=14, bevel=0.1, seg=1)
    F.cyl(nv, 0.7, 0.5, (-3.5, -0.2, 2.1), rot=(90, 0, 0), verts=14, bevel=0.1, seg=1)
    F.cyl(scr, 0.4, 0.2, (-3.5, 2.35, 2.1), rot=(90, 0, 0), verts=12, bevel=0.03, seg=1)
    F.box(og, (0.5, 1.0, 0.1), (-3.0, 0.8, 3.22), bevel=0.03, seg=1)
    wing(F, 1, 0.95, torn=True)
    F.hull(wsh, [(3.0, -1.2, 3.1), (3.0, -0.2, 2.2), (3.5, -0.9, 3.0), (3.5, 0.2, 2.5), (3.2, 0.7, 3.1)], bevel=0.02, seg=1)
    F.hull(wsh, [(3.0, 1.5, 3.1), (3.0, 2.5, 2.2), (3.7, 2.2, 3.05), (3.4, 1.4, 2.4)], bevel=0.02, seg=1)
    for yy in (-0.4, 2.2):
        F.tube(stl, (2.8, yy, 2.65), (4.0 + (yy % 0.5), yy + 0.1, 2.75 - (yy % 0.4)), 0.09, verts=6, bevel=0)
    F.tube(mt, (3.0, 0.6, 2.7), (3.9, 1.0, 1.6), 0.07, verts=6, bevel=0)
    # landing strut + antenna
    F.tube(mt, (1.9, -1.0, 1.7), (2.6, -1.4, 0.3), 0.16, verts=8, bevel=0)
    F.cyl(nv, 0.4, 0.3, (2.6, -1.4, 0.25), verts=10, bevel=0.05, seg=1)
    F.tube(stl, (-0.6, -2.3, 4.4), (-0.9, -2.8, 5.6), 0.05, verts=6, bevel=0)
    F.tube(stl, (-0.9, -2.8, 5.6), (-1.6, -3.0, 5.4), 0.05, verts=6, bevel=0)

    # severed wing lying on the ground
    sev = Frame(loc=(-9.2, -2.4, 0.5), rot=(3, 8, -140))
    sev.hull(wh, [(0, -2.0, 0.5), (0, 2.7, 0.5), (0, -2.0, -0.5), (0, 2.7, -0.5),
                  (-2.2, 0.2, 0.45), (-2.2, 2.5, 0.45), (-2.2, 0.2, 0.0), (-2.2, 2.5, 0.0)], bevel=0.1, seg=1)
    sev.hull(nv, [(0.0, -2.0, -0.5), (0, 2.7, -0.5), (-2.2, 0.2, 0.0), (-2.2, 2.5, 0.0),
                  (0, -2.0, -0.2), (0, 2.7, -0.2), (-2.2, 0.2, 0.1), (-2.2, 2.5, 0.1)], bevel=0.03, seg=1)
    sev.hull(og, [(-2.2, 0.2, 0.47), (-2.2, 2.5, 0.47), (-2.2, 0.2, -0.02), (-2.2, 2.5, -0.02),
                  (-1.7, 0.4, 0.47), (-1.7, 2.4, 0.47), (-1.7, 0.4, -0.02), (-1.7, 2.4, -0.02)], bevel=0.05, seg=1)
    sev.hull(wsh, [(0.3, -1.4, 0.45), (0.3, -0.4, -0.3), (0.9, -1.1, 0.3), (0.7, 0.2, 0.0)], bevel=0.02, seg=1)
    sev.hull(wsh, [(0.3, 1.0, 0.45), (0.3, 2.4, -0.3), (1.0, 1.6, 0.3), (0.6, 2.9, 0.0)], bevel=0.02, seg=1)
    for yy in (-0.6, 0.8, 2.0):
        sev.tube(stl, (0.2, yy, 0.1), (1.0 + (yy % 0.4), yy + .1, 0.15), 0.08, verts=6, bevel=0)

    # ================= DataCase (interact) =================
    CP = (-6.9, -5.6, 0.0)
    a.limb("DataCase", "interact", "Hull", pivot=CP)
    cf = Frame(loc=CP, rot=(0, 0, 28))
    cf.box(nv, (1.5, 0.9, 1.0), (0, 0, 0.5), bevel=0.14, seg=2)
    cf.box(og, (1.56, 0.12, 1.06), (0, 0, 0.5), bevel=0.04, seg=1)
    for sx in (-1, 1):
        cf.box(og, (0.34, 0.98, 0.34), (sx * 0.66, 0, 0.17), bevel=0.06, seg=1)
        cf.box(og, (0.34, 0.98, 0.34), (sx * 0.66, 0, 0.84), bevel=0.06, seg=1)
        cf.box(stl, (0.34, 0.1, 0.22), (sx * 0.36, -0.5, 0.5), bevel=0.03, seg=1)
    cf.box(mt, (0.8, 0.22, 0.2), (0, 0, 1.08), bevel=0.06, seg=1)
    cf.box(wh, (0.5, 0.06, 0.34), (0, -0.46, 0.7), bevel=0.02, seg=1)

    # ================= Ground (scorch + dirt) =================
    a.limb("Ground", "decor", "Hull", pivot=(0, 0, 0))
    ash, dirt = a.ash, a.dirt
    for (x, y, rx, ry) in [(0.0, 0.5, 4.8, 7.8), (1.0, 8.5, 3.2, 3.4), (-3.5, -3.5, 2.6, 2.6)]:
        pts = []
        for k in range(14):
            t = 2 * math.pi * k / 14
            j = 1.0 + 0.12 * math.sin(k * 2.3 + x)
            pts += [(x + rx * j * math.cos(t), y + ry * j * math.sin(t), 0.0), (x + rx * j * 0.97 * math.cos(t), y + ry * j * 0.97 * math.sin(t), 0.06)]
        ash.hull(pts, bevel=0.0, seg=1)
    for (x, y, z, sx, sy, sz) in [(0, -9.8, -0.2, 2.8, 1.6, 1.0), (-2.9, -8.9, -0.2, 1.4, 1.2, .7), (2.8, -9.0, -0.2, 1.4, 1.1, .65)]:
        dirt.ball(1.0, (x, y, z), scale=(sx, sy, sz * 0.8), segs=8)
    for (x, y, r) in [(5.5, -2.5, .35), (-6.5, 4.0, .3), (6.5, 6.5, .4)]:
        dirt.ball(r, (x, y, 0.0), scale=(1, 1, .6), segs=6)

    # ================= Debris =================
    a.limb("Debris", "decor", "Hull", pivot=(0, 0, 0))
    for (x, y, z, sz, rot, c) in [(-5.2, 3.0, 0.1, (1.4, 0.9, .12), (0, 4, 30), wh), (5.2, -4.2, 0.08, (1.1, 0.7, .1), (3, -3, -50), og),
                                  (3.3, 11.0, 0.08, (1.3, .8, .1), (3, 5, 70), nv), (-7.4, 3.8, 0.08, (0.9, .6, .1), (0, 0, -20), og)]:
        c.box(sz, (x, y, z), rot=rot, bevel=0.03, seg=1)
    for (x, y, z, l, ang) in [(4.0, 8.6, 0.1, 1.4, 30)]:
        ar = math.radians(ang)
        stl.tube((x, y, z), (x + math.cos(ar) * l, y + math.sin(ar) * l, z + 0.1), 0.09, verts=6, bevel=0)
    mt.cyl(0.42, 1.0, (-6.9, 6.8, 0.42), rot=(0, 90, 20), verts=8, bevel=0.0)

    a.build(ox, oy)
    return a


def main():
    kit.reset()
    a = build()
    a.over()
    kit.stage(target=(-0.5, 0.5, 2.0), dist=36, height=15, yaw=-33, lens=50, size=(1100, 820), floor=(40, 36), boost=1.05)
    kit.render("set_courier_wreck")
    if "NOEXPORT" not in os.environ:
        a.write_manifest("courier_wreck", notes="Origin at ground centre, nose toward -Y. Interactable: DataCase. Decor parts (Ground, Debris) can be dropped.")
        a.export()
    lo, hi = a.bounds()
    print("BOUNDS", lo, hi)


if __name__ == "__main__":
    main()
