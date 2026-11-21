"""Hostile Cogwork Heavy Drop Pod (key cog_drop_pod) in Orbitfall's "Foundry Clockwork" style.

Heavy chamfered gunmetal breach capsule built from bolted plates around a hollow front
deploy bay, with a separate hinged front blast door that lowers into an assault ramp,
CogRed riveted armour panels, offset brass gear clusters, rear steam boiler and copper
pipes, twin flared smokestacks, ground-anchor impact claws, and a caged top beacon.

Origin = base centre on the ground (z = 0), front blast door facing -Y (Roblox -Z).
Parts: Body (Metal), Door (Metal, parent Body), Glow (Neon, parent Body),
       DoorGlow (Neon, parent Door).

Headless:
  Blender -b --python art/blender/cog_drop_pod.py -- --out . --export --preview
"""
import os
import shutil
import sys
from math import cos, radians, sin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
from mathutils import Euler, Vector

KEY = "cog_drop_pod"

# Core dimensions (1 Blender unit = 1 stud)
HX = 2.85          # main hull half-width
HY = 2.85          # main hull half-depth
CH = 1.05          # 45-degree corner chamfer size
BAY_X = 1.80       # inner deploy bay half-width (3.60 studs clear)
BAY_Y_BACK = 1.55  # inner rear bulkhead Y
Z_BASE = 0.70      # deploy bay floor top / plinth height
Z_WALL_TOP = 8.45  # top of main octagonal hull walls
Z_BAY_TOP = 7.68   # deploy bay ceiling height

DOOR_HINGE = (0.0, -2.96, 0.66)
DOOR_W = 3.74
DOOR_H = 7.04
DOOR_T = 0.28


def facing(n, up=(0, 0, 1)):
    """Euler for a local-XY plate whose +Z faces normal n."""
    n = Vector(n).normalized()
    u = Vector(up)
    x = u.cross(n)
    if x.length < 1e-4:
        x = Vector((1, 0, 0))
    return pl.basis(x, n)


def extrude_z(part, poly_xy, z0, z1, color, bevel=0.0):
    """Extrude a 2D XY polygon cleanly from z0 to z1."""
    return pl.extrude(part, poly_xy, z1 - z0, (0.0, 0.0, (z0 + z1) / 2.0),
                      color=color, plane='XY', bevel=bevel)


def recessed_furnace_grate(b, g, w, h, bars, loc, normal, depth=0.22):
    """Low-tri recessed furnace grate with hot Neon backing behind horizontal bars."""
    rot = facing(normal)
    f = pl.frame(loc, rot)
    fw = min(w, h) * 0.11
    for x, y, sx, sy in ((0, h / 2 - fw / 2, w, fw), (0, -h / 2 + fw / 2, w, fw),
                         (w / 2 - fw / 2, 0, fw, h), (-w / 2 + fw / 2, 0, fw, h)):
        pl.box(b, (sx, sy, depth), f((x, y, 0)), "GunmetalDark", rot, bevel=0.0)
    inner_w = w - 2 * fw
    inner_h = h - 2 * fw
    # Dark soot recess wall + recessed glowing furnace core
    pl.box(b, (inner_w, inner_h, depth * 0.25), f((0, 0, -depth * 0.38)), "Soot", rot, bevel=0.0)
    pl.box(g, (inner_w * 0.90, inner_h * 0.90, depth * 0.12), f((0, 0, -depth * 0.20)), rot=rot, bevel=0.0)
    # Protective iron grate bars across the front of the recessed furnace
    for i in range(bars):
        y = -inner_h / 2 + inner_h * (i + 0.5) / bars
        pl.box(b, (inner_w, inner_h / bars * 0.28, depth * 0.45), f((0, y, depth * 0.18)),
               "Gunmetal", rot, bevel=0.0)


