import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
from kit import Part
import bugkit as B
from bugkit import CARAPACE, CARAPACE_DK, CARAPACE_LT, LILAC, ACID, BONE


def build(ox=0.0, oy=0.0, S=(1.0, 0.76, 1.0)):
    body = Part("Body", CARAPACE, "SmoothPlastic", "body", rough=B.GLOSS)
    legs = Part("Legs", CARAPACE_DK, "SmoothPlastic", "body", rough=0.3)
    belly = Part("Belly", LILAC, "SmoothPlastic", "trim", rough=0.35)
    ram = Part("Ram", CARAPACE_LT, "SmoothPlastic", "armor", rough=0.2)
    trim = Part("Trim", BONE, "SmoothPlastic", "trim", rough=0.3)
    abd = Part("Abdomen", ACID, "Neon", "weak")

    # ---- thorax hump + overlapping back plates + lilac ribs between them
    TC = (0, -0.3, 4.0)
    RX, RY, RZ = 3.1, 3.7, 2.45
    body.ball(1.0, TC, scale=(RX, RY, RZ), segs=20)
    for y in (-2.3, -1.2, -0.1, 1.0, 2.0):
        k = math.sqrt(max(0.04, 1 - ((y - TC[1]) / RY) ** 2))
        belly.ball(1.0, (0, y, TC[2]), scale=(RX * k + 0.07, 0.09, RZ * k + 0.07), segs=14)
    for i, (y, z, sx) in enumerate(((-1.8, 5.8, 1.9), (-0.5, 6.05, 2.0), (0.8, 5.95, 2.0))):   # armour shingles
        body.ball(1.0, (0, y, z), scale=(sx, 0.9, 0.55), segs=14, rot=(10 - i * 6, 0, 0))
    body.ball(1.9, (0, -3.2, 3.0), scale=(1.15, 1.1, 0.85), segs=18)                      # head / neck mass
    for s in (-1, 1):                                                                     # shoulder pauldrons
        body.ball(1.4, (s * 3.0, -1.1, 4.7), scale=(0.7, 1.3, 0.9), segs=14, rot=(0, s * 20, 0))

    # ---- raised soft glowing abdomen with carapace ribs
    th = 28
    ax = Vector((0, math.cos(math.radians(th)), math.sin(math.radians(th))))
    AC = Vector((0, 3.8, 4.9))
    AR = 2.4
    abd.ball(AR, tuple(AC), scale=(0.95, 1.3, 0.95), segs=20, rot=(th, 0, 0))
    for t, k in ((-1.9, 0.78), (-0.9, 0.97), (0.2, 1.0), (1.3, 0.88), (2.3, 0.68)):
        c = AC + ax * t
        body.ball(1.0, tuple(c), scale=(AR * 0.95 * k + 0.1, 0.33, AR * 0.95 * k + 0.1), segs=14, rot=(th, 0, 0))
    body.ball(0.85, tuple(AC + ax * 3.4), segs=12)                                        # armoured rear cap
    B.cone(trim, tuple(AC + ax * 3.8), tuple(AC + ax * 5.0 + Vector((0, 0, 0.3))), 0.4, verts=8)

    # ---- lilac belly
    belly.ball(2.6, (0, -0.2, 2.1), scale=(1.15, 1.5, 0.45), segs=12)
    belly.ball(1.8, (0, -3.2, 2.0), scale=(1.15, 1.0, 0.45), segs=12)

    # ---- armoured ram: layered frill shield (like a battering plate), rim spikes, great horn
    SC = Vector((0, -5.0, 3.7))
    SA = -16
    R = Matrix.Rotation(math.radians(SA), 3, "X")
    ram.ball(1.0, tuple(SC), scale=(3.5, 1.0, 2.7), segs=22, rot=(SA, 0, 0))
    for s_ in (-1, 1):
        ram.ball(1.0, (s_ * 3.0, -4.3, 3.3), scale=(1.5, 0.8, 2.2), segs=14, rot=(-8, 0, s_ * 22))
    ram.ball(1.0, (0, -4.0, 5.9), scale=(2.4, 1.5, 0.9), segs=14, rot=(-10, 0, 0))        # brow cap
    for k in range(-3, 4):
        t = math.radians(90 - k * 26)
        lp = Vector((3.5 * math.cos(t), 0, 2.7 * math.sin(t)))
        ln = Vector((math.cos(t) / 3.5, 0, math.sin(t) / 2.7)).normalized()
        a = SC + R @ lp
        b = SC + R @ (lp + ln * (1.0 + 0.25 * (3 - abs(k)))) + Vector((0, -0.45, 0))
        B.cone(trim, tuple(a + (R @ ln) * -0.2), tuple(b), 0.3, verts=8)
    B.chain(trim, [(0, -5.8, 4.7), (0, -7.0, 5.6), (0, -7.2, 7.1), (0, -6.3, 8.4)], 0.8, 0.06, n=2, verts=10)   # great horn
    for s_ in (-1, 1):                                                                    # cheek tusks
        B.chain(trim, [(s_ * 3.4, -3.9, 2.2), (s_ * 4.2, -5.0, 2.0), (s_ * 3.8, -6.0, 2.9)], 0.42, 0.05, n=2, verts=8)

    # ---- legs: front reaches forward, hind pushes back
    for hy, ky, fy in ((-2.2, -3.0, -3.8), (0.0, 0.1, 0.2), (2.4, 3.2, 3.9)):
        B.leg(legs, trim, (2.4, hy, 3.0), (4.0, ky, 3.7), (4.3, fy, 0.0), r=0.8, verts=12, seg=8, spike=True, boot=0.7, bh=0.75)
    for y in (-1.6, 0.0, 1.6):                                                            # dorsal spikes
        B.cone(trim, (0, y, 6.2), (0, y + 0.1, 7.2), 0.3, verts=8)

    parts = [body, legs, belly, ram, trim, abd]
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
    kit.stage(target=(0, 0.5, 3.8), dist=26, height=6, yaw=yaw, floor=22, boost=1.5)
    kit.render("charger" if yaw == -35 else "_charger_%d" % yaw)
    print("BBOX", kit.bbox(parts))
    if yaw == -35:
        kit.write_manifest("charger", parts)
        kit.export_fbx("charger")
