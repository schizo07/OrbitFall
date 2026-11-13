import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math, random
from mathutils import Vector, Matrix
import kit
from kit import Part, GUNMETAL, GUNMETAL_LT, DARK, RUST, YELLOW, AMBER
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, LILAC, ACID, BONE
import envkit as E


# ------------------------------------------------------------------------------------------
def cog_barricade(ox=0.0, oy=0.0):
    body = Part("Body", GUNMETAL, "Metal", "body")
    plates = Part("Plates", RUST, "SmoothPlastic", "trim")
    dark = Part("Dark", DARK, "SmoothPlastic", "trim")
    trim = Part("Trim", YELLOW, "SmoothPlastic", "trim")
    SL = 18.0                                                                             # front slope (deg)
    nrm = Vector((0, -math.cos(math.radians(SL)), math.sin(math.radians(SL))))

    def on_slope(x, t, off=0.0):
        """point on the sloped front, t = 0 (bottom) .. 1 (top), offset along the surface normal."""
        y = -1.45 + 0.95 * t
        z = 0.45 + 2.75 * t
        return (x + 0.0, y + nrm.y * off, z + nrm.z * off)

    dark.box((10.4, 3.4, 0.45), (0, 0.1, 0.225), bevel=0.18, seg=2)                       # footing
    body.hull([(-4.9, -1.45, 0.45), (4.9, -1.45, 0.45), (4.9, 1.4, 0.45), (-4.9, 1.4, 0.45),
               (-4.7, -0.5, 3.2), (4.7, -0.5, 3.2), (4.7, 1.0, 3.2), (-4.7, 1.0, 3.2)], bevel=0.22, seg=2)
    # sloped rust armour panels with gunmetal ribs between
    for x in (-3.15, 0.0, 3.15):
        c = on_slope(x, 0.5, 0.2)
        plates.box((2.55, 0.34, 2.75), c, rot=(-SL, 0, 0), bevel=0.12, seg=2)
        pts = [on_slope(x + dx, t, 0.4) for dx in (-1.0, 1.0) for t in (0.17, 0.83)]
        plates.rivets(pts, r=0.13, normal=tuple(nrm))
    for x in (-4.65, -1.57, 1.57, 4.65):
        body.box((0.7, 0.7, 2.95), on_slope(x, 0.5, 0.25), rot=(-SL, 0, 0), bevel=0.14, seg=2)
    c = on_slope(0.0, 0.52, 0.5)
    dark.gear(0.95, 0.78, 10, 0.22, c, rot=(90 - SL, 0, 0), bevel=0.04)
    trim.cyl(0.28, 0.3, on_slope(0.0, 0.52, 0.62), rot=(90 - SL, 0, 0), verts=12, bevel=0.03)
    for x in (-3.15, 3.15):                                                               # vision slits
        dark.box((1.7, 0.2, 0.34), on_slope(x, 0.62, 0.42), rot=(-SL, 0, 0), bevel=0.04, seg=1)
    # crown rail with big hazard stripes
    body.box((10.3, 1.9, 0.9), (0, 0.15, 3.55), bevel=0.2, seg=2)
    yf = -0.8 - 0.01
    for k in range(10):
        x0 = -4.8 + k * 1.0
        trim.hull([(x0, yf - 0.06, 3.15), (x0 + 0.5, yf - 0.06, 3.15), (x0 + 0.9, yf - 0.06, 3.95), (x0 + 0.4, yf - 0.06, 3.95),
                   (x0, yf + 0.02, 3.15), (x0 + 0.5, yf + 0.02, 3.15), (x0 + 0.9, yf + 0.02, 3.95), (x0 + 0.4, yf + 0.02, 3.95)],
                  bevel=0.0, seg=1)
    for k in range(7):                                                                    # rust spikes along the top
        x = -4.5 + k * 1.5
        plates.tube((x, 0.15, 3.95), (x, 0.1, 4.75), 0.3, 0.05, verts=8, bevel=0.0)
    # rear braces
    for x in (-3.2, 0.0, 3.2):
        dark.tube((x, 1.0, 3.2), (x, 2.5, 0.5), 0.22, verts=10)
        dark.box((0.8, 1.0, 0.35), (x, 2.6, 0.65), bevel=0.08, seg=1)
    return [body, plates, dark, trim]