def build_hull_and_bay(b, g):
    """Base impact plinth, hollow octagonal hull walls, top collar, and dark deploy bay."""
    # Bottom impact keel plate resting solidly on z = 0
    extrude_z(b, pl.chamfer_rect(2.45, 2.45, 0.90), 0.0, 0.18, "RustDark", bevel=0.0)

    # Heavy lower impact plinth / skirt (z = 0.14 .. 0.72)
    pl.loft(b, [
        pl.chamfer_rect(2.68, 2.68, 1.00, z=0.14),
        pl.chamfer_rect(2.94, 2.94, 1.08, z=0.72),
    ], color="GunmetalDark", bevel=0.05)

    # Lower exterior rust bumper band along the bottom skirt
    pl.loft(b, [
        pl.chamfer_rect(2.98, 2.98, 1.10, z=0.38),
        pl.chamfer_rect(3.00, 3.00, 1.11, z=0.62),
    ], color="Rust", bevel=0.0)

    # Hollow octagonal main walls (three convex extruded slabs, flush outer octagon)
    z0, z1 = Z_BASE - 0.04, Z_WALL_TOP
    left_poly = [(-HX, -HY + CH), (-BAY_X, -HY), (-BAY_X, BAY_Y_BACK + 0.04), (-HX, BAY_Y_BACK + 0.04)]
    extrude_z(b, left_poly, z0, z1, "Gunmetal", bevel=0.05)

    right_poly = [(BAY_X, -HY), (HX, -HY + CH), (HX, BAY_Y_BACK + 0.04), (BAY_X, BAY_Y_BACK + 0.04)]
    extrude_z(b, right_poly, z0, z1, "Gunmetal", bevel=0.05)

    rear_poly = [
        (-HX, BAY_Y_BACK), (HX, BAY_Y_BACK),
        (HX, HY - CH), (HX - CH, HY),
        (-HX + CH, HY), (-HX, HY - CH),
    ]
    extrude_z(b, rear_poly, z0, z1, "Gunmetal", bevel=0.05)

    # Upper ceiling slab closing the top of the deploy bay
    extrude_z(b, pl.chamfer_rect(HX, HY, CH), Z_BAY_TOP, Z_WALL_TOP + 0.08, "Gunmetal", bevel=0.05)

    # Heavy upper bolted structural collar wrapping the top of the main torso
    pl.loft(b, [
        pl.chamfer_rect(HX + 0.18, HY + 0.18, CH + 0.07, z=7.74),
        pl.chamfer_rect(HX + 0.18, HY + 0.18, CH + 0.07, z=8.52),
    ], color="GunmetalDark", bevel=0.05)

    # Brass perimeter bolts around the upper collar (skip centre front where visor sits)
    for x_off in (-1.40, 1.40):
        pl.bolt(b, (x_off, -HY - 0.18, 8.15), (0, -1, 0), r=0.11, color="Brass", segs=4)
    for x_off in (-1.20, 0.0, 1.20):
        pl.bolt(b, (x_off, HY + 0.18, 8.15), (0, 1, 0), r=0.11, color="Brass", segs=4)
    for y_off in (-1.20, 0.0, 1.20):
        pl.bolt(b, (-HX - 0.18, y_off, 8.15), (-1, 0, 0), r=0.11, color="Brass", segs=4)
        pl.bolt(b, (HX + 0.18, y_off, 8.15), (1, 0, 0), r=0.11, color="Brass", segs=4)

    # Front armoured doorway frame pillars & upper slam-latch lock lugs
    for s in (-1, 1):
        pl.box(b, (0.30, 0.36, Z_BAY_TOP - Z_BASE + 0.16),
               (s * (BAY_X + 0.10), -HY - 0.06, (Z_BASE + Z_BAY_TOP) / 2.0),
               "GunmetalDark", bevel=0.03)
        pl.box(b, (0.48, 0.44, 0.56), (s * 1.48, -HY - 0.22, 7.82), "GunmetalDark", bevel=0.0)
        pl.cyl(b, 0.12, 0.36, (s * 1.48, -HY - 0.38, 7.62), "Brass", segs=6, bevel=0.0)

    # Recessed twin warning visor slot on the upper front brow (above the door)
    pl.visor_slot(b, g, 1.75, 0.36, (0.0, -HY - 0.17, 8.15),
                  normal=(0, -1, 0), depth=0.22, lenses=2,
                  color="Soot", frame_color="Gunmetal")

    # ---- Recessed Dark Deploy Bay Interior ----
    pl.box(b, (BAY_X * 2.0 - 0.04, BAY_Y_BACK + HY - 0.25, 0.08),
           (0.0, (BAY_Y_BACK - HY) / 2.0 + 0.12, Z_BASE + 0.03), "Grime", bevel=0.0)
    for y_rib in (-2.05, -1.35, -0.65, 0.05, 0.75):
        pl.box(b, (BAY_X * 1.72, 0.16, 0.08), (0.0, y_rib, Z_BASE + 0.09), "GunmetalDark", bevel=0.0)
    pl.hazard_stripes(b, BAY_X * 1.92, 0.42, (0.0, -HY + 0.24, Z_BASE + 0.06),
                      rot=(0, 0, 0), stripes=5, c1="Hazard", c2="Oil", t=0.04)

    # Dark Soot interior wall linings + vertical structural bulkhead ribs
    pl.box(b, (BAY_X * 1.96, 0.10, Z_BAY_TOP - Z_BASE - 0.12),
           (0.0, BAY_Y_BACK - 0.04, (Z_BASE + Z_BAY_TOP) / 2.0), "Soot", bevel=0.0)
    for s in (-1, 1):
        pl.box(b, (0.10, BAY_Y_BACK + HY - 0.20, Z_BAY_TOP - Z_BASE - 0.12),
               (s * (BAY_X - 0.04), (BAY_Y_BACK - HY) / 2.0 + 0.08, (Z_BASE + Z_BAY_TOP) / 2.0),
               "Soot", bevel=0.0)
        for y_rib in (-1.75, -0.35, 0.90):
            pl.box(b, (0.20, 0.22, Z_BAY_TOP - Z_BASE - 0.20),
                   (s * (BAY_X - 0.12), y_rib, (Z_BASE + Z_BAY_TOP) / 2.0),
                   "GunmetalDark", bevel=0.0)
        # Recessed vertical furnace/heat vent strip on each interior side wall
        recessed_furnace_grate(b, g, 0.85, 2.75, 4, (s * (BAY_X - 0.18), -1.05, 4.10),
                               normal=(-s, 0, 0), depth=0.16)
        # Interior vertical copper steam conduit running down the back corner
        pl.rod(b, (s * (BAY_X - 0.26), BAY_Y_BACK - 0.26, Z_BASE + 0.25),
               (s * (BAY_X - 0.26), BAY_Y_BACK - 0.26, Z_BAY_TOP - 0.25),
               0.10, "Copper", segs=6, bevel=0.0)

    # Interior rear bulkhead: recessed glowing furnace grate + overhead restraint yoke
    recessed_furnace_grate(b, g, 2.40, 2.80, 4, (0.0, BAY_Y_BACK - 0.22, 4.25),
                           normal=(0, -1, 0), depth=0.24)
    pl.box(b, (2.60, 0.38, 0.30), (0.0, 0.45, Z_BAY_TOP - 0.24), "GunmetalDark", bevel=0.0)
    for s in (-1, 1):
        pl.box(b, (0.26, 1.30, 0.24), (s * 0.92, 0.25, Z_BAY_TOP - 0.48), "Rust", bevel=0.0)

    # Stationary hinge knuckles + prominent brass cog_joint gears at bottom-front corners
    hy, hz = DOOR_HINGE[1], DOOR_HINGE[2]
    for s in (-1, 1):
        pl.box(b, (0.48, 0.68, 0.68), (s * 2.08, hy + 0.20, hz + 0.04), "GunmetalDark", bevel=0.04)
        pl.cog_joint(b, (s * 2.18, hy, hz), (1, 0, 0), r=0.52, w=0.28, color="Brass",
                     cap="GunmetalDark", teeth=10)


