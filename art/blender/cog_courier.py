"""Scrap Courier (LOOT_COG, key courier_cog) in the Cogwork "Foundry Clockwork" style (helper/COGWORK_STYLE.md, art/STYLE.md).

Replaces the Part-built wheeled cart in server/Enemies/EnemyModels.luau (buildLootCog: chassis, 2 wheels, caster, prow, glowing
gold crate at the rear, height ~3.5). A scuttling cargo bot: low gunmetal hull on four splayed gear-jointed legs, a Cog Eye
nose up front, and a big brass strongbox strapped on its back with gold glowing through the lid gap and side windows.
Front = -Y (Roblox -Z). No weapons. Lowest point at z = 0.
Zones (Data/Enemies LOOT_COG): body -> Body (+ the 4 legs), crate -> Crate (role weak, Neon gold, the glow inside the strongbox).
Glow = Cog Eye lens + ember stacks (red-orange, no zone). Leg_* pivot at the hip, parent Body (swing about X to scuttle).

Run headless:  Blender -b --factory-startup --python cog_courier.py -- <scratch root> [<image dir>]
"""
import json
import os
import sys
from math import radians

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
import bpy
from mathutils import Vector

KEY = "courier_cog"
HULL_Z = 1.85                      # hull centre height
HIP_Z = 1.7
LEGS = (("FL", 1, -1), ("FR", -1, -1), ("RL", 1, 1), ("RR", -1, 1))   # name, side (+x = L), front(-1) / rear(+1)
BOX_Y0, BOX_Y1, BOX_Z0, BOX_Z1 = -0.45, 1.55, 2.2, 3.3       # strongbox footprint (y range, z range)
GOLD = "ffc94a"
K = {}


def start():
    k = pl.Kit(KEY, palette="cogwork", category="regular", reset=True)
    P = {}
    P["Body"] = k.part("Body", "body", "Metal", pivot=(0, 0, HULL_Z), color="Gunmetal")
    P["Glow"] = k.glow("Glow", role="glow", pivot=(0, 0, HULL_Z), parent="Body")
    P["Crate"] = k.glow("Crate", rgb=GOLD, role="weak", pivot=(0, 0.55, 2.75), parent="Body")
    for n, s, f in LEGS:
        P[f"Leg_{n}"] = k.part(f"Leg_{n}", "limb", "Metal", pivot=(s * 1.2, f * 1.0, HIP_Z), parent="Body", color="Gunmetal")
    K.clear()
    K.update(kit=k, P=P)
    return k


def ring_y(y, hx, hz, c, zc):
    """Chamfered rectangle ring in an XZ plane at height zc (loft rings running along Y)."""
    pts = [(-hx + c, -hz), (hx - c, -hz), (hx, -hz + c), (hx, hz - c), (hx - c, hz), (-hx + c, hz), (-hx, hz - c), (-hx, -hz + c)]
    return [(x, y, zc + z) for x, z in pts]


def hull():
    b, g = K["P"]["Body"], K["P"]["Glow"]
    # low chamfered chassis, tapering to a blunt nose with the faction Cog Eye
    rings = [ring_y(-2.05, 0.55, 0.4, 0.16, HULL_Z), ring_y(-1.3, 1.0, 0.48, 0.22, HULL_Z),
             ring_y(1.0, 1.1, 0.48, 0.22, HULL_Z), ring_y(1.95, 0.95, 0.4, 0.2, HULL_Z)]
    pl.loft(b, rings, color="Gunmetal", bevel=0.05)
    pl.box(b, (1.5, 1.0, 0.16), (0, -0.3, 1.38), "Rust", bevel=0.03)                    # grimy belly skid
    pl.box(b, (0.9, 0.4, 0.08), (0, -1.9, HULL_Z - 0.46), "Grime", bevel=0)
    pl.cog_mark(b, g, (0, -2.07, HULL_Z), (0, -1, 0), r=0.3)
    # CogRed armour: top plate in front of the strongbox (gear cluster on its left third), side panels
    pl.riveted_plate(b, 1.6, 0.8, 0.12, (0, -1.38, HULL_Z + 0.5), (0, 0, 0), "CogRed", "Brass", spacing=0.42, chamfer=0.25)
    pl.gear_cluster(b, (-0.5, -1.4, HULL_Z + 0.56), (0, 0, 0), R=0.26, t=0.08)
    for s in (1, -1):
        pl.plate(b, 1.7, 0.5, 0.1, (s * 1.11, -0.2, HULL_Z + 0.05), (0, radians(s * 90), 0), "CogRed", chamfer=0.22)
        pl.bolt_row(b, (s * 1.16, -0.9, HULL_Z + 0.3), (s * 1.16, 0.5, HULL_Z + 0.3), 4, (s, 0, 0), 0.05, "Brass")
    # rear: twin ember stacks and a copper pipe from a small boiler stub up to the strongbox
    for s in (1, -1):
        pl.smokestack(b, (s * 0.85, 1.72, HULL_Z + 0.2), 0.16, 0.8, glow=g)
    pl.vent_grille(b, 0.8, 0.3, 3, (0, 1.94, HULL_Z - 0.05), (radians(-90), 0, 0), "GunmetalDark", "Soot", glow=g)
    pl.antenna(b, (0.9, 0.2, HULL_Z + 0.5), 0.8, color="Steel")