def cog_pylon(ox=0.0, oy=0.0):
    body = Part("Body", GUNMETAL, "Metal", "body")
    plates = Part("Plates", RUST, "SmoothPlastic", "trim")
    dark = Part("Dark", DARK, "SmoothPlastic", "trim")
    trim = Part("Trim", YELLOW, "SmoothPlastic", "trim")
    beacon = Part("Beacon", AMBER, "Neon", "glow")

    # plinth + cog emblem
    dark.cyl(3.3, 0.7, (0, 0, 0.35), verts=8, bevel=0.18)
    body.cyl(2.6, 0.6, (0, 0, 1.0), r2=1.7, verts=8, bevel=0.12)
    plates.gear(1.5, 1.25, 10, 0.2, (0, -2.0, 1.05), rot=(90 - 12, 0, 0), bevel=0.03)
    dark.cyl(0.38, 0.3, (0, -2.1, 1.05), rot=(90 - 12, 0, 0), verts=10, bevel=0.02)
    # four splayed legs with cross braces
    for k in range(4):
        a = math.radians(45 + 90 * k)
        R0 = 2.5
        bx, by = math.cos(a) * R0, math.sin(a) * R0
        tx, ty = math.cos(a) * 0.7, math.sin(a) * 0.7
        body.tube((bx, by, 1.0), (tx, ty, 6.4), 0.4, 0.3, verts=10)
        dark.cyl(0.62, 0.3, (bx, by, 1.05), verts=10, bevel=0.05)
        a2 = math.radians(135 + 90 * k)
        for z0, z1 in ((1.8, 3.8), (3.8, 5.8)):
            f0, f1 = R0 - (z0 - 1.0) * 0.33, R0 - (z1 - 1.0) * 0.33
            dark.tube((math.cos(a) * f0, math.sin(a) * f0, z0), (math.cos(a2) * f1, math.sin(a2) * f1, z1), 0.1, verts=6, bevel=0.0)
    # mast
    body.cyl(0.95, 5.8, (0, 0, 3.7), r2=0.62, verts=14, bevel=0.07)
    body.cyl(0.62, 3.8, (0, 0, 8.9), r2=0.46, verts=14, bevel=0.06)
    for z in (2.4, 4.8, 7.0):
        plates.cyl(1.2 - z * 0.06, 0.45, (0, 0, z), verts=14, bevel=0.08)
    trim.cyl(0.84, 0.24, (0, 0, 3.6), verts=14, bevel=0.02)
    trim.cyl(0.66, 0.24, (0, 0, 6.0), verts=14, bevel=0.02)
    dark.cyl(0.95, 0.7, (0, 0, 7.8), verts=14, bevel=0.1)                                # collar

    def dish(z, yaw, pitch, r):
        m = Matrix.Rotation(math.radians(yaw), 4, "Z") @ Matrix.Rotation(math.radians(pitch), 4, "X")
        d = m.to_3x3() @ Vector((0, -1, 0))
        c = Vector((0, 0, z)) + d * (1.1 + r * 0.55)
        rm = Matrix.Rotation(math.radians(yaw), 3, "Z") @ Matrix.Rotation(math.radians(pitch + 90), 3, "X")
        plates.cyl(r, 0.35, tuple(c), rot=rm.to_4x4(), r2=r * 0.3, verts=16, bevel=0.04)
        plates.cyl(r * 0.99, 0.12, tuple(c - d * 0.17), rot=rm.to_4x4(), verts=16, bevel=0.0)
        body.tube(tuple(Vector((0, 0, z)) + d * 0.3), tuple(c - d * 0.1), 0.2, verts=8, bevel=0.0)
        tip = c + d * (r * 0.85)
        dark.tube(tuple(c), tuple(tip), 0.08, verts=6, bevel=0.0)
        trim.ball(0.24, tuple(tip), segs=8)
    dish(9.0, 0, -12, 2.1)
    dish(6.4, 125, 10, 1.6)
    # antenna spire with yellow bands and glowing tip
    dark.cyl(0.22, 4.0, (0, 0, 11.9), r2=0.13, verts=8, bevel=0.0)
    for z in (10.8, 11.9, 13.0):
        trim.cyl(0.3, 0.34, (0, 0, z), r2=0.24, verts=8, bevel=0.0)
    for k in range(3):                                                                    # cage fins around the beacon
        a = math.radians(120 * k + 20)
        dark.tube((math.cos(a) * 1.3, math.sin(a) * 1.3, 13.2), (0, 0, 14.9), 0.1, verts=6, bevel=0.0)
        dark.ball(0.14, (math.cos(a) * 1.3, math.sin(a) * 1.3, 13.2), segs=6)
    beacon.ball(0.92, (0, 0, 13.7), scale=(1, 1, 1.1), segs=16)
    beacon.ball(0.4, (0, 0, 14.9), segs=8)
    return [body, plates, dark, trim, beacon]