def build_door(door, door_glow):
    """Separate hinged Front Blast Door that lowers forward into an assault ramp."""
    hy, hz = DOOR_HINGE[1], DOOR_HINGE[2]
    yc = hy - 0.02                      # centre plane of door slab
    zc = hz + DOOR_H / 2.0 + 0.04       # vertical centre of closed door

    # Main heavy door armour slab
    pl.box(door, (DOOR_W, DOOR_T, DOOR_H), (0.0, yc, zc), "GunmetalDark", bevel=0.05)

    # Bottom hinge axle barrel spanning the hinge axis + brass hinge knuckles
    pl.cyl(door, 0.20, DOOR_W + 0.24, (0.0, hy, hz), "GunmetalDark", pl.AX_X, segs=8, bevel=0.0)
    for x_kn in (-1.35, 0.0, 1.35):
        pl.cyl(door, 0.28, 0.46, (x_kn, hy, hz), "Brass", pl.AX_X, segs=8, bevel=0.0)

    # ---- Outer Blast Face (-Y when closed) ----
    y_out = yc - DOOR_T / 2.0
    rot_front = facing((0, -1, 0))

    # Upper & lower CogRed riveted armour plates with horizontal blast seam
    pl.riveted_plate(door, 3.16, 2.48, 0.16, (0.0, y_out - 0.07, hz + 5.38),
                     rot_front, "CogRed", "Brass", spacing=1.25, rivet_r=0.085,
                     chamfer=0.14, rivet_segs=4, bevel=0.0)
    pl.riveted_plate(door, 3.16, 2.48, 0.16, (0.0, y_out - 0.07, hz + 2.48),
                     rot_front, "CogRed", "Brass", spacing=1.25, rivet_r=0.085,
                     chamfer=0.14, rivet_segs=4, bevel=0.0)

    # Horizontal seam crossbar & heavy locking bolts across the door waist
    pl.box(door, (DOOR_W + 0.08, 0.22, 0.36), (0.0, y_out - 0.08, hz + 3.93), "Gunmetal", bevel=0.0)
    for s in (-1, 1):
        pl.box(door, (0.44, 0.28, 0.62), (s * 1.62, y_out - 0.10, hz + 3.93), "GunmetalDark", bevel=0.0)
        pl.box(door, (0.42, 0.18, 0.22), (s * 1.88, y_out - 0.06, hz + 3.93), "Brass", bevel=0.0)
        pl.box(door, (0.36, 0.26, 0.72), (s * 1.48, y_out - 0.10, hz + 6.45), "Gunmetal", bevel=0.0)
        pl.bolt(door, (s * 1.48, y_out - 0.23, hz + 6.55), (0, -1, 0), r=0.09, color="Brass", segs=4)

    # Central Faction Mark (brass gear + recessed glowing red Cog Eye in DoorGlow)
    pl.cog_mark(door, door_glow, (0.0, y_out - 0.16, hz + 3.93),
                normal=(0, -1, 0), r=0.92, color="Brass", rim="GunmetalDark")

    # Lower exterior hazard warning stripe band
    pl.hazard_stripes(door, 3.12, 0.56, (0.0, y_out - 0.04, hz + 0.68),
                      rot=rot_front, stripes=5, c1="Hazard", c2="Oil", t=0.06)

    # Top heavy rust breach bumper lip (takes impact when slamming open onto ground)
    pl.box(door, (DOOR_W - 0.12, 0.34, 0.30), (0.0, yc - 0.04, hz + DOOR_H - 0.05), "Rust", bevel=0.04)

    # ---- Inner Assault Ramp Face (+Y when closed, faces UP when lowered!) ----
    y_in = yc + DOOR_T / 2.0
    for s in (-1, 1):
        pl.box(door, (0.24, 0.16, DOOR_H - 0.36), (s * (DOOR_W / 2.0 - 0.18), y_in + 0.07, zc),
               "Gunmetal", bevel=0.0)
        pl.box(door, (0.10, 0.06, DOOR_H - 0.50), (s * (DOOR_W / 2.0 - 0.18), y_in + 0.16, zc),
               "Brass", bevel=0.0)
    pl.box(door, (DOOR_W - 0.60, 0.06, DOOR_H - 0.48), (0.0, y_in + 0.02, zc), "Soot", bevel=0.0)
    for i in range(9):
        zt = hz + 0.62 + i * 0.72
        pl.box(door, (DOOR_W - 0.82, 0.12, 0.20), (0.0, y_in + 0.08, zt), "Steel", bevel=0.0)
    pl.box(door, (0.22, 0.10, DOOR_H - 0.56), (0.0, y_in + 0.06, zc), "GunmetalDark", bevel=0.0)


