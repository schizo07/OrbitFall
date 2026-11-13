"""SET B: Halcyon trooper armour kit, fitted around a standard R15-proportioned dummy (the dummy is never exported).
Every piece's origin = the centre of the body part (or attachment) it welds to, so C0 = identity."""
import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kit
import halcyon as H
from halcyon import Frame, CYAN

HEAD = (0, 0, 5.18)
TORSO = (0, 0, 3.7)
BACK = (0, 0.5, 3.75)


def build(ox=0.0, oy=0.0):
    a = H.Asset("armor_kit", fbx="armor_kit", kind="armor")
    wh, nv, og, mt, wsh, ndk, nlt, ogd, stl = a.white, a.navy, a.orange, a.metal, a.white_sh, a.navy_dk, a.navy_lt, a.orange_dk, a.steel
    P = lambda b, p: (b[0] + p[0], b[1] + p[1], b[2] + p[2])

    # ---------------- Helmet (origin = head centre / HatAttachment parent) ----------------
    a.limb("Helmet", "armor", None, pivot=HEAD)
    h = lambda p: P(HEAD, p)
    wh.hull([h(p) for p in [(-0.82, -0.8, -0.15), (0.82, -0.8, -0.15), (-0.82, 0.85, -0.15), (0.82, 0.85, -0.15),
                            (-0.88, -0.86, 0.35), (0.88, -0.86, 0.35), (-0.88, 0.9, 0.35), (0.88, 0.9, 0.35),
                            (-0.6, -0.62, 0.9), (0.6, -0.62, 0.9), (-0.6, 0.72, 0.9), (0.6, 0.72, 0.9)]], bevel=0.24, seg=3)   # shell
    nv.box((1.5, 1.35, 0.55), h((0, 0.03, -0.38)), bevel=0.18, seg=2)                              # jaw / neck guard
    nv.box((1.1, 0.3, 0.2), h((0, -0.76, -0.2)), bevel=0.06, seg=1)                                 # chin bar
    wh.box((1.45, 0.34, 0.26), h((0, -0.62, 0.34)), rot=(-14, 0, 0), bevel=0.1, seg=2)              # brow ridge
    ndk.box((1.2, 0.3, 0.62), h((0, -0.66, 0.0)), bevel=0.12, seg=2)                                # visor frame
    og.box((0.2, 1.5, 0.3), h((0, 0.0, 0.88)), bevel=0.07, seg=1, taper=(0.8, 1))                   # crest
    wsh.box((0.5, 0.5, 0.4), h((0, 0.72, 0.05)), bevel=0.1, seg=1)                                  # rear vent block
    for s in (-1, 1):
        nv.cyl(0.33, 0.28, h((s * 0.84, 0.0, 0.0)), rot=(0, 90, 0), verts=14, bevel=0.05, seg=1)   # ear pods
        og.cyl(0.2, 0.32, h((s * 0.86, 0.0, 0.0)), rot=(0, 90, 0), verts=12, bevel=0.03, seg=1)
        wh.box((0.14, 0.5, 0.14), h((s * 0.6, -0.62, 0.62)), rot=(0, 0, s * -20), bevel=0.04, seg=1)
    stl.tube(h((0.52, 0.5, 0.55)), h((0.6, 0.62, 1.4)), 0.035, verts=6, bevel=0)                    # antenna
    og.ball(0.08, h((0.6, 0.62, 1.42)), segs=8)
    vis = a.glow("Visor", CYAN, "glow", "Helmet", pivot=h((0, -0.8, 0.0)))
    vis.box((0.98, 0.14, 0.34), h((0, -0.82, 0.0)), bevel=0.07, seg=2)

    # ---------------- ChestPlate (origin = UpperTorso centre) ----------------
    a.limb("ChestPlate", "armor", None, pivot=TORSO)
    t = lambda p: P(TORSO, p)
    wh.hull([t((-1.1, -0.5, 0.8)), t((1.1, -0.5, 0.8)), t((-1.02, -0.9, 0.72)), t((1.02, -0.9, 0.72)),
             t((-0.85, -0.5, -0.78)), t((0.85, -0.5, -0.78)), t((-0.78, -0.84, -0.7)), t((0.78, -0.84, -0.7))], bevel=0.14, seg=2)   # breastplate
    nv.box((1.5, 0.3, 0.3), t((0, -0.7, -0.66)), bevel=0.08, seg=1)                                # belt plate
    nv.box((1.26, 0.2, 0.7), t((0, -0.92, -0.05)), bevel=0.06, seg=1)                              # sternum panel
    og.hull([t((-0.7, -0.93, 0.5)), t((0, -0.93, 0.05)), t((0.7, -0.93, 0.5)), t((0.7, -0.93, 0.3)), t((0, -0.93, -0.25)), t((-0.7, -0.93, 0.3)),
             t((-0.7, -0.99, 0.5)), t((0, -0.99, 0.05)), t((0.7, -0.99, 0.5)), t((0.7, -0.99, 0.3)), t((0, -0.99, -0.25)), t((-0.7, -0.99, 0.3))], bevel=0.0, seg=1)   # chevron
    wh.box((2.15, 0.92, 0.32), t((0, 0.0, 0.7)), bevel=0.12, seg=2)                                # shoulder yoke
    nv.cyl(0.78, 0.2, t((0, 0, 0.9)), verts=18, bevel=0.05, seg=1)                                 # collar
    for s in (-1, 1):
        nv.box((0.14, 1.0, 1.3), t((s * 1.04, -0.05, -0.05)), bevel=0.05, seg=1)                   # side straps
        og.box((0.3, 0.3, 0.3), t((s * 0.72, -0.78, -0.42)), bevel=0.06, seg=1)                    # ammo pouches
        nv.box((0.4, 0.34, 0.42), t((s * 0.72, -0.82, -0.2)), bevel=0.06, seg=1)
    wsh.hull([t((-0.95, 0.5, 0.75)), t((0.95, 0.5, 0.75)), t((-0.8, 0.62, 0.65)), t((0.8, 0.62, 0.65)),
              t((-0.8, 0.5, -0.75)), t((0.8, 0.5, -0.75)), t((-0.7, 0.62, -0.7)), t((0.7, 0.62, -0.7))], bevel=0.1, seg=1)   # back plate
    og.box((0.18, 0.1, 1.2), t((0, 0.66, 0.0)), bevel=0.03, seg=1)                                  # spine stripe

    # ---------------- Backpack (origin = UpperTorso back surface, BodyBackAttachment) ----------------
    a.limb("Backpack", "armor", None, pivot=BACK)
    b = lambda p: P(BACK, p)
    nv.box((1.5, 0.8, 1.5), b((0, 0.7, 0.0)), bevel=0.16, seg=2)
    wh.box((1.56, 0.86, 0.34), b((0, 0.7, 0.72)), bevel=0.12, seg=2)                                # cap
    wh.box((1.16, 0.12, 0.7), b((0, 1.14, 0.1)), bevel=0.04, seg=1)                                  # service hatch
    og.box((1.2, 0.14, 0.16), b((0, 1.14, 0.1)), bevel=0.04, seg=1)
    for s in (-1, 1):
        og.cyl(0.26, 1.15, b((s * 0.9, 0.55, 0.0)), verts=14, bevel=0.06, seg=1)                    # fuel tanks (sides)
        nv.cyl(0.27, 0.14, b((s * 0.9, 0.55, 0.6)), verts=14, bevel=0.03, seg=1)
        nv.cyl(0.38, 0.5, b((s * 0.45, 0.7, -0.95)), r2=0.3, verts=14, bevel=0.06, seg=1)           # thruster housings
        mt.cyl(0.26, 0.2, b((s * 0.45, 0.7, -1.28)), verts=12, bevel=0.03, seg=1)
    stl.tube(b((-0.5, 1.0, 0.85)), b((-0.5, 1.2, 1.5)), 0.04, verts=6, bevel=0)

    # glow objects: thrusters + visor
    for s in (1, -1):
        c = b((s * 0.45, 0.7, -1.4))
        g = a.glow("Thruster_%s" % ("L" if s > 0 else "R"), CYAN, "glow", "Backpack", pivot=c)
        g.cyl(0.22, 0.1, c, verts=14, bevel=0.02, seg=1)

    # ---------------- Pauldrons (origin = Upper arm centre) ----------------
    for s, n in ((1, "L"), (-1, "R")):
        C = (s * 1.5, 0, 3.9)
        a.limb("Pauldron_" + n, "armor", None, pivot=C)
        q = lambda p, C=C, s=s: (C[0] + s * p[0], C[1] + p[1], C[2] + p[2])
        wh.hull([q(p) for p in [(-0.55, -0.68, 0.3), (0.62, -0.68, 0.3), (-0.55, 0.68, 0.3), (0.62, 0.68, 0.3),
                                (-0.4, -0.56, 0.62), (0.4, -0.56, 0.62), (-0.4, 0.56, 0.62), (0.4, 0.56, 0.62),
                                (0.72, -0.5, -0.05), (0.72, 0.5, -0.05)]], bevel=0.17, seg=3)                  # shell
        nv.box((1.2, 1.12, 0.18), q((0.04, 0, 0.27)), bevel=0.06, seg=1)                                  # rim
        og.box((0.26, 1.24, 0.12), q((0.38, 0, 0.5)), bevel=0.03, seg=1)                                  # stripe
        wh.box((0.14, 0.9, 0.9), q((0.6, 0, -0.1)), bevel=0.06, seg=1)                                # outer cheek plate
        nv.box((0.22, 0.6, 0.2), q((0.2, 0, 0.7)), rot=(0, s * 20, 0), bevel=0.05, seg=1)
        for k in (-1, 1):
            nv.cyl(0.08, 0.1, q((0.6, k * 0.3, 0.25)), rot=(0, 90, 0), verts=8, bevel=0, seg=1)

    # ---------------- Shins (origin = LowerLeg centre) ----------------
    for s, n in ((1, "L"), (-1, "R")):
        C = (s * 0.5, 0, 0.85)
        a.limb("Shin_" + n, "armor", None, pivot=C)
        q = lambda p, C=C: (C[0] + p[0], C[1] + p[1], C[2] + p[2])
        wh.hull([q((-0.52, -0.5, 0.52)), q((0.52, -0.5, 0.52)), q((-0.48, -0.74, 0.44)), q((0.48, -0.74, 0.44)),
                 q((-0.45, -0.5, -0.4)), q((0.45, -0.5, -0.4)), q((-0.42, -0.68, -0.34)), q((0.42, -0.68, -0.34))], bevel=0.1, seg=2)
        wh.box((0.14, 0.8, 0.8), q((-0.56, -0.2, 0.1)), bevel=0.05, seg=1)
        wh.box((0.14, 0.8, 0.8), q((0.56, -0.2, 0.1)), bevel=0.05, seg=1)
        nv.box((1.14, 1.14, 0.24), q((0, 0, -0.5)), bevel=0.08, seg=1)                                # boot cuff
        nv.box((1.1, 1.1, 0.16), q((0, 0, 0.58)), bevel=0.06, seg=1)                                  # top band
        og.box((0.7, 0.2, 0.3), q((0, -0.72, 0.2)), rot=(-12, 0, 0), bevel=0.05, seg=1)               # kneepad stripe
        nv.box((0.3, 0.1, 0.5), q((0, -0.8, -0.1)), bevel=0.03, seg=1)

    a.attach = {
        "Helmet": {"bodyPart": "Head", "attachment": "HatAttachment", "note": "origin = head centre; HatAttachment sits ~0.6 above it"},
        "Visor": {"bodyPart": "Head", "note": "weld to Helmet; glow"},
        "ChestPlate": {"bodyPart": "UpperTorso", "attachment": "BodyFrontAttachment", "note": "origin = UpperTorso centre"},
        "Backpack": {"bodyPart": "UpperTorso", "attachment": "BodyBackAttachment", "note": "origin = UpperTorso back surface"},
        "Thruster_L": {"bodyPart": "UpperTorso", "note": "weld to Backpack; glow"},
        "Thruster_R": {"bodyPart": "UpperTorso", "note": "weld to Backpack; glow"},
        "Pauldron_L": {"bodyPart": "LeftUpperArm", "attachment": "LeftShoulderAttachment", "note": "origin = LeftUpperArm centre"},
        "Pauldron_R": {"bodyPart": "RightUpperArm", "attachment": "RightShoulderAttachment", "note": "origin = RightUpperArm centre"},
        "Shin_L": {"bodyPart": "LeftLowerLeg", "note": "origin = LeftLowerLeg centre"},
        "Shin_R": {"bodyPart": "RightLowerLeg", "note": "origin = RightLowerLeg centre"},
    }
    a.build(ox, oy)
    return a


def main():
    kit.reset()
    cen = H.build_dummy()
    a = build()
    a.over(total=99999)
    for name, yaw in (("armor_kit_front", 0), ("armor_kit_back", 180)):
        kit.stage(target=(0, 0, 3.2), dist=14, height=2.2, yaw=yaw, lens=50, size=(800, 1000), floor=7, boost=0.9)
        kit.render(name)
        # restage cleanly for the second render
        for o in [o for o in bpy.data.objects if o.name.startswith("_") and o.type in ("CAMERA", "LIGHT")] + [bpy.data.objects.get("_Floor")]:
            if o:
                bpy.data.objects.remove(o)
    if "NOEXPORT" not in os.environ:
        dummy = {n: [round(-v.x, 3), round(v.z, 3), round(v.y, 3)] for n, v in cen.items()}
        a.write_manifest("armor_kit", dummy_part_centres_roblox=dummy,
                         notes="Fitted to an R15 dummy (never exported). Each part origin is the centre of the body part it welds to (Backpack: back surface).")
        a.export()


import bpy
if __name__ == "__main__":
    main()