def hive_mound(ox=0.0, oy=0.0):
    body = Part("Body", CARAPACE, "SmoothPlastic", "body", rough=B.GLOSS)
    belly = Part("Belly", LILAC, "SmoothPlastic", "trim", rough=0.35)
    dark = Part("Dark", (22, 12, 34), "SmoothPlastic", "trim", rough=0.4)
    trim = Part("Trim", BONE, "SmoothPlastic", "trim", rough=0.3)
    slime = Part("Slime", ACID, "Neon", "glow")

    # stacked, wobbling terraces like a wasp-nest tower (built at final height)
    tiers = [(Vector((0.0, 0.2, 1.3)), Vector((4.8, 4.4, 2.1))),
             (Vector((0.3, 0.1, 2.9)), Vector((3.9, 3.6, 1.8))),
             (Vector((-0.2, 0.3, 4.1)), Vector((2.8, 2.6, 1.55)))]
    body.ball(1.0, (0, 0.2, 0.15), scale=(5.2, 4.8, 1.6), segs=22)                        # skirt
    for c, rr in tiers:
        body.ball(1.0, tuple(c), scale=tuple(rr), segs=20)
    body.ball(1.0, (-3.1, 1.8, 0.8), scale=(2.1, 2.0, 1.4), segs=14)                      # satellite lumps
    body.ball(1.0, (3.5, 1.4, 0.7), scale=(1.9, 1.8, 1.2), segs=14)
    # chimney crown with a glowing mouth
    body.cyl(1.5, 1.9, (-0.2, 0.3, 5.3), r2=1.1, verts=14, bevel=0.12)
    belly.cyl(1.35, 0.26, (-0.2, 0.3, 6.3), verts=14, bevel=0.05)
    slime.ball(0.95, (-0.2, 0.3, 6.3), scale=(1, 1, 0.45), segs=12)
    slime.tube((-0.2, 0.3, 6.3), (-0.2, 0.3, 7.4), 0.55, 0.12, verts=8, bevel=0.0)
    slime.ball(0.3, (-0.2, 0.3, 7.45), segs=8)
    for (c, rr) in tiers:                                                                 # lilac ledge bands
        belly.ball(1.0, (c.x, c.y, c.z + rr.z * 0.2), scale=(rr.x * 0.985, rr.y * 0.985, 0.14), segs=20)

    def surf(e, ang_deg, zf=0.25):
        c, rr = e
        a = math.radians(ang_deg)
        z_off = zf * rr.z
        k = math.sqrt(1 - zf * zf)
        x, y, z = c.x + math.cos(a) * rr.x * k, c.y + math.sin(a) * rr.y * k, c.z + z_off
        n = Vector(((x - c.x) / rr.x ** 2, (y - c.y) / rr.y ** 2, (z - c.z) / rr.z ** 2)).normalized()
        return Vector((x, y, z)), n
    holes = [(0, -110, 1.0), (0, -55, 0.85), (0, -165, 0.85), (0, -15, 0.7), (0, 175, 0.7),
             (1, -95, 0.85), (1, -40, 0.75), (1, -145, 0.75), (2, -100, 0.7), (2, -45, 0.6)]
    for t, ang, hr in holes:
        P, n = surf(tiers[t], ang)
        E.torus(belly, tuple(P + n * 0.02), tuple(n), hr * 0.95, hr * 0.3, segs=14, rsegs=6, squash=(0.82, 1.08))
        m = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
        dark.ball(hr * 0.95, tuple(P - n * 0.05 * hr), scale=(0.82, 1.08, 0.2), segs=14, rot=m)
    # cream thorns on the ledges (front kept clear for the holes)
    for e, cnt, L in ((tiers[1], 7, 1.1), (tiers[0], 8, 1.0), (tiers[2], 5, 0.9)):
        for k in range(cnt):
            ang = 360 * k / cnt + 20
            if -150 < ((ang + 180) % 360) - 180 < -30:
                continue
            P, n = surf(e, ang, 0.35)
            B.cone(trim, tuple(P - n * 0.1), tuple(P + (n + Vector((0, 0, 0.7))).normalized() * L), 0.3, verts=7)
    # slime pool flowing from the front hole
    P, n = surf(tiers[0], -110)
    slime.ball(1.0, (P.x, P.y - 1.5, 0.14), scale=(2.4, 1.5, 0.2), segs=16)
    slime.ball(1.0, (P.x - 1.7, P.y - 0.9, 0.12), scale=(1.5, 1.2, 0.16), segs=14)
    slime.ball(1.0, (P.x + 2.0, P.y - 1.1, 0.12), scale=(1.4, 1.1, 0.15), segs=14)
    slime.ball(1.0, (P.x + 3.2, P.y - 1.9, 0.1), scale=(0.8, 0.6, 0.12), segs=10)
    for t_ in (0.0, 0.33, 0.66):                                                         # slime dribbling down from the hole
        slime.ball(1.0, (P.x, P.y - 0.55 - t_ * 1.4, P.z * (1 - t_) + 0.25), scale=(0.5 + t_ * 0.3, 0.55, 0.4), segs=10)
    return [body, belly, dark, trim, slime]