def build_nose_and_beacon(b, g):
    """Top-heavy chamfered armoured impact cowl, toothed crown gear, vanes, and caged beacon."""
    # Main stepped chamfered impact nose (z = 8.48 .. 10.68)
    pl.loft(b, [
        pl.chamfer_rect(2.86, 2.86, 1.06, z=8.48),
        pl.chamfer_rect(2.42, 2.42, 0.90, z=9.40),
        pl.chamfer_rect(1.86, 1.86, 0.70, z=10.68),
    ], color="Gunmetal", bevel=0.05)

    # CogRed armoured collar band wrapped around the mid-cowl
    pl.loft(b, [
        pl.chamfer_rect(2.68, 2.68, 1.00, z=8.98),
        pl.chamfer_rect(2.40, 2.40, 0.90, z=9.62),
    ], color="CogRed", bevel=0.0)

    # Toothed brass crown gear collar cleanly proud around the upper cap shelf (Cog rule 3)
    pl.gear(b, 2.08, 1.84, 14, 0.30, (0.0, 0.0, 10.74), "Brass")

    # Upper octagonal armoured cap plate nested cleanly inside the brass crown gear
    pl.loft(b, [
        pl.chamfer_rect(1.66, 1.66, 0.62, z=10.68),
        pl.chamfer_rect(1.38, 1.38, 0.52, z=11.24),
    ], color="GunmetalDark", bevel=0.04)

    # Recessed Top Warning Beacon inside an armoured roll-cage (z = 11.24 .. 12.32)
    pl.cyl(b, 0.76, 0.24, (0.0, 0.0, 11.34), "Gunmetal", segs=8, bevel=0.0)
    pl.cyl(b, 0.56, 0.12, (0.0, 0.0, 11.46), "Brass", segs=8, bevel=0.0)
    pl.cyl(g, 0.42, 0.52, (0.0, 0.0, 11.74), segs=8, bevel=0.0)
    pl.cyl(b, 0.68, 0.22, (0.0, 0.0, 12.08), "CogRed", segs=8, bevel=0.0)
    pl.cyl(b, 0.42, 0.14, (0.0, 0.0, 12.24), "GunmetalDark", segs=8, bevel=0.0)
    for i in range(4):
        a = radians(45 + i * 90)
        px, py = cos(a) * 0.60, sin(a) * 0.60
        pl.rod(b, (px, py, 11.34), (px * 0.94, py * 0.94, 12.10), 0.085, "GunmetalDark", segs=5)

    # Four chunky corner re-entry drag vanes on brass cog_joint pivots (z = 9.05)
    for sx in (-1, 1):
        for sy in (-1, 1):
            d = Vector((sx, sy, 0)).normalized()
            ang = radians(45 if (sx > 0 and sy > 0) else 135 if (sx < 0 and sy > 0)
                          else 225 if (sx < 0 and sy < 0) else 315)
            p_base = d * 3.12 + Vector((0, 0, 9.10))
            pl.box(b, (0.54, 0.54, 0.44), d * 2.92 + Vector((0, 0, 9.06)),
                   "GunmetalDark", rot=(0, 0, ang), bevel=0.0)
            tangent = Vector((-d.y, d.x, 0))
            pl.cog_joint(b, p_base, tangent, r=0.32, w=0.34, color="Brass",
                         cap="GunmetalDark", teeth=8)
            rot_vane = Euler((0, radians(-18), ang)).to_matrix()
            p_vane = p_base + d * 0.64 + Vector((0, 0, 0.20))
            pl.box(b, (1.02, 0.86, 0.14), p_vane, "GunmetalDark", rot=rot_vane, bevel=0.0)
            pl.box(b, (0.76, 0.62, 0.18), p_vane, "Rust", rot=rot_vane, bevel=0.0)
            pl.box(b, (0.84, 0.14, 0.28), p_vane + Vector((0, 0, 0.10)), "Brass",
                   rot=rot_vane, bevel=0.0)


