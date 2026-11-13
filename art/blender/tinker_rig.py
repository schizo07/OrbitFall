"""TINKER, rig v2: same geometry as tinker.py, split into articulated limbs (see rigkit.py)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
from mathutils import Vector, Matrix
import kit
import rigkit
from kit import GUNMETAL, DARK, RUST, YELLOW, AMBER


def build(ox=0.0, oy=0.0):
    rig = rigkit.Rig("tinker", "cog")
    metal = rig.colour("metal", GUNMETAL, "Metal")
    plates = rig.colour("plates", RUST)
    dark = rig.colour("dark", DARK)
    trim = rig.colour("trim", YELLOW)
    body, legs, arm_r = metal, metal, metal      # same gunmetal; each call lands in the current limb

    HIP_Z, KNEE_Z = 1.7, 1.1
    L = lambda s: "L" if s > 0 else "R"          # character faces -Y, so its left is +X

    # ---- Body (root): pelvis + barrel torso + back cog / exhaust
    rig.limb("Body", "body", None, pivot=(0, 0.05, HIP_Z))
    dark.box((2.5, 1.3, 0.5), (0, 0.05, 1.85), bevel=0.15, seg=2)                        # pelvis
    tilt = 16
    C = Vector((0, -0.2, 2.75))
    R = Matrix.Rotation(math.radians(tilt), 3, "X")
    T = lambda x, y, z: tuple(C + R @ Vector((x, y, z)))
    body.cyl(1.0, 1.75, tuple(C), rot=(tilt, 0, 0), r2=1.25, verts=18, bevel=0.14, seg=3)
    trim.cyl(1.04, 0.17, T(0, 0, -0.62), rot=(tilt, 0, 0), r2=1.06, verts=18, bevel=0.03)   # hazard band
    plates.hull([T(-0.7, -1.18, 0.55), T(0.7, -1.18, 0.55), T(0.5, -1.18, -0.45), T(-0.5, -1.18, -0.45),
                 T(-0.6, -0.8, 0.5), T(0.6, -0.8, 0.5), T(0.45, -0.8, -0.4), T(-0.45, -0.8, -0.4)],
                bevel=0.1, seg=2)
    plates.rivets([T(-0.45, -1.18, 0.38), T(0.45, -1.18, 0.38), T(-0.3, -1.18, -0.28), T(0.3, -1.18, -0.28)],
                  r=0.1, normal=tuple(R @ Vector((0, -1, 0))))
    plates.gear(0.62, 0.5, 9, 0.22, T(0, 1.2, 0.1), rot=(90 + tilt, 0, 0), bevel=0.04)
    dark.cyl(0.14, 0.4, T(0, 1.2, 0.1), rot=(90 + tilt, 0, 0), verts=10, bevel=0.02)
    dark.cyl(0.24, 1.1, (0.55, 0.85, 3.75), rot=(-12, 0, 0), r2=0.3, verts=12, bevel=0.04)  # exhaust stack
    for sx in (-1, 1):                                                                       # shoulder caps
        plates.cyl(0.6, 0.42, (sx * 1.7, -0.2, 3.3), rot=(0, sx * 28, 0), r2=0.45, verts=16, bevel=0.1, seg=2)

    # ---- Head (dome, socket ring, brow, emblems, antenna); the cyclops Eye is its own weak-spot object
    rig.limb("Head", "limb", "Body", pivot=(0, -0.55, 3.05))
    body.ball(1.2, (0, -0.55, 3.55), scale=(1.15, 1.0, 0.7), segs=22)
    dark.cyl(0.8, 0.4, (0, -1.5, 3.55), rot=(90, 0, 0), verts=22, bevel=0.07)
    for sx in (-1, 1):
        plates.gear(0.5, 0.4, 8, 0.2, (sx * 1.33, -0.45, 3.5), rot=(0, 90, 0), bevel=0.03)
        dark.cyl(0.14, 0.3, (sx * 1.33, -0.45, 3.5), rot=(0, 90, 0), verts=10, bevel=0.02)
    plates.box((1.7, 0.4, 0.34), (0, -1.45, 4.22), rot=(-22, 0, 0), bevel=0.12, seg=2)
    dark.cyl(0.06, 0.55, (-0.55, -0.3, 4.1), verts=8, bevel=0.0)
    trim.ball(0.16, (-0.55, -0.3, 4.4), segs=10)
    eye = rig.solid("Eye", AMBER, "Neon", "weak", parent="Head")
    eye.ball(0.64, (0, -1.62, 3.55), scale=(1, 0.7, 1), segs=22)

    # ---- legs (stubby): Upper = hip joint + piston + upper shin; Lower = lower shin + ankle + foot
    for s in (1, -1):
        x = s * 0.95
        n = L(s)
        rig.limb("Leg_%s_Upper" % n, "limb", "Body", pivot=(x, 0.05, HIP_Z))
        dark.ball(0.58, (x, 0.05, 1.7), segs=20)                                         # hip joint
        dark.tube((x, 0.5286, KNEE_Z), (x, 0.5, 1.7), 0.08, verts=8, bevel=0)                  # hydraulic piston (upper half)
        legs.cyl(0.43, 0.525, (x, 0.05, 1.3625), r2=0.4, verts=14, bevel=0.06)           # upper shin (split at the knee)
        dark.ball(0.5, (x, 0.05, KNEE_Z), segs=16)                                       # knee cap (hides the seam)
        rig.limb("Leg_%s_Lower" % n, "limb", "Leg_%s_Upper" % n, pivot=(x, 0.05, KNEE_Z))
        legs.cyl(0.46, 0.525, (x, 0.05, 0.8375), r2=0.43, verts=14, bevel=0.06)          # lower shin
        dark.tube((x, 0.55, 0.65), (x, 0.5286, KNEE_Z), 0.08, verts=8, bevel=0)                # hydraulic piston (lower half)
        dark.cyl(0.55, 0.28, (x, 0.05, 0.62), verts=14, bevel=0.06)                      # ankle ring
        legs.box((1.35, 1.9, 0.6), (x, -0.25, 0.3), bevel=0.22, seg=3)                  # foot
        plates.box((1.42, 0.62, 0.52), (x, -0.95, 0.31), bevel=0.2, seg=3)               # toe cap

    # ---- right arm = blaster (pivot at the shoulder joint)
    rig.limb("Arm_R", "limb", "Body", pivot=(-1.5, -0.2, 3.0))
    dark.ball(0.44, (-1.5, -0.2, 3.0), segs=20)
    arm_r.box((0.8, 1.7, 0.9), (-1.85, -1.2, 2.45), bevel=0.2, seg=3)
    arm_r.cyl(0.3, 1.0, (-1.85, -2.4, 2.45), rot=(90, 0, 0), verts=14, bevel=0.05)
    plates.cyl(0.38, 0.22, (-1.85, -2.05, 2.45), rot=(90, 0, 0), verts=14, bevel=0.04)
    dark.cyl(0.22, 0.18, (-1.85, -2.95, 2.45), rot=(90, 0, 0), verts=14, bevel=0.02)
    for i in range(3):
        dark.box((0.12, 1.1, 0.22), (-2.1 + i * 0.25, -1.1, 2.98), bevel=0.03, seg=1)
    trim.box((0.26, 0.5, 0.08), (-1.85, -1.75, 2.9), bevel=0.02, seg=1)

    # ---- left arm = big fist
    rig.limb("Arm_L", "limb", "Body", pivot=(1.5, -0.2, 3.0))
    dark.ball(0.44, (1.5, -0.2, 3.0), segs=20)
    body.tube((1.55, -0.2, 3.0), (2.0, -0.45, 2.0), 0.4, verts=12)
    dark.ball(0.46, (2.0, -0.45, 2.0), segs=20)
    body.tube((2.0, -0.45, 2.0), (2.05, -1.05, 1.45), 0.4, verts=12)
    body.box((1.0, 1.0, 0.85), (2.1, -1.2, 1.1), bevel=0.25, seg=3)
    plates.box((1.06, 0.3, 0.9), (2.1, -1.48, 1.12), bevel=0.12, seg=2)

    rig.build(ox, oy)
    return rig


POSE = {
    "Leg_L_Upper": (-24, 0, 0), "Leg_L_Lower": (18, 0, 0),
    "Leg_R_Upper": (22, 0, 0), "Leg_R_Lower": (6, 0, 0),
    "Arm_L": (24, 0, 0), "Arm_R": (-18, 0, 0), "Head": (0, 0, 6),
}

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, -0.3, 2.2), dist=10.5, height=2.4, yaw=-35), POSE,
                  debug_stage_kw=dict(target=(0, -0.3, 2.6), dist=15, height=2.0, yaw=-18, size=(1000, 800)),
                  debug_name=dict(explode=0.55, label_size=0.3), budget=(4000, 10000))