def supply_crate(ox=0.0, oy=0.0):
    OLIVE = (96, 110, 70)
    body = Part("Body", OLIVE, "Metal", "body")
    frame = Part("Frame", (62, 72, 46), "Metal", "trim")
    stencil = Part("Stencil", (240, 205, 50), "SmoothPlastic", "trim")
    light = Part("Light", (90, 225, 255), "Neon", "glow")
    W, D, H = 3.5, 2.6, 2.6
    body.box((W, D, H), (0, 0, H / 2), bevel=0.14, seg=2)
    # lid, with overhang and seam
    frame.box((W + 0.18, D + 0.18, 0.4), (0, 0, H - 0.2), bevel=0.1, seg=2)
    frame.box((W + 0.16, D + 0.16, 0.3), (0, 0, 0.15), bevel=0.08, seg=2)                 # skid base
    # corner brackets
    for sx in (-1, 1):
        for sy in (-1, 1):
            frame.box((0.34, 0.34, H + 0.02), (sx * (W / 2 - 0.02), sy * (D / 2 - 0.02), H / 2), bevel=0.07, seg=1)
    # raised ribs on the front/back
    for sy in (-1, 1):
        for x in (-0.95, 0.95):
            frame.box((0.2, 0.1, H - 0.9), (x, sy * (D / 2 + 0.03), H / 2), bevel=0.03, seg=1)
    for sx in (-1, 1):                                                                    # side handles
        frame.tube((sx * (W / 2 + 0.02), -0.6, 1.4), (sx * (W / 2 + 0.34), -0.6, 1.4), 0.1, verts=8)
        frame.tube((sx * (W / 2 + 0.02), 0.6, 1.4), (sx * (W / 2 + 0.34), 0.6, 1.4), 0.1, verts=8)
        frame.tube((sx * (W / 2 + 0.34), -0.6, 1.4), (sx * (W / 2 + 0.34), 0.6, 1.4), 0.1, verts=8)
    # latches on the lid front
    for x in (-0.9, 0.9):
        frame.box((0.4, 0.14, 0.5), (x, -(D / 2 + 0.12), H - 0.55), bevel=0.04, seg=1)
    # yellow stencil: band along the lid edge, label bars + chevrons on the front
    y_f = -(D / 2 + 0.012)
    stencil.box((W - 0.5, 0.06, 0.22), (0, y_f - 0.04, H - 0.82), bevel=0.01, seg=1)
    for i, (w, x) in enumerate(((0.5, -1.1), (0.28, -0.6), (0.62, 0.0), (0.28, 0.58), (0.45, 1.05))):
        stencil.box((w, 0.05, 0.3), (x, y_f - 0.035, 0.85), bevel=0.01, seg=1)
    for k in range(4):
        stencil.box((0.22, 0.05, 0.62), (-1.05 + k * 0.32, y_f - 0.035, 1.5), rot=(0, 30, 0), bevel=0.01, seg=1)
    # top: hazard corner marks
    for sx in (-1, 1):
        stencil.box((0.9, 0.5, 0.05), (sx * 1.15, 0.0, H + 0.02), bevel=0.01, seg=1)
    # tiny glowing locator light on a stub
    frame.cyl(0.24, 0.3, (W / 2 - 0.3, D / 2 - 0.3, H + 0.15), verts=10, bevel=0.03)
    light.ball(0.22, (W / 2 - 0.3, D / 2 - 0.3, H + 0.38), segs=12)
    return [body, frame, stencil, light]


MODELS = {
    "cog_barricade": (cog_barricade, dict(target=(0, 0, 2.0), dist=19, height=5.5)),
    "cog_pylon": (cog_pylon, dict(target=(0, 0, 7.2), dist=29, height=8)),
    "hive_mound": (hive_mound, dict(target=(0, -0.5, 3.6), dist=24, height=6)),
    "supply_crate": (supply_crate, dict(target=(0, 0, 1.4), dist=11, height=3.2)),
}


def build_one(name, ox=0.0, oy=0.0):
    fn, _ = MODELS[name]
    parts = fn()
    E.finish(parts, smooth_angle=35.0, ox=ox, oy=oy)
    return parts


if __name__ == "__main__":
    only = (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []) or list(MODELS)
    for name in only:
        fn, cam = MODELS[name]
        kit.reset()
        parts = build_one(name)
        kit.stage(yaw=-35, floor=cam["dist"] * 0.7, boost=1.2, **cam)
        kit.render("env_" + name)
        kit.write_manifest("env_" + name, parts)
        kit.export_fbx("env_" + name)
