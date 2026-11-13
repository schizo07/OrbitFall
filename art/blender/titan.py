import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
from kit import Part
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, CARAPACE_LT, LILAC, ACID, BONE

# main elytra dome and abdomen ellipsoids (centre, radii)
DOME = (Vector((0, 0.0, 11.6)), Vector((7.0, 8.0, 6.0)))
ABD = (Vector((0, 8.0, 10.6)), Vector((5.6, 5.8, 4.8)))


def surf(e, x, y):
    c, r = e
    t = 1 - ((x - c.x) / r.x) ** 2 - ((y - c.y) / r.y) ** 2
    z = c.z + r.z * math.sqrt(max(t, 0.0))
    # gradient normal of the ellipsoid
    n = Vector(((x - c.x) / r.x ** 2, (y - c.y) / r.y ** 2, (z - c.z) / r.z ** 2)).normalized()
    return Vector((x, y, z)), n


def vent(body, glow, e, x, y, size=1.0, mirror=False):
    P, n = surf(e, x, y)
    n = (n + Vector((0, 0, 0.6))).normalized()
    m = n.to_track_quat("Z", "Y").to_matrix().to_4x4()
    body.cyl(1.9 * size, 1.5 * size, tuple(P + n * 0.3 * size), rot=m, r2=1.35 * size, verts=12, bevel=0.0, mirror=mirror)
    glow.ball(1.2 * size, tuple(P + n * 1.0 * size), scale=(1, 1, 0.8), segs=14, rot=m, mirror=mirror)
    glow.tube(tuple(P + n * 1.2 * size), tuple(P + n * 3.9 * size), 1.05 * size, 0.3 * size, verts=10, mirror=mirror)
    glow.ball(1.0 * size, tuple(P + n * 1.3 * size), segs=10, mirror=mirror)
    glow.ball(0.5 * size, tuple(P + n * 3.95 * size), segs=8, mirror=mirror)
    # lobed blobs bubbling around the crater
    t = n.to_track_quat("Z", "Y")
    for a in (0, 120, 240):
        d = t @ Vector((math.cos(math.radians(a + 30)), math.sin(math.radians(a + 30)), 0))
        glow.ball(0.42 * size, tuple(P + n * 1.1 * size + d * 1.2 * size), segs=8, mirror=mirror)