def build_flanks(b):
    """Side CogRed riveted armour panels, offset brass gear clusters, vents, and gauges."""
    for s in (-1, 1):
        rot_side = facing((s, 0, 0))
        # Large CogRed riveted armour slab bolted to each flank
        pl.riveted_plate(b, 3.15, 5.30, 0.22, (s * (HX + 0.08), 0.0, 4.55),
                         rot_side, "CogRed", "Brass", spacing=1.25, rivet_r=0.09,
                         chamfer=0.14, rivet_segs=4, bevel=0.0)

        for z_rib in (1.58, 7.52):
            pl.box(b, (0.28, 3.30, 0.34), (s * (HX + 0.08), 0.0, z_rib), "GunmetalDark", bevel=0.0)

        # Offset brass gear_cluster seated cleanly inside the CogRed plate (upper-front third)
        # Note: facing((+1,0,0)) has local +X along +Y; facing((-1,0,0)) has local +X along -Y.
        if s < 0:
            # Left flank (-X): big gear slightly toward rear (+Y), meshing forward & down (-Y, -Z)
            pl.gear_cluster(b, (s * (HX + 0.20), 0.32, 5.38), rot_side,
                            R=0.76, color="Brass", hub="CogRed", t=0.15, third=True, angle=-42.0)
        else:
            # Right flank (+X): big gear slightly toward front (-Y), meshing rearward & down (+Y, -Z)
            pl.gear_cluster(b, (s * (HX + 0.20), -0.32, 5.38), rot_side,
                            R=0.76, color="Brass", hub="CogRed", t=0.15, third=True, angle=-42.0)

        # Lower-rear recessed exhaust vent grille (low-tri)
        vf = pl.frame((s * (HX + 0.18), 0.65, 2.85), rot_side)
        pl.box(b, (1.18, 1.05, 0.18), vf((0, 0, 0)), "GunmetalDark", rot_side, bevel=0.0)
        pl.box(b, (0.94, 0.82, 0.08), vf((0, 0, 0.06)), "Soot", rot_side, bevel=0.0)
        for i in range(4):
            pl.box(b, (0.92, 0.10, 0.08), vf((0, -0.30 + i * 0.20, 0.10)),
                   "Gunmetal", rot_side, bevel=0.0)

        # Side pressure gauge near upper-rear corner
        pl.gauge(b, (s * (HX + 0.20), 1.08, 6.28), (s, 0, 0), r=0.28)


