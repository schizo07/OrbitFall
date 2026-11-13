import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector
import kit
from kit import Part
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, CARAPACE_LT, LILAC, ACID, BONE


def build(ox=0.0, oy=0.0):
    D = -0.35   # body drop: low, scuttling stance
    body = Part("Body", CARAPACE, "SmoothPlastic", "body", rough=B.GLOSS)
    legs = Part("Legs", CARAPACE_DK, "SmoothPlastic", "body", rough=0.3)
    belly = Part("Belly", LILAC, "SmoothPlastic", "trim", rough=0.35)
    trim = Part("Trim", BONE, "SmoothPlastic", "trim", rough=0.3)
    eye = Part("Eye", ACID, "Neon", "weak")

    def z(v):
        return v + D

    # ---- body: head / pronotum / abdomen, chunky overlapping carapace
    body.ball(0.9, (0, -1.2, z(1.5)), scale=(1.22, 0.92, 0.82), segs=22)                  # big head
    body.ball(0.95, (0, -0.4, z(1.7)), scale=(1.18, 0.8, 0.82), segs=22)                  # pronotum shield
    body.ball(1.15, (0, 0.8, z(1.6)), scale=(1.0, 1.2, 0.9), segs=22, rot=(8, 0, 0))     # abdomen
    body.ball(0.7, (0, 1.5, z(1.8)), scale=(0.9, 1.0, 0.85), segs=18, rot=(14, 0, 0))    # abdomen tip
    body.ball(0.55, (0, -1.85, z(2.0)), scale=(1.5, 0.7, 0.42), segs=16)                 # brow ridge
    for hy in (-0.55, 0.2, 0.95):                                                         # shoulder plates over leg roots
        body.ball(0.6, (0.9, hy, z(2.0)), scale=(0.9, 0.95, 0.55), segs=14, rot=(0, 18, 0), mirror=True)
    for y, zz, h in ((-0.2, 2.45, 0.55), (0.5, 2.5, 0.6), (1.2, 2.6, 0.55)):            # dorsal spikes
        B.cone(trim, (0, y, z(zz - 0.15)), (0, y + 0.05, z(zz + h)), 0.2, verts=8)

    # ---- lilac underside skirt and abdomen bands
    belly.ball(1.0, (0, -0.2, z(1.2)), scale=(1.08, 1.3, 0.55), segs=14)
    belly.ball(1.1, (0, 0.9, z(1.15)), scale=(1.0, 1.2, 0.55), segs=14)
    belly.ball(0.8, (0, -1.25, z(1.1)), scale=(1.1, 0.9, 0.5), segs=12)
    for y in (0.4, 0.9, 1.4):
        dy = (y - 0.8) / 1.38
        k = math.sqrt(max(0.05, 1 - dy * dy))
        belly.ball(1.0, (0, y, z(1.6 + dy * 0.14)), scale=(1.15 * k + 0.04, 0.09, 1.035 * k + 0.04), segs=16, rot=(8, 0, 0))

    # ---- six legs: sprawling stance
    for hy, ky, fy in ((-0.55, -1.15, -1.8), (0.2, 0.15, 0.1), (0.95, 1.4, 2.0)):
        B.leg(legs, trim, (0.75, hy, z(1.4)), (1.85, ky, z(1.95)), (2.5, fy, 0.0), r=0.31, verts=12, spike=(hy < 0.5), seg=8)

    # ---- mandibles: big hooked cream pincers with serrations (tips nearly meet)
    B.chain(trim, [(0.4, -1.95, z(1.55)), (0.95, -2.35, z(1.4)), (1.0, -2.8, z(1.5)), (0.3, -3.25, z(1.7))],
            0.32, 0.05, n=3, verts=10, mirror=True)
    for sx in (-1, 1):
        for y in (-2.65, -3.05):
            B.cone(trim, (sx * 0.6, y, z(1.5)), (sx * 0.3, y - 0.05, z(1.95)), 0.1, verts=6)

    # ---- eye clusters (weak spot): big eye ringed by beads, one cluster each side of the face
    B.eye_cluster(eye, (0.52, -1.98, z(2.0)), (0.3, -1, 0.15), r_big=0.38, r_small=0.16, n=5, ring=0.46)

    parts = [body, legs, belly, trim, eye]
    for p in parts:
        ob = p.build()
        ob.location.x += ox
        ob.location.y += oy
    return parts


if __name__ == "__main__":
    kit.reset()
    parts = build()
    yaw = float(os.environ.get("YAW", -35))
    kit.stage(target=(0, -0.3, 1.2), dist=9.5, height=2.6, yaw=yaw, floor=8, boost=1.5)
    kit.render("skitter" if yaw == -35 else "_skitter_%d" % yaw)
    print("BBOX", kit.bbox(parts))
    if yaw == -35:
        kit.write_manifest("skitter", parts)
        kit.export_fbx("skitter")