def build(ox=0.0, oy=0.0, S=0.9):
    body = Part("Body", CARAPACE, "SmoothPlastic", "body", rough=B.GLOSS)
    legs = Part("Legs", CARAPACE_DK, "SmoothPlastic", "body", rough=0.3)
    belly = Part("Belly", LILAC, "SmoothPlastic", "trim", rough=0.35)
    trim = Part("Trim", BONE, "SmoothPlastic", "trim", rough=0.3)
    v = [Part("Vent_%d" % (i + 1), ACID, "Neon", "weak") for i in range(4)]

    # ---- main carapace: twin elytra domes, pronotum shield, abdomen
    c, r = DOME
    for s in (-1, 1):
        body.ball(1.0, (s * 2.2, c.y, c.z), scale=(r.x - 1.6, r.y, r.z), segs=16)
    body.ball(1.0, tuple(c), scale=(r.x - 1.0, r.y - 0.5, r.z - 0.4), segs=12)
    body.ball(1.0, (0, -7.6, 13.6), scale=(5.4, 3.8, 3.0), segs=14)                       # pronotum shield
    c2, r2 = ABD
    body.ball(1.0, tuple(c2), scale=tuple(r2), segs=16, rot=(10, 0, 0))                   # abdomen
    body.ball(1.0, (0, 12.0, 11.2), scale=(3.0, 3.2, 2.8), segs=14, rot=(14, 0, 0))      # abdomen tip
    for s in (-1, 1):                                                                     # shoulder pauldrons
        body.ball(1.0, (s * 6.9, -4.4, 11.2), scale=(2.2, 3.0, 2.4), segs=10, rot=(0, s * 25, 0))
        body.ball(1.0, (s * 6.9, 0.8, 10.8), scale=(2.2, 2.9, 2.2), segs=10, rot=(0, s * 25, 0))
    # head
    body.ball(1.0, (0, -10.0, 8.2), scale=(4.2, 3.8, 3.2), segs=14)
    body.ball(1.0, (0, -11.6, 10.2), scale=(3.6, 2.0, 1.2), segs=12)                      # brow ridge

    # ---- lilac belly skirt, abdomen bands, head eyes
    belly.ball(1.0, (0, 0.5, 7.2), scale=(6.8, 9.2, 2.6), segs=20)
    belly.ball(1.0, (0, 8.0, 7.0), scale=(5.4, 6.2, 2.2), segs=16)
    for y in (5.5, 7.5, 9.5, 11.5):
        dy = (y - c2.y) / r2.y
        k = math.sqrt(max(0.05, 1 - dy * dy))
        belly.ball(1.0, (0, y, c2.z + dy * 1.2), scale=(r2.x * k + 0.15, 0.3, r2.z * k + 0.15), segs=18, rot=(10, 0, 0))
    for s in (-1, 1):
        belly.ball(1.0, (s * 2.4, -12.6, 9.2), scale=(1.2, 0.9, 1.1), segs=10)

    # ---- acid vents (weak spots): each a separate glowing object on the back
    vent(body, v[0], DOME, 0.0, -3.6, 1.4)
    vent(body, v[1], DOME, 4.2, 0.6, 1.3, mirror=True)
    vent(body, v[2], DOME, 3.6, 5.2, 1.15, mirror=True)
    vent(body, v[3], ABD, 0.0, 10.0, 1.4)

    # ---- crown of horns fanned over the brow + stag mandibles
    for k, a in enumerate((0, 32, 62, 90)):
        ar = math.radians(a)
        C = Vector((0, -8.4, 15.3))
        base = C + Vector((3.2 * math.sin(ar), -1.3 * math.cos(ar), -0.2 * k))
        out = Vector((math.sin(ar) * 0.9, -math.cos(ar) * 0.55, 0))
        H = 5.2 - 1.0 * k
        mid = base + out * 1.0 + Vector((0, 0, H * 0.5))
        tip = base + out * 2.4 + Vector((0, 0, H))
        B.chain(trim, [tuple(base - Vector((0, 0, 0.5))), tuple(mid), tuple(tip)], 1.3 - 0.2 * k, 0.08, n=3, verts=8, mirror=(a > 0), joint=False)
    for s in (-1, 1):                                                                     # mandibles
        B.chain(trim, [(s * 1.9, -11.6, 8.0), (s * 4.0, -13.8, 7.2), (s * 4.4, -16.0, 7.9), (s * 1.8, -17.6, 9.3)],
                1.3, 0.12, n=3, verts=10, joint=False)
        for y in (-14.6, -15.8):
            B.cone(trim, (s * 3.7, y, 7.9), (s * 2.3, y - 0.1, 10.0), 0.4, verts=6)
    # elytra seam down the back
    belly.ball(1.0, (0, 0.5, 17.3), scale=(0.35, 7.2, 0.9), segs=10)

    # ---- six huge legs
    for hy, ky, fy in ((-5.6, -7.0, -8.0), (0.6, 0.8, 1.0), (6.6, 8.2, 9.4)):
        B.leg(legs, trim, (4.8, hy, 8.0), (8.8, ky, 10.4), (10.4, fy, 0.0), r=1.9, verts=12, seg=8, spike=True,
              boot=0.6, bh=1.4, pad=body)

    parts = [body, legs, belly, trim] + v
    for p in parts:
        ob = p.build()
        ob.location.x += ox
        ob.location.y += oy
    B.scale_parts(parts, S)
    return parts


if __name__ == "__main__":
    kit.reset()
    parts = build()
    yaw = float(os.environ.get("YAW", -35))
    kit.stage(target=(0, 0, 9.0), dist=58, height=14, yaw=yaw, floor=44, boost=1.5)
    kit.render("titan" if yaw == -35 else "_titan_%d" % yaw)
    print("BBOX", kit.bbox(parts))
    if yaw == -35:
        kit.write_manifest("titan", parts)
        kit.export_fbx("titan")