def build_rear_machinery(b, g):
    """Rear steam boiler drum, CogRed upper plate, twin smokestacks, and copper steam pipes."""
    rot_back = facing((0, 1, 0))

    # Upper rear CogRed riveted armour panel
    pl.riveted_plate(b, 3.10, 2.55, 0.22, (0.0, HY + 0.08, 6.08),
                     rot_back, "CogRed", "Brass", spacing=1.20, rivet_r=0.09,
                     chamfer=0.15, rivet_segs=4, bevel=0.0)

    # Rear valve handwheel & pressure gauge on the upper plate
    pl.handwheel(b, (-0.75, HY + 0.34, 6.08), (0, 1, 0), R=0.45, stem=0.20,
                 color="Brass", stem_color="GunmetalDark")
    pl.gauge(b, (0.78, HY + 0.22, 6.25), (0, 1, 0), r=0.32)

    # Horizontal steam boiler drum cradled across the lower-mid rear wall
    pl.steam_boiler(b, 0.88, 2.25, (0.0, HY + 0.54, 2.95), rot=pl.AX_X,
                    color="Rust", band_color="Brass", bands=3, rivets=False, segs=10)
    for s in (-1, 1):
        pl.box(b, (0.40, 1.12, 1.48), (s * 0.82, HY + 0.34, 2.75), "GunmetalDark", bevel=0.0)
        pl.box(b, (0.52, 0.90, 0.36), (s * 0.82, HY + 0.42, 1.88), "Gunmetal", bevel=0.0)

    # Rear lower hazard bumper stripe below the boiler
    pl.hazard_stripes(b, 2.95, 0.48, (0.0, HY + 0.06, 1.24),
                      rot=rot_back, stripes=5, c1="Hazard", c2="Oil", t=0.06)

    # Twin rear/upper smokestacks (tucked inward on the flat rear wall, clear of rear vanes)
    for s in (-1, 1):
        sx, sy, sz = s * 1.18, 2.72, 7.18
        pl.box(b, (0.98, 1.02, 1.24), (sx, sy - 0.16, sz + 0.18), "GunmetalDark", bevel=0.0)
        pl.box(b, (0.76, 1.08, 0.30), (sx, sy - 0.48, 9.25), "GunmetalDark", bevel=0.0)
        pl.cyl(b, 0.58, 0.26, (sx, sy, 9.25), "Brass", segs=8, bevel=0.0)
        pl.smokestack(b, (sx, sy, sz), r=0.46, h=4.75, color="Gunmetal", rim="Rust",
                      glow=g, segs=8)

        # Copper steam pipe running from rear boiler up into smokestack base
        pl.pipe(b, [
            (s * 1.08, HY + 0.54, 3.45),
            (s * 1.65, HY + 0.46, 4.35),
            (s * 1.72, HY + 0.25, 6.25),
            (sx, sy + 0.08, sz + 0.35),
        ], r=0.16, color="Copper", joint="Brass", sides=6)

        # Secondary copper feed pipe routing ABOVE the rear corner shock housing into the flank
        pl.pipe(b, [
            (s * 1.25, HY + 0.42, 3.35),
            (s * 2.02, HY + 0.15, 4.10),
            (s * 2.95, 1.85, 4.10),
            (s * 2.95, 1.45, 4.45),
        ], r=0.13, color="Copper", joint="Brass", sides=6)


