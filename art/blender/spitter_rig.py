"""SPITTER, rig v2: same geometry as spitter.py, split into articulated limbs (see rigkit.py).
Legs: odd = left (+X), even = right, front -> back. Neck pivots at the thorax, Head at the top of the neck."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
import kit
import rigkit
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, LILAC, ACID, BONE

DARKB = (34, 20, 48)


def build(ox=0.0, oy=0.0, S=0.8):
    rig = rigkit.Rig("spitter", "brood", S=S)
    body = rig.colour("carapace", CARAPACE, rough=B.GLOSS)
    legs = rig.colour("carapace_dk", CARAPACE_DK, rough=0.3)
    belly = rig.colour("lilac", LILAC, rough=0.35)
    trim = rig.colour("bone", BONE, rough=0.3)
    dark = rig.colour("dark", DARKB, rough=0.3)

    # ---- Body (root): thorax + swollen abdomen, belly skirt, sac cradle collar and thorns
    rig.limb("Body", "body", None, pivot=(0, 0.5, 2.4))
    body.ball(1.3, (0, -0.7, 2.7), scale=(1.0, 1.1, 0.88), segs=18)
    body.ball(1.55, (0, 1.6, 2.95), scale=(1.0, 1.2, 1.0), segs=20, rot=(18, 0, 0))
    body.ball(0.8, (0, 3.0, 3.6), scale=(0.9, 1.0, 0.9), segs=16, rot=(25, 0, 0))
    belly.ball(1.3, (0, 0.2, 1.9), scale=(1.0, 1.6, 0.55), segs=16)
    belly.ball(1.5, (0, 1.9, 1.95), scale=(0.95, 1.25, 0.5), segs=16)
    body.ball(1.7, (0, 1.55, 3.95), scale=(0.95, 0.65, 0.28), segs=22, rot=(18, 0, 0))   # collar ring
    for a in range(0, 360, 60):
        x = math.cos(math.radians(a)) * 1.55
        y = 1.55 + math.sin(math.radians(a)) * 1.1
        B.cone(trim, (x, y, 3.85), (x * 1.12, y + (y - 1.55) * 0.1, 4.55), 0.17, verts=6)

    # ---- Sac (weak spot): big glowing bulb + satellite bubbles
    sac = rig.solid("Sac", ACID, "Neon", "weak", parent="Body")
    sac.ball(1.45, (0, 1.6, 4.9), scale=(0.95, 1.0, 1.1), segs=22)
    sac.ball(0.62, (1.05, 1.0, 4.45), segs=12, mirror=True)
    sac.ball(0.48, (0.75, 2.5, 4.4), segs=12, mirror=True)
    sac.ball(0.4, (0.1, 0.55, 5.9), segs=10)

    # ---- Head: long segmented neck, head, snout / spout, eyes, brow, horns
    rig.limb("Neck", "limb", "Body", pivot=(0, -1.6, 3.2))
    neck = [(0, -1.6, 3.2), (0, -2.35, 4.2), (0, -2.35, 5.3), (0, -2.65, 6.1)]
    B.segments(body, belly, neck, 0.62, 0.48, n=2, ring_every=1, segs=12)
    rig.limb("Head", "limb", "Neck", pivot=(0, -2.65, 6.1))
    body.ball(0.9, (0, -2.95, 6.3), scale=(1.0, 1.25, 0.85), segs=20)
    B.chain(trim, [(0, -3.5, 6.3), (0, -4.3, 6.2), (0, -5.0, 5.75)], 0.42, 0.3, n=3, verts=12, joint=True)
    trim.cyl(0.46, 0.22, (0, -5.1, 5.7), rot=(-48, 0, 0), verts=14, bevel=0.04)
    dark.cyl(0.3, 0.12, (0, -5.17, 5.64), rot=(-48, 0, 0), verts=12, bevel=0)
    for s in (-1, 1):
        trim.ball(0.28, (s * 0.62, -3.2, 6.65), segs=12)
        dark.ball(0.15, (s * 0.7, -3.4, 6.7), segs=8)
    body.ball(0.5, (0, -2.95, 7.0), scale=(1.4, 0.8, 0.4), segs=12)
    for s in (-1, 1):
        B.chain(trim, [(s * 0.5, -2.6, 6.9), (s * 0.9, -2.2, 7.3), (s * 0.85, -1.7, 7.5)], 0.2, 0.03, n=2, verts=8)

    # ---- legs: front pair short, rear two pairs strong; one object each, pivot at the hip
    n = 0
    for hy, ky, fy, r in ((-1.0, -1.6, -2.3, 0.42), (0.5, 0.6, 0.7, 0.5), (2.0, 2.7, 3.4, 0.5)):
        for sx in (1, -1):
            n += 1
            hip = (sx * 0.9, hy, 2.4)
            rig.limb("Leg_%d" % n, "limb", "Body", pivot=hip)
            B.leg(legs, trim, hip, (sx * 2.1, ky, 3.0), (sx * 2.8, fy, 0.0), r=r, verts=12, seg=8, spike=False, mirror=False)

    rig.build(ox, oy)
    return rig


LEGS = [("Leg_%d" % i, 1 if i % 2 else -1) for i in range(1, 7)]
POSE = rigkit.gait_pose(LEGS, {"Leg_1", "Leg_4", "Leg_5"}, amp=18, lift=14)
POSE["Neck"] = (-5, 0, 0)
POSE["Head"] = (-8, 0, 8)

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, 0, 2.6), dist=12.5, height=3.0, yaw=-35, floor=11, boost=1.5), POSE, budget=(4000, 10000))
