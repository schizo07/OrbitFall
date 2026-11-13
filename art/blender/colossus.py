import sys, os, math
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mathutils import Vector, Matrix
import kit
from kit import Part, GUNMETAL, DARK, RUST, AMBER

VENT = (255, 105, 28)


def build(ox=0.0, oy=0.0):
    body = Part("Body", GUNMETAL, "Metal", "body")
    plates = Part("Plates", RUST, "SmoothPlastic", "trim")
    dark = Part("Dark", DARK, "SmoothPlastic", "trim")
    core = Part("Core", VENT, "Neon", "weak")
    joints = {}
    names = {(-1, -1): "Joint_1", (1, -1): "Joint_2", (-1, 1): "Joint_3", (1, 1): "Joint_4"}
    for k, n in names.items():
        joints[k] = Part(n, AMBER, "Neon", "weak")

    # ---- hull (big armoured foundry box)
    zb, zt = 12.4, 19.0
    body.hull([(-6.8, -7.6, zb), (6.8, -7.6, zb), (-6.8, 8.2, zb), (6.8, 8.2, zb),
               (-6.0, -6.9, zt), (6.0, -6.9, zt), (-6.0, 7.6, zt), (6.0, 7.6, zt)], bevel=1.0, seg=3)
    dark.box((10.0, 12.0, 1.0), (0, 0.3, 12.1), bevel=0.3, seg=1)                         # belly plate

    # front glacis plate (orange, riveted)
    def fy(z):
        return -7.6 + 0.7 * (z - zb) / (zt - zb)
    pz0, pz1, hw = 13.4, 18.2, 5.6
    d = 0.7
    plates.hull([(-hw, fy(pz0) - d, pz0), (hw, fy(pz0) - d, pz0), (-hw, fy(pz1) - d, pz1), (hw, fy(pz1) - d, pz1),
                 (-hw, fy(pz0) + 0.3, pz0), (hw, fy(pz0) + 0.3, pz0), (-hw, fy(pz1) + 0.3, pz1), (hw, fy(pz1) + 0.3, pz1)],
                bevel=0.35, seg=2)
    pts = [(x, fy(z) - d, z) for z in (14.2, 17.4) for x in (-4.2, -1.4, 1.4, 4.2)]
    plates.rivets(pts, r=0.32, normal=(0, -1, 0.08))
    dark.gear(2.0, 1.6, 12, 0.4, (0, fy(15.8) - d - 0.1, 15.8), rot=(90, 0, 0), bevel=0)
    dark.cyl(0.7, 0.6, (0, fy(15.8) - d - 0.2, 15.8), rot=(90, 0, 0), verts=10, bevel=0)

    # side armour panels + cog emblems
    for sx in (-1, 1):
        plates.box((0.7, 11.0, 4.0), (sx * 6.4, 0.3, 16.0), rot=(0, -sx * 5.5, 0), bevel=0.25, seg=2)
        for yy in (-4.2, -1.4, 1.4, 4.2):
            plates.rivets([(sx * 6.8, yy, 14.3), (sx * 6.8, yy, 17.7)], r=0.28, normal=(sx, 0, 0.1))
        dark.gear(2.2, 1.8, 12, 0.4, (sx * 6.95, 0.3, 16.0), rot=(0, 90, 0), bevel=0)
        dark.cyl(0.7, 0.6, (sx * 7.05, 0.3, 16.0), rot=(0, 90, 0), verts=10, bevel=0)

    # cab on the deck + dark viewport slits (not glowing)
    body.box((8.0, 6.8, 2.8), (0, -1.6, 20.2), bevel=0.65, seg=3, taper=(0.88, 0.9))
    dark.box((6.0, 0.5, 0.8), (0, -4.7, 20.4), bevel=0.15, seg=2)
    plates.box((5.6, 0.4, 0.5), (0, -4.85, 19.5), bevel=0.12, seg=2)
    plates.box((6.0, 3.6, 0.4), (0, -1.2, 21.7), bevel=0.15, seg=2)                      # roof hatch
    # chimneys
    for sx in (-1, 1):
        dark.cyl(0.95, 3.4, (sx * 3.0, 4.6, 20.6), r2=1.1, verts=12, bevel=0.1)
        plates.cyl(1.3, 0.4, (sx * 3.0, 4.6, 22.35), verts=12, bevel=0.1)

    # ---- rear reactor vent (weak spot) with heat-sink fins
    dark.box((8.0, 1.0, 4.2), (0, 8.1, 16.0), bevel=0.3, seg=2)                         # housing frame
    core.box((6.6, 0.6, 2.9), (0, 8.65, 16.0), bevel=0.25, seg=2)                         # glowing vent
    for i in range(4):
        dark.box((6.8, 0.45, 0.22), (0, 9.05, 15.0 + i * 0.7), bevel=0.04, seg=1)        # louvres over the glow
    for i in range(9):                                                                   # heat-sink fins above
        dark.box((0.35, 1.8, 2.2), (-4.0 + i * 1.0, 8.5, 18.1), bevel=0.05, seg=1)
    for sx in (-1, 1):
        for i in range(4):                                                               # side fin banks on deck
            dark.box((0.3, 2.6, 1.3), (sx * 4.1 + sx * 0.0, 3.0 - i * 1.0 - 4.0 * 0 + 0.0, 19.9), bevel=0.04, seg=1)
    plates.gear(2.2, 1.8, 12, 0.45, (0, 7.8, 13.9), rot=(90, 0, 0), bevel=0.06) if False else None

    # ---- four walking legs, glowing knees
    for (sx, sy), jp in joints.items():
        hip = Vector((sx * 5.2, sy * 5.8, 13.0))
        knee = Vector((sx * 8.3, sy * 8.9, 8.0))
        ankle = Vector((sx * 9.2, sy * 9.9, 1.7))
        ax = Vector((-sy, sx, 0)).normalized()         # hinge axis, perpendicular to the leg plane
        dark.ball(2.5, tuple(hip), segs=12)
        body.tube(tuple(hip), tuple(knee), 2.1, r2=1.9, verts=10, bevel=0.2)           # thigh
        body.tube(tuple(knee), tuple(ankle), 2.0, r2=1.6, verts=10, bevel=0.2)         # shin
        jp.ball(2.75, tuple(knee), segs=16)                                               # glowing knee
        dark.tube(tuple(knee - ax * 0.45), tuple(knee + ax * 0.45), 3.0, verts=14, bevel=0)   # equator band
        plates.tube(tuple(hip + (knee - hip) * 0.16), tuple(hip + (knee - hip) * 0.68), 2.5, r2=2.3, verts=10, bevel=0.15)  # thigh armour sleeve
        dark.cyl(2.1, 0.9, (ankle.x, ankle.y, 2.0), verts=12, bevel=0.1, seg=1)                # ankle
        body.box((5.8, 6.6, 1.5), (ankle.x, ankle.y + 0.2, 0.75), bevel=0.55, seg=3)        # foot pad
        plates.box((5.9, 1.7, 1.3), (ankle.x, ankle.y - 3.0, 0.7), bevel=0.5, seg=3)    # toe cap

    parts = [body, plates, dark, core] + [joints[k] for k in sorted(joints, key=lambda k: names[k])]
    for p in parts:
        ob = p.build()
        ob.location.x += ox
        ob.location.y += oy
    return parts


if __name__ == "__main__":
    kit.reset()
    parts = build()
    yaw = float(os.environ.get("YAW", -35))
    kit.stage(target=(0, 0, 10.5), dist=62, height=20, yaw=yaw, floor=40, lens=50)
    kit.render("colossus" if yaw == -35 else "_colossus_%d" % yaw)
    kit.write_manifest("colossus", parts)
    if yaw == -35:
        kit.export_fbx("colossus")