def build_impact_claws(b):
    """Four heavy ground-anchor impact claws / shock-skids ringing the 45-deg lower corners."""
    for sx in (-1, 1):
        for sy in (-1, 1):
            d = Vector((sx, sy, 0)).normalized()
            tangent = Vector((-d.y, d.x, 0))
            ang = radians(45 if (sx > 0 and sy > 0) else 135 if (sx < 0 and sy > 0)
                          else 225 if (sx < 0 and sy < 0) else 315)
            rot_z = (0, 0, ang)

            # Heavy upper corner shock housing bolted onto the 45-deg chamfered wall
            p_house = d * 3.06 + Vector((0, 0, 2.42))
            pl.box(b, (0.90, 1.12, 1.98), p_house, "GunmetalDark", rot=rot_z, bevel=0.05)
            pl.box(b, (0.82, 1.04, 0.32), p_house + Vector((0, 0, 1.08)), "CogRed",
                   rot=rot_z, bevel=0.0)

            # Brass cog_joint hinge gear at the claw hip knuckle
            p_hip = d * 3.36 + Vector((0, 0, 1.68))
            pl.cog_joint(b, p_hip, tangent, r=0.42, w=0.54, color="Brass",
                         cap="GunmetalDark", teeth=8)

            # Angled forged claw leg strut slamming outward into the ground
            p_ankle = d * 4.06 + Vector((0, 0, 0.30))
            leg_dir = p_ankle - p_hip
            leg_rot = pl.basis(tangent, leg_dir)
            pl.taper_box(b, (0.54, 0.52), (0.40, 0.40), 0.0, leg_dir.length,
                         color="RustDark", loc=p_hip, rot=leg_rot, bevel=0.0)

            # Hydraulic shock absorber piston running from upper housing to ankle
            pl.piston(b, d * 3.52 + Vector((0, 0, 3.02)), p_ankle + Vector((0, 0, 0.24)),
                      r=0.13, color="Gunmetal", rod_color="Steel", split=0.55, segs=5)

            # Heavy ground-anchor impact claw / spade skid seated firmly at z = 0
            p_foot = d * 4.18 + Vector((0, 0, 0.21))
            pl.box(b, (1.06, 1.16, 0.42), p_foot, "Rust", rot=rot_z, bevel=0.04)
            pl.loft(b, [
                [(0.34, -0.50, 0.0), (0.34, 0.50, 0.0), (0.88, 0.34, 0.0), (0.88, -0.34, 0.0)],
                [(0.34, -0.44, 0.36), (0.34, 0.44, 0.36), (0.72, 0.26, 0.14), (0.72, -0.26, 0.14)],
            ], loc=d * 4.18, rot=rot_z, color="GunmetalDark", bevel=0.0)
            pl.rod(b, d * 2.86 + Vector((0, 0, 0.40)), d * 3.92 + Vector((0, 0, 0.32)),
                   0.15, "GunmetalDark", segs=5)


