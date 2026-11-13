"""TITAN, rig v2: same geometry as titan.py, split into articulated limbs (see rigkit.py).
Legs: odd = left (+X), even = right, front -> back; Leg_n_Upper pivots at the hip, Leg_n_Lower at the knee.
Body = domes/pronotum/pauldrons/belly, Abdomen = rear segment (own pivot), Head + Mandible_L/R at the front."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
import rigkit
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, LILAC, ACID, BONE

# main elytra dome and abdomen ellipsoids (centre, radii)
DOME = (Vector((0, 0.0, 11.6)), Vector((7.0, 8.0, 6.0)))
ABD = (Vector((0, 8.0, 10.6)), Vector((5.6, 5.8, 4.8)))


def surf(e, x, y):
    c, r = e
    t = 1 - ((x - c.x) / r.x) ** 2 - ((y - c.y) / r.y) ** 2
    z = c.z + r.z * math.sqrt(max(t, 0.0))
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
    t = n.to_track_quat("Z", "Y")
    for a in (0, 120, 240):
        d = t @ Vector((math.cos(math.radians(a + 30)), math.sin(math.radians(a + 30)), 0))
        glow.ball(0.42 * size, tuple(P + n * 1.1 * size + d * 1.2 * size), segs=8, mirror=mirror)


def build(ox=0.0, oy=0.0, S=0.9):
    rig = rigkit.Rig("titan", "brood", S=S)
    body = rig.colour("carapace", CARAPACE, rough=B.GLOSS)
    legs = rig.colour("carapace_dk", CARAPACE_DK, rough=0.3)
    belly = rig.colour("lilac", LILAC, rough=0.35)
    trim = rig.colour("bone", BONE, rough=0.3)
    v = [rig.solid("Vent_%d" % (i + 1), ACID, "Neon", "weak", parent="Body" if i < 3 else "Abdomen") for i in range(4)]

    # ---- Body (root): twin elytra domes, pronotum shield, pauldrons, belly skirt, seam, three dorsal vent housings
    rig.limb("Body", "body", None, pivot=(0, 0.6, 8.0))
    c, r = DOME
    for s in (-1, 1):
        body.ball(1.0, (s * 2.2, c.y, c.z), scale=(r.x - 1.6, r.y, r.z), segs=16)
    body.ball(1.0, tuple(c), scale=(r.x - 1.0, r.y - 0.5, r.z - 0.4), segs=12)
    body.ball(1.0, (0, -7.6, 13.6), scale=(5.4, 3.8, 3.0), segs=14)                       # pronotum shield
    for s in (-1, 1):                                                                     # shoulder pauldrons
        body.ball(1.0, (s * 6.9, -4.4, 11.2), scale=(2.2, 3.0, 2.4), segs=10, rot=(0, s * 25, 0))
        body.ball(1.0, (s * 6.9, 0.8, 10.8), scale=(2.2, 2.9, 2.2), segs=10, rot=(0, s * 25, 0))
    belly.ball(1.0, (0, 0.5, 7.2), scale=(6.8, 9.2, 2.6), segs=20)                        # belly skirt
    belly.ball(1.0, (0, 0.5, 17.3), scale=(0.35, 7.2, 0.9), segs=10)                      # elytra seam
    vent(body, v[0], DOME, 0.0, -3.6, 1.4)
    vent(body, v[1], DOME, 4.2, 0.6, 1.3, mirror=True)
    vent(body, v[2], DOME, 3.6, 5.2, 1.15, mirror=True)

    # ---- Abdomen: rear segment with its own belly skirt, bands, and the fourth vent housing
    c2, r2 = ABD
    rig.limb("Abdomen", "limb", "Body", pivot=(0, 4.2, 10.0))
    body.ball(1.0, tuple(c2), scale=tuple(r2), segs=16, rot=(10, 0, 0))
    body.ball(1.0, (0, 12.0, 11.2), scale=(3.0, 3.2, 2.8), segs=14, rot=(14, 0, 0))      # abdomen tip
    belly.ball(1.0, (0, 8.0, 7.0), scale=(5.4, 6.2, 2.2), segs=16)
    for y in (5.5, 7.5, 9.5, 11.5):
        dy = (y - c2.y) / r2.y
        k = math.sqrt(max(0.05, 1 - dy * dy))
        belly.ball(1.0, (0, y, c2.z + dy * 1.2), scale=(r2.x * k + 0.15, 0.3, r2.z * k + 0.15), segs=18, rot=(10, 0, 0))
    vent(body, v[3], ABD, 0.0, 10.0, 1.4)

    # ---- Head: skull, brow, eyes, crown of horns
    rig.limb("Head", "limb", "Body", pivot=(0, -8.0, 8.6))
    body.ball(1.0, (0, -10.0, 8.2), scale=(4.2, 3.8, 3.2), segs=14)
    body.ball(1.0, (0, -11.6, 10.2), scale=(3.6, 2.0, 1.2), segs=12)                      # brow ridge
    for s in (-1, 1):
        belly.ball(1.0, (s * 2.4, -12.6, 9.2), scale=(1.2, 0.9, 1.1), segs=10)
    for k, a in enumerate((0, 32, 62, 90)):
        ar = math.radians(a)
        C = Vector((0, -8.4, 15.3))
        base = C + Vector((3.2 * math.sin(ar), -1.3 * math.cos(ar), -0.2 * k))
        out = Vector((math.sin(ar) * 0.9, -math.cos(ar) * 0.55, 0))
        H = 5.2 - 1.0 * k
        mid = base + out * 1.0 + Vector((0, 0, H * 0.5))
        tip = base + out * 2.4 + Vector((0, 0, H))
        B.chain(trim, [tuple(base - Vector((0, 0, 0.5))), tuple(mid), tuple(tip)], 1.3 - 0.2 * k, 0.08, n=3, verts=8, mirror=(a > 0), joint=False)

    # ---- stag mandibles (pivot at the jaw hinge)
    for s, nm in ((1, "L"), (-1, "R")):
        rig.limb("Mandible_%s" % nm, "limb", "Head", pivot=(s * 1.9, -11.6, 8.0))
        B.chain(trim, [(s * 1.9, -11.6, 8.0), (s * 4.0, -13.8, 7.2), (s * 4.4, -16.0, 7.9), (s * 1.8, -17.6, 9.3)],
                1.3, 0.12, n=3, verts=10, joint=False)
        for y in (-14.6, -15.8):
            B.cone(trim, (s * 3.7, y, 7.9), (s * 2.3, y - 0.1, 10.0), 0.4, verts=6)

    # ---- six huge legs: Upper (hip -> knee, knee cap + spike), Lower (tibia + boot)
    n = 0
    for hy, ky, fy in ((-5.6, -7.0, -8.0), (0.6, 0.8, 1.0), (6.6, 8.2, 9.4)):
        for sx in (1, -1):
            n += 1
            hip = (sx * 4.8, hy, 8.0)
            rig.limb("Leg_%d_Upper" % n, "limb", "Body", pivot=hip)
            lower = "Leg_%d_Lower" % n
            knee = (sx * 8.8, ky, 10.4)

            def sw(lower=lower, knee=knee, n=n):
                rig.limb(lower, "limb", "Leg_%d_Upper" % n, pivot=knee)
            B.leg(legs, trim, hip, knee, (sx * 10.4, fy, 0.0), r=1.9, verts=12, seg=8, spike=True,
                  boot=0.6, bh=1.4, pad=body, mirror=False, switch=sw)

    rig.build(ox, oy)
    return rig


LEGS = [("Leg_%d" % i, 1 if i % 2 else -1) for i in range(1, 7)]


def _pose():
    p = {}
    fwd = {"Leg_1", "Leg_4", "Leg_5"}
    for nm, s in LEGS:
        if nm in fwd:
            p[nm + "_Upper"] = (0, -s * 10, -s * 12)
            p[nm + "_Lower"] = (0, -s * 14, 0)
        else:
            p[nm + "_Upper"] = (0, 0, s * 10)
            p[nm + "_Lower"] = (0, s * 6, 0)
    p.update(Head=(-4, 0, 6), Mandible_L=(0, 0, -10), Mandible_R=(0, 0, 10), Abdomen=(-4, 0, -4))
    return p


POSE = _pose()

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, 0, 9.0), dist=58, height=14, yaw=-35, floor=44, boost=1.5), POSE, budget=(4000, 16000))
