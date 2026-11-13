"""RIVET, rig v2: same geometry as rivet.py, split into articulated limbs (see rigkit.py)."""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math
import kit
import rigkit
from kit import GUNMETAL, DARK, RUST, YELLOW

VISOR = (255, 70, 45)


def build(ox=0.0, oy=0.0):
    rig = rigkit.Rig("rivet", "cog")
    metal = rig.colour("metal", GUNMETAL, "Metal")
    plates = rig.colour("plates", RUST)
    dark = rig.colour("dark", DARK)
    trim = rig.colour("trim", YELLOW)
    body = legs = metal
    HIP_Z, KNEE_Z = 3.4, 2.2

    # ---- Body (root): pelvis, V-torso, plate, shoulders, backpack
    rig.limb("Body", "body", None, pivot=(0, -0.05, HIP_Z))
    dark.box((3.1, 1.6, 0.7), (0, -0.05, 3.65), bevel=0.2, seg=2)                       # pelvis
    z0, z1 = 3.9, 5.85
    hw0, hw1 = 1.25, 1.95
    yf0, yf1 = -0.85, -1.1
    yb0, yb1 = 0.85, 1.0
    body.hull([(-hw0, yf0, z0), (hw0, yf0, z0), (-hw0, yb0, z0), (hw0, yb0, z0),
               (-hw1, yf1, z1), (hw1, yf1, z1), (-hw1, yb1, z1), (hw1, yb1, z1)], bevel=0.28, seg=3)

    def front_y(z):
        return yf0 + (yf1 - yf0) * (z - z0) / (z1 - z0)

    def half_w(z):
        return hw0 + (hw1 - hw0) * (z - z0) / (z1 - z0)

    pz0, pz1 = 4.3, 5.55
    pw0, pw1 = half_w(pz0) - 0.3, half_w(pz1) - 0.3
    d = 0.3
    plates.hull([(-pw0, front_y(pz0) - d, pz0), (pw0, front_y(pz0) - d, pz0),
                 (-pw1, front_y(pz1) - d, pz1), (pw1, front_y(pz1) - d, pz1),
                 (-pw0, front_y(pz0) + 0.1, pz0), (pw0, front_y(pz0) + 0.1, pz0),
                 (-pw1, front_y(pz1) + 0.1, pz1), (pw1, front_y(pz1) + 0.1, pz1)], bevel=0.12, seg=2)
    nrm = (0, -1, -0.12)
    pts = []
    for zr, xs in ((5.25, (-1.0, 0, 1.0)), (4.6, (-0.8, 0.8))):
        for xr in xs:
            pts.append((xr, front_y(zr) - d, zr))
    plates.rivets(pts, r=0.12, normal=nrm)
    trim.gear(0.34, 0.26, 6, 0.1, (0, front_y(4.9) - d - 0.04, 4.92), rot=(90, 0, 0), bevel=0.02)
    trim.box((2.5, 0.22, 0.2), (0, front_y(4.0) - 0.08, 4.02), bevel=0.05, seg=1)       # hazard sill
    for sx in (-1, 1):                                                                   # shoulder armour
        plates.box((1.55, 1.7, 0.85), (sx * 2.3, -0.05, 5.7), rot=(0, sx * 24, 0), bevel=0.3, seg=3, taper=(0.9, 0.9))
        trim.box((0.14, 1.2, 0.22), (sx * 2.78, -0.05, 5.52), rot=(0, sx * 24, 0), bevel=0.04, seg=1)
    body.box((2.2, 1.0, 1.8), (0, 1.55, 4.9), bevel=0.25, seg=2)                        # backpack
    plates.gear(0.75, 0.6, 10, 0.22, (0, 2.12, 4.9), rot=(90, 0, 0), bevel=0.04)
    dark.cyl(0.18, 0.4, (0, 2.12, 4.9), rot=(90, 0, 0), verts=10, bevel=0.02)
    for sx in (-1, 1):
        dark.cyl(0.26, 1.3, (sx * 0.65, 1.5, 6.25), r2=0.3, verts=12, bevel=0.05)
        plates.cyl(0.33, 0.14, (sx * 0.65, 1.5, 6.9), verts=12, bevel=0.03)

    # ---- Head: armoured block, visor housing, crest, ears (visor slit = weak spot, separate)
    rig.limb("Head", "limb", "Body", pivot=(0, -0.2, 5.85))
    body.box((1.9, 1.6, 1.15), (0, -0.2, 6.1), bevel=0.32, seg=3, taper=(0.9, 0.95))
    dark.box((1.55, 0.35, 0.55), (0, -1.0, 6.1), bevel=0.14, seg=2)
    plates.hull([(-0.12, -0.7, 6.55), (0.12, -0.7, 6.55), (-0.12, 0.6, 6.5), (0.12, 0.6, 6.5),
                 (-0.18, -0.7, 6.6), (0.18, -0.7, 6.6), (-0.2, 0.9, 6.3), (0.2, 0.9, 6.3),
                 (-0.18, -0.9, 6.3), (0.18, -0.9, 6.3)], bevel=0.04, seg=1)
    for sx in (-1, 1):
        dark.cyl(0.3, 0.3, (sx * 0.98, -0.1, 6.0), rot=(0, 90, 0), verts=12, bevel=0.04)
    eye = rig.solid("Eye", VISOR, "Neon", "weak", parent="Head")
    eye.box((1.3, 0.2, 0.26), (0, -1.2, 6.1), bevel=0.07, seg=2)

    # ---- legs (mirrored): Upper = thigh + knee joint/guard + upper piston; Lower = shin + ankle + foot
    for s in (1, -1):
        x = s * 1.15
        n = "L" if s > 0 else "R"
        rig.limb("Leg_%s_Upper" % n, "limb", "Body", pivot=(x, -0.05, HIP_Z))
        legs.box((1.15, 1.2, 1.2), (x, -0.05, 3.0), bevel=0.2, seg=2, taper=(1.08, 1.05))  # thigh
        dark.ball(0.66, (x, -0.05, 2.2), segs=14)                                       # knee
        plates.box((0.95, 0.35, 0.8), (x, -0.62, 2.2), rot=(-10, 0, 0), bevel=0.12, seg=2)  # knee guard
        dark.tube((x, 0.5909, KNEE_Z), (x, 0.55, 3.1), 0.09, verts=8)                    # piston (upper half)
        rig.limb("Leg_%s_Lower" % n, "limb", "Leg_%s_Upper" % n, pivot=(x, -0.05, KNEE_Z))
        legs.box((1.05, 1.1, 1.3), (x, -0.05, 1.5), bevel=0.2, seg=2, taper=(1.12, 1.1))  # shin
        dark.tube((x, 0.65, 0.9), (x, 0.5909, KNEE_Z), 0.09, verts=8)                    # piston (lower half)
        dark.cyl(0.62, 0.3, (x, -0.05, 0.8), verts=16, bevel=0.06)                      # ankle
        legs.box((1.6, 2.4, 0.7), (x, -0.4, 0.35), bevel=0.25, seg=3)                  # foot
        plates.box((1.66, 0.8, 0.6), (x, -1.2, 0.38), bevel=0.22, seg=3)                # toe cap

    # ---- twin blaster arms (pivot = shoulder ball)
    for sx, n in ((-1, "R"), (1, "L")):
        x = sx * 2.25
        rig.limb("Arm_%s" % n, "limb", "Body", pivot=(sx * 2.2, -0.15, 5.0))
        dark.ball(0.62, (sx * 2.2, -0.15, 5.0), segs=14)                                 # shoulder joint
        body.box((0.95, 1.0, 1.5), (x, -0.15, 4.35), rot=(-8, 0, 0), bevel=0.22, seg=3)      # upper arm
        dark.cyl(0.52, 1.0, (x, -0.3, 3.65), rot=(0, 90, 0), verts=16, bevel=0.06)          # elbow
        body.box((1.05, 2.3, 1.05), (x, -1.45, 3.65), bevel=0.28, seg=3)                      # gun housing
        body.cyl(0.34, 1.3, (x, -3.1, 3.65), rot=(90, 0, 0), verts=16, bevel=0.05)            # barrel
        plates.cyl(0.46, 0.26, (x, -2.7, 3.65), rot=(90, 0, 0), verts=16, bevel=0.05)        # barrel shroud
        dark.cyl(0.26, 0.2, (x, -3.8, 3.65), rot=(90, 0, 0), verts=16, bevel=0.03)           # muzzle
        trim.box((0.28, 0.7, 0.08), (x, -0.95, 4.2), bevel=0.02, seg=1)                      # hazard tab
        for i in range(2):
            dark.box((0.1, 1.0, 0.18), (x - 0.15 + i * 0.3, -1.6, 4.25), bevel=0.03, seg=1)    # heat-sink fins

    rig.build(ox, oy)
    return rig


POSE = {
    "Leg_L_Upper": (-24, 0, 0), "Leg_L_Lower": (18, 0, 0),
    "Leg_R_Upper": (22, 0, 0), "Leg_R_Lower": (6, 0, 0),
    "Arm_L": (14, 0, 0), "Arm_R": (-10, 0, 0), "Head": (0, 0, 6),
}

if __name__ == "__main__":
    kit.reset()
    rig = build()
    rigkit.finish(rig, dict(target=(0, -0.7, 3.4), dist=14, height=3.4, yaw=-35), POSE,
                  debug_stage_kw=dict(target=(0, -0.7, 3.6), dist=20, height=2.5, yaw=-18, size=(1000, 800)),
                  debug_name=dict(explode=0.5, label_size=0.4), budget=(4000, 10000))