def strongbox():
    b, c = K["P"]["Body"], K["P"]["Crate"]
    y0, y1, z0, z1 = BOX_Y0, BOX_Y1, BOX_Z0, BOX_Z1
    yc, w = (y0 + y1) / 2, 2.0
    d = y1 - y0
    # cradle saddle on the hull, then the brass strongbox itself
    pl.box(b, (w + 0.2, d + 0.2, 0.18), (0, yc, z0 + 0.05), "GunmetalDark", bevel=0.04)
    pl.box(b, (w, d, z1 - z0 - 0.2), (0, yc, (z0 + 0.1 + z1) / 2), "Brass", bevel=0.05)
    # gunmetal corner straps + horizontal band
    for sx in (1, -1):
        for sy in (y0 + 0.12, y1 - 0.12):
            pl.box(b, (0.22, 0.22, z1 - z0 + 0.05), (sx * (w / 2 - 0.05), sy, (z0 + z1) / 2), "GunmetalDark", bevel=0.03)
    pl.box(b, (w + 0.14, d + 0.14, 0.16), (0, yc, z0 + 0.5), "GunmetalDark", bevel=0.03)
    # lid: raised on four posts, a gap all round shows the glowing gold; hinge gears at the back
    gap_z0, gap_z1 = z1 - 0.3, z1 - 0.02
    for sx in (1, -1):
        for sy in (y0 + 0.2, y1 - 0.2):
            pl.box(b, (0.2, 0.2, gap_z1 - gap_z0 + 0.02), (sx * (w / 2 - 0.1), sy, (gap_z0 + gap_z1) / 2), "GunmetalDark", bevel=0.02)
    pl.taper_box(b, (w + 0.15, d + 0.15), (w - 0.35, d - 0.35), z1 - 0.02, z1 + 0.32, "Brass", loc=(0, yc, 0), bevel=0.05)
    pl.box(b, (w + 0.2, 0.18, 0.1), (0, y0 - 0.02, z1 + 0.02), "GunmetalDark", bevel=0.02)
    for sx in (1, -1):
        pl.cog_joint(b, (sx * 0.75, y1 + 0.05, z1 + 0.1), (1, 0, 0), 0.3, 0.12, teeth=8)
    # front face: CogRed riveted plate + brass gear cluster (the lock), handwheel on the lid
    pl.riveted_plate(b, 1.5, 0.75, 0.1, (0, y0 - 0.06, (z0 + z1) / 2 - 0.1), (radians(90), 0, 0), "CogRed", "Bolt",
                     spacing=0.38, chamfer=0.2)
    pl.gear_cluster(b, (-0.35, y0 - 0.12, (z0 + z1) / 2 - 0.1), (radians(90), 0, 0), R=0.28, t=0.08)
    pl.handwheel(b, (0.0, yc, z1 + 0.35), (0, 0, 1), 0.38, color="Brass")
    # gold glowing through the gap (a slab inside the lid posts) and side windows with brass bars
    pl.box(c, (w + 0.04, d + 0.04, gap_z1 - gap_z0 - 0.04), (0, yc, (gap_z0 + gap_z1) / 2), bevel=0)
    zc, hh = z0 + 0.8, 0.7
    for sx in (1, -1):                      # side windows: gunmetal frame, recessed gold slab, brass bars over it
        x, L = sx * w / 2, d - 0.5
        for zz in (zc + hh / 2 + 0.06, zc - hh / 2 - 0.06):
            pl.box(b, (0.14, L, 0.12), (x + sx * 0.04, yc, zz), "GunmetalDark", bevel=0)
        for oy in (-L / 2, L / 2):
            pl.box(b, (0.14, 0.12, hh + 0.24), (x + sx * 0.04, yc + oy, zc), "GunmetalDark", bevel=0)
        pl.box(c, (0.06, L - 0.1, hh), (x, yc, zc), bevel=0)
        for oy in (-0.45, 0.0, 0.45):
            pl.box(b, (0.1, 0.07, hh), (x + sx * 0.05, yc + oy, zc), "Brass", bevel=0)
    # rear window (so the gold reads from behind): same build on the back face
    Lw = w - 0.8
    for zz in (zc + hh / 2 + 0.06, zc - hh / 2 - 0.06):
        pl.box(b, (Lw, 0.14, 0.12), (0, y1 + 0.04, zz), "GunmetalDark", bevel=0)
    for ox in (-Lw / 2, Lw / 2):
        pl.box(b, (0.12, 0.14, hh + 0.24), (ox, y1 + 0.04, zc), "GunmetalDark", bevel=0)
    pl.box(c, (Lw - 0.1, 0.06, hh), (0, y1, zc), bevel=0)
    for ox in (-0.4, 0.0, 0.4):
        pl.box(b, (0.07, 0.1, hh), (ox, y1 + 0.05, zc), "Brass", bevel=0)


