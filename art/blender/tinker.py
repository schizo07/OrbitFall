import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
from kit import Part, GUNMETAL, DARK, RUST, YELLOW, AMBER


def build(ox=0.0, oy=0.0):
    """Builds TINKER at x offset ox. Returns list of Parts."""
    body = Part("Body", GUNMETAL, "Metal", "body")
    legs = Part("Legs", GUNMETAL, "Metal", "body")
    arm_r = Part("Arm_R", GUNMETAL, "Metal", "body")
    plates = Part("Plates", RUST, "SmoothPlastic", "trim")
    dark = Part("Dark", DARK, "SmoothPlastic", "trim")
    trim = Part("Trim", YELLOW, "SmoothPlastic", "trim")
    eye = Part("Eye", AMBER, "Neon", "weak")

    # ---- legs & feet (stubby, wide stance)
    for s in (-1, 1):
        x = s * 0.95
        legs.box((1.35, 1.9, 0.6), (x, -0.25, 0.3), bevel=0.22, seg=3)                  # foot
        plates.box((1.42, 0.62, 0.52), (x, -0.95, 0.31), bevel=0.2, seg=3)               # toe cap
        legs.cyl(0.46, 1.05, (x, 0.05, 1.1), r2=0.4, verts=14, bevel=0.06)               # shin
        dark.cyl(0.55, 0.28, (x, 0.05, 0.62), verts=14, bevel=0.06)                      # ankle ring
        dark.ball(0.58, (x, 0.05, 1.7), segs=20)                                         # hip joint
        dark.tube((x, 0.55, 0.65), (x, 0.5, 1.7), 0.08, verts=8)                          # hydraulic piston
    dark.box((2.5, 1.3, 0.5), (0, 0.05, 1.85), bevel=0.15, seg=2)                        # pelvis

    # ---- torso (barrel, hunched forward)
    tilt = 16
    C = Vector((0, -0.2, 2.75))
    R = Matrix.Rotation(math.radians(tilt), 3, "X")
    T = lambda x, y, z: tuple(C + R @ Vector((x, y, z)))
    body.cyl(1.0, 1.75, tuple(C), rot=(tilt, 0, 0), r2=1.25, verts=18, bevel=0.14, seg=3)
    trim.cyl(1.04, 0.17, T(0, 0, -0.62), rot=(tilt, 0, 0), r2=1.06, verts=18, bevel=0.03)   # hazard band
    # chest armour plate: trapezoid, sits proud of the barrel front
    plates.hull([T(-0.7, -1.18, 0.55), T(0.7, -1.18, 0.55), T(0.5, -1.18, -0.45), T(-0.5, -1.18, -0.45),
                 T(-0.6, -0.8, 0.5), T(0.6, -0.8, 0.5), T(0.45, -0.8, -0.4), T(-0.45, -0.8, -0.4)],
                bevel=0.1, seg=2)
    plates.rivets([T(-0.45, -1.18, 0.38), T(0.45, -1.18, 0.38), T(-0.3, -1.18, -0.28), T(0.3, -1.18, -0.28)],
                  r=0.1, normal=tuple(R @ Vector((0, -1, 0))))
    # back cog + stack
    plates.gear(0.62, 0.5, 9, 0.22, T(0, 1.2, 0.1), rot=(90 + tilt, 0, 0), bevel=0.04)
    dark.cyl(0.14, 0.4, T(0, 1.2, 0.1), rot=(90 + tilt, 0, 0), verts=10, bevel=0.02)
    dark.cyl(0.24, 1.1, (0.55, 0.85, 3.75), rot=(-12, 0, 0), r2=0.3, verts=12, bevel=0.04)  # exhaust stack

    # ---- head (big dome, sunk into shoulders) with cyclops eye
    body.ball(1.2, (0, -0.55, 3.55), scale=(1.15, 1.0, 0.7), segs=22)
    dark.cyl(0.8, 0.4, (0, -1.5, 3.55), rot=(90, 0, 0), verts=22, bevel=0.07)             # eye socket ring
    eye.ball(0.64, (0, -1.62, 3.55), scale=(1, 0.7, 1), segs=22)
    for sx in (-1, 1):                                                                       # cog emblems on head
        plates.gear(0.5, 0.4, 8, 0.2, (sx * 1.33, -0.45, 3.5), rot=(0, 90, 0), bevel=0.03)
        dark.cyl(0.14, 0.3, (sx * 1.33, -0.45, 3.5), rot=(0, 90, 0), verts=10, bevel=0.02)
    plates.box((1.7, 0.4, 0.34), (0, -1.45, 4.22), rot=(-22, 0, 0), bevel=0.12, seg=2)     # brow plate
    dark.cyl(0.06, 0.55, (-0.55, -0.3, 4.1), verts=8, bevel=0.0)                           # antenna
    trim.ball(0.16, (-0.55, -0.3, 4.4), segs=10)

    # ---- right arm = blaster
    dark.ball(0.44, (-1.5, -0.2, 3.0), segs=20)                                             # shoulder joint
    arm_r.box((0.8, 1.7, 0.9), (-1.85, -1.2, 2.45), bevel=0.2, seg=3)                       # gun housing
    arm_r.cyl(0.3, 1.0, (-1.85, -2.4, 2.45), rot=(90, 0, 0), verts=14, bevel=0.05)           # barrel
    plates.cyl(0.38, 0.22, (-1.85, -2.05, 2.45), rot=(90, 0, 0), verts=14, bevel=0.04)       # barrel band
    dark.cyl(0.22, 0.18, (-1.85, -2.95, 2.45), rot=(90, 0, 0), verts=14, bevel=0.02)         # muzzle

    for sx in (-1, 1):                                                                       # shoulder caps
        plates.cyl(0.6, 0.42, (sx * 1.7, -0.2, 3.3), rot=(0, sx * 28, 0), r2=0.45, verts=16, bevel=0.1, seg=2)
    for i in range(3):                                                                      # gun heat-sink fins
        dark.box((0.12, 1.1, 0.22), (-2.1 + i * 0.25, -1.1, 2.98), bevel=0.03, seg=1)
    trim.box((0.26, 0.5, 0.08), (-1.85, -1.75, 2.9), bevel=0.02, seg=1)                      # hazard tab on gun

    # ---- left arm = big fist
    dark.ball(0.44, (1.5, -0.2, 3.0), segs=20)
    body.tube((1.55, -0.2, 3.0), (2.0, -0.45, 2.0), 0.4, verts=12)
    dark.ball(0.46, (2.0, -0.45, 2.0), segs=20)
    body.tube((2.0, -0.45, 2.0), (2.05, -1.05, 1.45), 0.4, verts=12)
    body.box((1.0, 1.0, 0.85), (2.1, -1.2, 1.1), bevel=0.25, seg=3)                         # fist
    plates.box((1.06, 0.3, 0.9), (2.1, -1.48, 1.12), bevel=0.12, seg=2)                      # knuckle guard

    parts = [body, legs, arm_r, plates, dark, trim, eye]
    for p in parts:
        ob = p.build()
        ob.location.x += ox
        ob.location.y += oy
    return parts


if __name__ == "__main__":
    kit.reset()
    parts = build()
    yaw = float(os.environ.get("YAW", -35))
    kit.stage(target=(0, -0.3, 2.2), dist=10.5, height=2.4, yaw=yaw)
    kit.render("tinker" if yaw == -35 else "_tinker_%d" % yaw)
    kit.write_manifest("tinker", parts)
    if yaw == -35:
        kit.export_fbx("tinker")
