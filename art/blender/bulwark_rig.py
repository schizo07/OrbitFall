"""BULWARK, rig v2: same geometry as bulwark.py, split into articulated limbs (see rigkit.py).
Legs: Leg_1 = left front, Leg_2 = right front, Leg_3 = left rear, Leg_4 = right rear (left = +X)."""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Vector, Matrix
import kit
import rigkit
from kit import GUNMETAL, DARK, RUST, YELLOW, AMBER


def build(ox=0.0, oy=0.0):
    rig = rigkit.Rig("bulwark", "cog")
    metal = rig.colour("metal", GUNMETAL, "Metal")
    shield = rig.colour("rust", RUST)
    dark = rig.colour("dark", DARK)
    trim = rig.colour("trim", YELLOW)
    body = legs = metal

    # ---- Body (root): hull, deck plates, flank plates, turret pedestal, exhaust, rear cog
    rig.limb("Body", "body", None, pivot=(0, 1.05, 3.05))
    zb, zt = 1.6, 4.0
    body.hull([(-2.8, -2.3, zb), (2.8, -2.3, zb), (-2.8, 3.1, zb), (2.8, 3.1, zb),
               (-2.1, -1.9, zt), (2.1, -1.9, zt), (-2.1, 2.6, zt), (2.1, 2.6, zt)], bevel=0.4, seg=3)
    dark.box((4.6, 1.0, 0.5), (0, 0.4, 1.4), bevel=0.15, seg=2)                         # belly underplate
    shield.hull([(-1.7, -1.7, 4.0), (1.7, -1.7, 4.0), (-1.7, 0.0, 4.0), (1.7, 0.0, 4.0),
                 (-1.4, -1.7, 4.3), (1.4, -1.7, 4.3), (-1.4, 0.0, 4.3), (1.4, 0.0, 4.3)], bevel=0.12, seg=2)
    shield.rivets([(-1.15, -1.3, 4.3), (1.15, -1.3, 4.3), (-1.15, -0.4, 4.3), (1.15, -0.4, 4.3)], r=0.11, normal=(0, 0, 1))
    for i in range(3):
        dark.box((2.8, 0.16, 0.14), (0, 1.9 + i * 0.32, 4.02), bevel=0.02, seg=1)
    for sx in (-1, 1):                                                                  # flank plates
        shield.box((0.3, 3.8, 1.3), (sx * 2.55, 0.4, 2.7), rot=(0, sx * -20, 0), bevel=0.1, seg=2)
    dark.cyl(1.55, 0.6, (0, 0.8, 4.3), verts=18, bevel=0.1)                             # core pedestal
    dark.cyl(1.2, 0.5, (0, 0.8, 4.8), r2=1.0, verts=18, bevel=0.08)                      # cradle ring
    for a in (40, 140, 220, 320):                                                       # cradle prongs
        r = math.radians(a)
        dark.tube((math.cos(r) * 1.12, 0.8 + math.sin(r) * 1.12, 4.9), (math.cos(r) * 0.95, 0.8 + math.sin(r) * 0.95, 5.85), 0.13, verts=8)
    for sx in (-1, 1):                                                                  # rear exhaust + cog
        dark.cyl(0.38, 1.4, (sx * 1.95, 2.55, 4.7), r2=0.44, verts=12, bevel=0.06)
        shield.cyl(0.48, 0.16, (sx * 1.95, 2.55, 5.42), verts=12, bevel=0.03)
    shield.gear(0.95, 0.78, 10, 0.2, (0, 3.2, 2.9), rot=(90, 0, 0), bevel=0.03)
    dark.cyl(0.24, 0.4, (0, 3.2, 2.9), rot=(90, 0, 0), verts=10, bevel=0.02)

    core = rig.solid("Core", AMBER, "Neon", "weak", parent="Body")
    core.ball(1.05, (0, 0.8, 5.55), segs=22)

    # ---- Shield: heater shield, leaning back, framed in gunmetal (armour object)
    rig.limb("Shield", "armor", "Body", pivot=None)
    tilt = -14.0
    tn = math.tan(math.radians(14))

    def yf(z):
        return -3.1 + (z - 0.6) * tn
    outline = [(-3.0, 4.7), (3.0, 4.7), (3.4, 3.5), (2.6, 1.9), (0.9, 0.6), (-0.9, 0.6), (-2.6, 1.9), (-3.4, 3.5)]

    def slab(scale, y_front, y_back, cz=2.9):
        pts = []
        for yy in (y_front, y_back):
            for (x, z) in outline:
                zz = cz + (z - cz) * scale
                pts.append((x * scale, yy + (zz - 0.6) * tn, zz))
        return pts
    body.hull(slab(1.0, -3.1, -2.1), bevel=0.3, seg=3)                                  # frame / backing
    shield.hull(slab(0.86, -3.4, -2.9), bevel=0.2, seg=3)                               # face plate
    Rt = Matrix.Rotation(math.radians(tilt), 3, "X")
    Rf = Rt @ Matrix.Rotation(math.radians(90), 3, "X")
    fy = lambda z: yf(z) - 0.32
    dark.gear(0.85, 0.7, 10, 0.2, (0, fy(3.65) - 0.02, 3.65), rot=Rf, bevel=0.03)
    dark.cyl(0.3, 0.3, (0, fy(3.65) - 0.1, 3.65), rot=Rf, verts=12, bevel=0.03)
    for i in range(5):                                                                  # hazard slashes
        xx = -2.0 + i * 1.0
        trim.box((0.34, 0.12, 0.95), (xx, fy(2.3) - 0.04, 2.3), rot=Rt @ Matrix.Rotation(math.radians(28), 3, "Y"), bevel=0.04, seg=1)
    shield.rivets([(-2.55, fy(4.3), 4.3), (2.55, fy(4.3), 4.3), (-2.9, fy(3.3), 3.3), (2.9, fy(3.3), 3.3)], r=0.15,
                  normal=tuple(Rt @ Vector((0, -1, 0))))

    # ---- crab legs, one object each (pivot at the hip on the hull flank)
    n = 0
    for y in (-0.1, 2.2):
        for sx in (1, -1):
            n += 1
            rig.limb("Leg_%d" % n, "limb", "Body", pivot=(sx * 2.5, y, 3.05))
            legs.box((1.7, 1.25, 1.0), (sx * 3.05, y, 3.05), rot=(0, sx * -10, 0), bevel=0.25, seg=2)   # thigh
            dark.cyl(0.5, 1.4, (sx * 3.7, y, 2.85), rot=(90, 0, 0), verts=12, bevel=0.05)           # knee hinge
            legs.box((1.15, 1.15, 2.4), (sx * 3.75, y, 1.65), rot=(0, sx * 6, 0), bevel=0.22, seg=2, taper=(1.25, 1.2))  # shin
            legs.box((1.9, 2.3, 0.6), (sx * 3.8, y - 0.25, 0.3), bevel=0.22, seg=3)                  # foot
            shield.box((1.96, 0.55, 0.5), (sx * 3.8, y - 1.2, 0.28), bevel=0.18, seg=2)              # toe cap

    # ---- heavy claws (pivot at the shoulder)
    for sx, nm in ((-1, "R"), (1, "L")):
        rig.limb("Arm_%s" % nm, "limb", "Body", pivot=(sx * 2.85, -1.5, 3.0))
        dark.cyl(0.75, 1.0, (sx * 2.85, -1.5, 3.0), verts=12, bevel=0.06)               # shoulder
        metal.tube((sx * 2.85, -1.5, 2.9), (sx * 3.75, -2.7, 2.2), 0.62, verts=14, bevel=0.05)
        metal.box((1.7, 1.7, 1.6), (sx * 3.75, -3.2, 2.1), bevel=0.32, seg=3)              # palm
        shield.box((1.74, 0.3, 1.1), (sx * 3.75, -4.0, 2.1), bevel=0.1, seg=2)           # palm guard
        for pz, gap in ((2.65, 1), (1.55, -1)):                                          # upper / lower prong
            metal.hull([(sx * 3.0, -3.9, pz - 0.35), (sx * 4.5, -3.9, pz - 0.35), (sx * 3.0, -3.9, pz + 0.35), (sx * 4.5, -3.9, pz + 0.35),
                        (sx * 3.0, -5.7, pz - 0.1 * gap), (sx * 3.5, -5.7, pz - 0.1 * gap), (sx * 3.0, -5.7, pz + 0.1 * gap), (sx * 3.5, -5.7, pz + 0.1 * gap)],
                       bevel=0.12, seg=2)

    rig.build(ox, oy)
    return rig


LEGS = [("Leg_1", 1), ("Leg_2", -1), ("Leg_3", 1), ("Leg_4", -1)]
POSE = dict(rigkit.gait_pose(LEGS, {"Leg_1", "Leg_4"}, amp=16, lift=14), Arm_L=(18, 0, 0), Arm_R=(-18, 0, 0))

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, -0.2, 2.7), dist=19, height=7.0, yaw=-35, floor=16), POSE, budget=(4000, 10000))