def leg(name, s, f):
    p = K["P"][f"Leg_{name}"]
    hip = Vector((s * 1.2, f * 1.0, HIP_Z))
    knee = Vector((s * 1.7, f * 1.4, 1.25))
    foot = Vector((s * 1.55, f * 1.65, 0.16))
    pl.cog_joint(p, hip, (1, 0, 0), 0.36, 0.2, teeth=8)                                 # hip gear (outer face)
    pl.rod(p, hip, knee, 0.2, "Gunmetal", segs=6)                                       # thigh
    pl.cog_joint(p, knee, (1, 0, 0), 0.3, 0.18, teeth=8)                                # knee gear
    pl.rod(p, knee, foot + Vector((0, 0, 0.2)), 0.16, "GunmetalDark", segs=6)           # shin
    pl.box(p, (0.5, 0.7, 0.18), foot - Vector((0, f * 0.05, 0.07)) + Vector((0, 0, 0.16)), "Rust", bevel=0.03)   # foot pad
    pl.box(p, (0.56, 0.76, 0.06), (foot.x, foot.y - f * 0.05, 0.03), "Grime", bevel=0)


def build_all():
    start()
    hull()
    strongbox()
    for n, s, f in LEGS:
        leg(n, s, f)
    k = K["kit"]
    k.ground()
    return k


def finish():
    k = K["kit"]
    k.build()
    k.report()
    return k


def export(root):
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'  # 1 BU = 1 stud in Roblox
    k = K["kit"]
    k.export_fbx()
    return k.manifest_entry()


def _relink_palette(k):
    img = bpy.data.images.get(f"palette_{k.palette_name}")
    k.image = img
    for p in k.parts:
        for n in p.obj.data.materials[0].node_tree.nodes:
            if n.type == 'TEX_IMAGE':
                n.image = img


def main():
    args = pl._argv()
    root = args[0] if args else "/private/tmp/orbitfall-gnat-courier"
    img_dir = args[1] if len(args) > 1 else root
    os.makedirs(root, exist_ok=True)
    k = build_all()
    finish()
    entry = export(root)
    with open(os.path.join(root, f"{KEY}.entry.json"), "w") as f:
        json.dump(entry, f, indent=2)
    print("ENTRY size", entry["size_studs_roblox_xyz"], "weak", entry["weak_spots"])
    for p in entry["parts"]:
        print("PART", p["name"], p["role"], p["parent"], p["pivot"], p["triangles"])
    lo, hi = k.bbox()
    print("BBOX", [round(v, 2) for v in lo], [round(v, 2) for v in hi])
    import env_set1
    _relink_palette(k)
    for name, d in (("front", (0.45, -1.0, 0.4)), ("back", (-0.5, 1.0, 0.45))):
        env_set1.stage(os.path.join(img_dir, f"{KEY}_{name}.png"), [k], size=(900, 900), cam_dir=d)


if __name__ == "__main__":
    main()
