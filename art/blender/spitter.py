import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
from kit import Part
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, CARAPACE_LT, LILAC, ACID, BONE


def build(ox=0.0, oy=0.0, S=0.8):
    body = Part("Body", CARAPACE, "SmoothPlastic", "body", rough=B.GLOSS)
    legs = Part("Legs", CARAPACE_DK, "SmoothPlastic", "body", rough=0.3)
    belly = Part("Belly", LILAC, "SmoothPlastic", "trim", rough=0.35)
    trim = Part("Trim", BONE, "SmoothPlastic", "trim", rough=0.3)
    dark = Part("Dark", (34, 20, 48), "SmoothPlastic", "trim", rough=0.3)
    sac = Part("Sac", ACID, "Neon", "weak")

    # ---- thorax + swollen abdomen carrying the sac
    body.ball(1.3, (0, -0.7, 2.7), scale=(1.0, 1.1, 0.88), segs=18)                       # thorax
    body.ball(1.55, (0, 1.6, 2.95), scale=(1.0, 1.2, 1.0), segs=20, rot=(18, 0, 0))     # abdomen
    body.ball(0.8, (0, 3.0, 3.6), scale=(0.9, 1.0, 0.9), segs=16, rot=(25, 0, 0))       # abdomen tip
    belly.ball(1.3, (0, 0.2, 1.9), scale=(1.0, 1.6, 0.55), segs=16)                      # underside skirt
    belly.ball(1.5, (0, 1.9, 1.95), scale=(0.95, 1.25, 0.5), segs=16)

    # ---- the acid sac: big glowing bulb in a carapace cradle, satellite bubbles
    body.ball(1.7, (0, 1.55, 3.95), scale=(0.95, 0.65, 0.28), segs=22, rot=(18, 0, 0))  # collar ring (flat bowl)
    sac.ball(1.45, (0, 1.6, 4.9), scale=(0.95, 1.0, 1.1), segs=22)
    sac.ball(0.62, (1.05, 1.0, 4.45), segs=12, mirror=True)
    sac.ball(0.48, (0.75, 2.5, 4.4), segs=12, mirror=True)
    sac.ball(0.4, (0.1, 0.55, 5.9), segs=10)
    # cream thorns around the cradle
    for a in range(0, 360, 60):
        x = math.cos(math.radians(a)) * 1.55
        y = 1.55 + math.sin(math.radians(a)) * 1.1
        B.cone(trim, (x, y, 3.85), (x * 1.12, y + (y - 1.55) * 0.1, 4.55), 0.17, verts=6)

    # ---- long segmented neck rising from the thorax to a downward-pointing head
    neck = [(0, -1.6, 3.2), (0, -2.35, 4.2), (0, -2.35, 5.3), (0, -2.65, 6.1)]
    B.segments(body, belly, neck, 0.62, 0.48, n=2, ring_every=1, segs=12)
    body.ball(0.9, (0, -2.95, 6.3), scale=(1.0, 1.25, 0.85), segs=20)                    # head
    # snout / spout, cream, flared lip
    B.chain(trim, [(0, -3.5, 6.3), (0, -4.3, 6.2), (0, -5.0, 5.75)], 0.42, 0.3, n=3, verts=12, joint=True)
    trim.cyl(0.46, 0.22, (0, -5.1, 5.7), rot=(-48, 0, 0), verts=14, bevel=0.04)
    dark.cyl(0.3, 0.12, (0, -5.17, 5.64), rot=(-48, 0, 0), verts=12, bevel=0)           # spout hole
    # eyes: cream with dark pupils
    for s in (-1, 1):
        trim.ball(0.28, (s * 0.62, -3.2, 6.65), segs=12)
        dark.ball(0.15, (s * 0.7, -3.4, 6.7), segs=8)
    body.ball(0.5, (0, -2.95, 7.0), scale=(1.4, 0.8, 0.4), segs=12)                      # brow
    for s in (-1, 1):                                                                     # head horns
        B.chain(trim, [(s * 0.5, -2.6, 6.9), (s * 0.9, -2.2, 7.3), (s * 0.85, -1.7, 7.5)], 0.2, 0.03, n=2, verts=8)

    # ---- legs: front pair short, rear two pairs strong
    for hy, ky, fy, r in ((-1.0, -1.6, -2.3, 0.42), (0.5, 0.6, 0.7, 0.5), (2.0, 2.7, 3.4, 0.5)):
        B.leg(legs, trim, (0.9, hy, 2.4), (2.1, ky, 3.0), (2.8, fy, 0.0), r=r, verts=12, seg=8, spike=False)
    parts = [body, legs, belly, trim, dark, sac]
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
    kit.stage(target=(0, 0, 2.6), dist=12.5, height=3.0, yaw=yaw, floor=11, boost=1.5)
    kit.render("spitter" if yaw == -35 else "_spitter_%d" % yaw)
    print("BBOX", kit.bbox(parts))
    if yaw == -35:
        kit.write_manifest("spitter", parts)
        kit.export_fbx("spitter")
