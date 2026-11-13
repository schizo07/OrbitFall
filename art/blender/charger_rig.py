"""CHARGER, rig v2: same geometry as charger.py, split into articulated limbs (see rigkit.py).
Legs: odd = left (+X), even = right, front -> back. Ram pivots at the neck so the head-butt can be animated."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
import rigkit
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, CARAPACE_LT, LILAC, ACID, BONE


def build(ox=0.0, oy=0.0, S=(1.0, 0.76, 1.0)):
    rig = rigkit.Rig("charger", "brood", S=S)
    body = rig.colour("carapace", CARAPACE, rough=B.GLOSS)
    legs = rig.colour("carapace_dk", CARAPACE_DK, rough=0.3)
    belly = rig.colour("lilac", LILAC, rough=0.35)
    ram = rig.colour("carapace_lt", CARAPACE_LT, rough=0.2)
    trim = rig.colour("bone", BONE, rough=0.3)

    # ---- Body (root): thorax hump, plates, ribs, head mass, pauldrons, abdomen ribs, belly, dorsal spikes
    rig.limb("Body", "body", None, pivot=(0, 0.0, 3.0))
    TC = (0, -0.3, 4.0)
    RX, RY, RZ = 3.1, 3.7, 2.45
    body.ball(1.0, TC, scale=(RX, RY, RZ), segs=20)
    for y in (-2.3, -1.2, -0.1, 1.0, 2.0):
        k = math.sqrt(max(0.04, 1 - ((y - TC[1]) / RY) ** 2))
        belly.ball(1.0, (0, y, TC[2]), scale=(RX * k + 0.07, 0.09, RZ * k + 0.07), segs=14)
    for i, (y, z, sx) in enumerate(((-1.8, 5.8, 1.9), (-0.5, 6.05, 2.0), (0.8, 5.95, 2.0))):
        body.ball(1.0, (0, y, z), scale=(sx, 0.9, 0.55), segs=14, rot=(10 - i * 6, 0, 0))
    body.ball(1.9, (0, -3.2, 3.0), scale=(1.15, 1.1, 0.85), segs=18)
    for s in (-1, 1):
        body.ball(1.4, (s * 3.0, -1.1, 4.7), scale=(0.7, 1.3, 0.9), segs=14, rot=(0, s * 20, 0))

    th = 28
    ax = Vector((0, math.cos(math.radians(th)), math.sin(math.radians(th))))
    AC = Vector((0, 3.8, 4.9))
    AR = 2.4
    for t, k in ((-1.9, 0.78), (-0.9, 0.97), (0.2, 1.0), (1.3, 0.88), (2.3, 0.68)):
        c = AC + ax * t
        body.ball(1.0, tuple(c), scale=(AR * 0.95 * k + 0.1, 0.33, AR * 0.95 * k + 0.1), segs=14, rot=(th, 0, 0))
    body.ball(0.85, tuple(AC + ax * 3.4), segs=12)
    B.cone(trim, tuple(AC + ax * 3.8), tuple(AC + ax * 5.0 + Vector((0, 0, 0.3))), 0.4, verts=8)
    belly.ball(2.6, (0, -0.2, 2.1), scale=(1.15, 1.5, 0.45), segs=12)
    belly.ball(1.8, (0, -3.2, 2.0), scale=(1.15, 1.0, 0.45), segs=12)
    for y in (-1.6, 0.0, 1.6):
        B.cone(trim, (0, y, 6.2), (0, y + 0.1, 7.2), 0.3, verts=8)

    # ---- Abdomen (weak spot): raised soft glowing sac
    abd = rig.solid("Abdomen", ACID, "Neon", "weak", parent="Body")
    abd.ball(AR, tuple(AC), scale=(0.95, 1.3, 0.95), segs=20, rot=(th, 0, 0))

    # ---- Ram (armour): layered frill shield, rim spikes, great horn, cheek tusks
    rig.limb("Ram", "armor", "Body", pivot=(0, -3.4, 3.4))
    SC = Vector((0, -5.0, 3.7))
    SA = -16
    R = Matrix.Rotation(math.radians(SA), 3, "X")
    ram.ball(1.0, tuple(SC), scale=(3.5, 1.0, 2.7), segs=22, rot=(SA, 0, 0))
    for s_ in (-1, 1):
        ram.ball(1.0, (s_ * 3.0, -4.3, 3.3), scale=(1.5, 0.8, 2.2), segs=14, rot=(-8, 0, s_ * 22))
    ram.ball(1.0, (0, -4.0, 5.9), scale=(2.4, 1.5, 0.9), segs=14, rot=(-10, 0, 0))
    for k in range(-3, 4):
        t = math.radians(90 - k * 26)
        lp = Vector((3.5 * math.cos(t), 0, 2.7 * math.sin(t)))
        ln = Vector((math.cos(t) / 3.5, 0, math.sin(t) / 2.7)).normalized()
        a = SC + R @ lp
        b = SC + R @ (lp + ln * (1.0 + 0.25 * (3 - abs(k)))) + Vector((0, -0.45, 0))
        B.cone(trim, tuple(a + (R @ ln) * -0.2), tuple(b), 0.3, verts=8)
    B.chain(trim, [(0, -5.8, 4.7), (0, -7.0, 5.6), (0, -7.2, 7.1), (0, -6.3, 8.4)], 0.8, 0.06, n=2, verts=10)
    for s_ in (-1, 1):
        B.chain(trim, [(s_ * 3.4, -3.9, 2.2), (s_ * 4.2, -5.0, 2.0), (s_ * 3.8, -6.0, 2.9)], 0.42, 0.05, n=2, verts=8)

    # ---- legs: front reaches forward, hind pushes back; one object each, pivot at the hip
    n = 0
    for hy, ky, fy in ((-2.2, -3.0, -3.8), (0.0, 0.1, 0.2), (2.4, 3.2, 3.9)):
        for sx in (1, -1):
            n += 1
            hip = (sx * 2.4, hy, 3.0)
            rig.limb("Leg_%d" % n, "limb", "Body", pivot=hip)
            B.leg(legs, trim, hip, (sx * 4.0, ky, 3.7), (sx * 4.3, fy, 0.0), r=0.8, verts=12, seg=8, spike=True, boot=0.7, bh=0.75, mirror=False)

    rig.build(ox, oy)
    return rig


LEGS = [("Leg_%d" % i, 1 if i % 2 else -1) for i in range(1, 7)]
POSE = rigkit.gait_pose(LEGS, {"Leg_1", "Leg_4", "Leg_5"}, amp=16, lift=12)
POSE["Ram"] = (-6, 0, 0)

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, 0.5, 3.8), dist=26, height=6, yaw=-35, floor=22, boost=1.5), POSE, budget=(4000, 10000))
