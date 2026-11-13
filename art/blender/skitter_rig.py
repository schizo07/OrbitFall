"""SKITTER, rig v2: same geometry as skitter.py, split into articulated limbs (see rigkit.py).
Legs: odd = left (+X), even = right, front -> back: 1/2 front, 3/4 middle, 5/6 rear."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
import kit
import rigkit
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, LILAC, ACID, BONE


def build(ox=0.0, oy=0.0):
    D = -0.35   # body drop: low, scuttling stance
    rig = rigkit.Rig("skitter", "brood")
    body = rig.colour("carapace", CARAPACE, rough=B.GLOSS)
    legs = rig.colour("carapace_dk", CARAPACE_DK, rough=0.3)
    belly = rig.colour("lilac", LILAC, rough=0.35)
    trim = rig.colour("bone", BONE, rough=0.3)

    def z(v):
        return v + D

    ROWS = ((-0.55, -1.15, -1.8), (0.2, 0.15, 0.1), (0.95, 1.4, 2.0))

    # ---- Body (root): head / pronotum / abdomen, belly bands, dorsal spikes
    rig.limb("Body", "body", None, pivot=(0, 0.2, z(1.4)))
    body.ball(0.9, (0, -1.2, z(1.5)), scale=(1.22, 0.92, 0.82), segs=22)
    body.ball(0.95, (0, -0.4, z(1.7)), scale=(1.18, 0.8, 0.82), segs=22)
    body.ball(1.15, (0, 0.8, z(1.6)), scale=(1.0, 1.2, 0.9), segs=22, rot=(8, 0, 0))
    body.ball(0.7, (0, 1.5, z(1.8)), scale=(0.9, 1.0, 0.85), segs=18, rot=(14, 0, 0))
    body.ball(0.55, (0, -1.85, z(2.0)), scale=(1.5, 0.7, 0.42), segs=16)
    for hy in (-0.55, 0.2, 0.95):
        body.ball(0.6, (0.9, hy, z(2.0)), scale=(0.9, 0.95, 0.55), segs=14, rot=(0, 18, 0), mirror=True)
    for y, zz, h in ((-0.2, 2.45, 0.55), (0.5, 2.5, 0.6), (1.2, 2.6, 0.55)):
        B.cone(trim, (0, y, z(zz - 0.15)), (0, y + 0.05, z(zz + h)), 0.2, verts=8)
    belly.ball(1.0, (0, -0.2, z(1.2)), scale=(1.08, 1.3, 0.55), segs=14)
    belly.ball(1.1, (0, 0.9, z(1.15)), scale=(1.0, 1.2, 0.55), segs=14)
    belly.ball(0.8, (0, -1.25, z(1.1)), scale=(1.1, 0.9, 0.5), segs=12)
    for y in (0.4, 0.9, 1.4):
        dy = (y - 0.8) / 1.38
        k = math.sqrt(max(0.05, 1 - dy * dy))
        belly.ball(1.0, (0, y, z(1.6 + dy * 0.14)), scale=(1.15 * k + 0.04, 0.09, 1.035 * k + 0.04), segs=14, rot=(8, 0, 0))

    # ---- Eye clusters (weak spot): one object spanning both sides of the face
    eye = rig.solid("Eye", ACID, "Neon", "weak", parent="Body")
    B.eye_cluster(eye, (0.52, -1.98, z(2.0)), (0.3, -1, 0.15), r_big=0.38, r_small=0.16, n=5, ring=0.46)

    # ---- mandibles: big hooked cream pincers (pivot at the jaw hinge)
    for sx, nm in ((1, "L"), (-1, "R")):
        rig.limb("Mandible_%s" % nm, "limb", "Body", pivot=(sx * 0.4, -1.95, z(1.55)))
        B.chain(trim, [(sx * 0.4, -1.95, z(1.55)), (sx * 0.95, -2.35, z(1.4)), (sx * 1.0, -2.8, z(1.5)), (sx * 0.3, -3.25, z(1.7))],
                0.32, 0.05, n=3, verts=10)
        for y in (-2.65, -3.05):
            B.cone(trim, (sx * 0.6, y, z(1.5)), (sx * 0.3, y - 0.05, z(1.95)), 0.1, verts=6)

    # ---- six legs: sprawling stance, one object each, pivot at the hip
    n = 0
    for hy, ky, fy in ROWS:
        for sx in (1, -1):
            n += 1
            hip = (sx * 0.75, hy, z(1.4))
            rig.limb("Leg_%d" % n, "limb", "Body", pivot=hip)
            B.leg(legs, trim, hip, (sx * 1.85, ky, z(1.95)), (sx * 2.5, fy, 0.0), r=0.31, verts=12, spike=(hy < 0.5), seg=8, mirror=False)

    rig.build(ox, oy)
    return rig


LEGS = [("Leg_%d" % i, 1 if i % 2 else -1) for i in range(1, 7)]
POSE = rigkit.gait_pose(LEGS, {"Leg_1", "Leg_4", "Leg_5"}, amp=20, lift=16)
POSE.update(Mandible_L=(0, 0, -12), Mandible_R=(0, 0, 12))

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, -0.3, 1.2), dist=9.5, height=2.6, yaw=-35, floor=8, boost=1.5), POSE,
                  debug_stage_kw=dict(target=(0, -0.3, 1.4), dist=13, height=9.0, yaw=-20, floor=10, boost=1.5, size=(1000, 800)),
                  debug_name=dict(explode=0.45, label_size=0.3), budget=(4000, 10000))