def build():
    k = pl.Kit(KEY, palette="cogwork", category="heavy", reset=True)
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Gunmetal")
    g = k.glow("Glow", role="glow", pivot=(0, 0, 0), parent="Body")
    door = k.part("Door", "limb", "Metal", pivot=DOOR_HINGE, parent="Body", color="Gunmetal")
    door_glow = k.glow("DoorGlow", role="glow", pivot=DOOR_HINGE, parent="Door")

    build_hull_and_bay(b, g)
    build_door(door, door_glow)
    build_nose_and_beacon(b, g)
    build_flanks(b)
    build_rear_machinery(b, g)
    build_impact_claws(b)

    # Named attachments for Luau wiring
    k.attachment("DoorHinge", DOOR_HINGE, part="Body")
    k.attachment("Beacon", (0.0, 0.0, 11.74), part="Body")
    k.attachment("StackL", (-1.18, 2.72, 12.05), part="Body")
    k.attachment("StackR", (1.18, 2.72, 12.05), part="Body")
    k.attachment("DeployExit", (0.0, -4.35, 1.35), part="Body")

    k.build()
    return k


def render_previews(k, root):
    """Render 3 clean preview PNGs directly into art/images/."""
    img_dir = os.path.join(root, "art", "images")
    os.makedirs(img_dir, exist_ok=True)
    shots = [
        ("", None, (0.68, -1.0, 0.48), 1.04),
        ("_open", {"Door": (radians(94), 0, 0)}, (0.48, -1.0, 0.38), 1.02),
        ("_back", None, (-0.70, 1.0, 0.46), 1.04),
    ]
    previews_dir = os.path.join(root, "art", "previews")
    previews_existed = os.path.isdir(previews_dir)
    for suffix, poses, direction, zoom in shots:
        src = k.preview(size=1024, suffix=suffix, poses=poses, direction=direction, zoom=zoom)
        if src and os.path.exists(src):
            dst = os.path.join(img_dir, f"{KEY}{suffix}.png")
            shutil.move(src, dst)
            print(f"[cog_drop_pod] image -> {dst}")
    if not previews_existed and os.path.isdir(previews_dir) and not os.listdir(previews_dir):
        os.rmdir(previews_dir)


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = os.path.abspath(a[a.index("--out") + 1]) if "--out" in a else os.path.normpath(os.path.join(HERE, "..", ".."))
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = "FBX_SCALE_ALL"

    k = build()
    k.report()
    for n, pt, v in k.attachments:
        print("ATTACH", KEY, n, pt, pl.to_roblox(v))
    if "--export" in a:
        k.export_fbx()
        k.write_manifest()
    if "--preview" in a:
        render_previews(k, root)


if __name__ == "__main__":
    main()
