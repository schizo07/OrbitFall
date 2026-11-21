"""Hostile Cogwork Ballistic Drop Pod (key cog_drop_pod) in Orbitfall's "Foundry Clockwork" style.

Hard-faceted orbital artillery-shell / bullet-form assault pod built from bolted forged-iron
tiers rising from a heavy impact skirt into a fluted armour-piercing warhead tip, anchored by
four swept-back stabilizer blast-blades with brass gear-joint roots. Features a flush-contoured
hinged front blast door lowering into a ribbed boarding ramp, a hollow recessed deploy bay with
glowing furnace vents, slanted CogRed flank armour with offset brass gear clusters, a toothed
brass warhead collar over recessed glow slits, and compact rear thruster-manifold exhausts.

Origin = base centre on the ground (z = 0), front blast door facing -Y (Roblox -Z).
Parts: Body (Metal), Door (Metal, parent Body), Glow (Neon, parent Body),
       DoorGlow (Neon, parent Door).

Headless:
  Blender -b --python art/blender/cog_drop_pod.py -- --out . --export --preview
"""
import os
import shutil
import sys
from math import atan2, cos, pi, radians, sin, sqrt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)
import parts_lib as pl
from mathutils import Euler, Matrix, Vector

KEY = "cog_drop_pod"

# Core ballistic hull dimensions (1 Blender unit = 1 stud, Z up, front = -Y)
Z_BASE = 0.66          # deploy bay floor top / lower driving-band shelf
Z_BAY_TOP = 6.08       # deploy bay ceiling height
Z_SHOULDER = 6.66      # top of lower tapered fuselage / warhead collar base
Z_TIP = 13.68          # sharp armour-piercing bullet tip

R_BASE = 2.94          # lower fuselage octagonal apothem at Z_BASE
C_BASE = 1.14          # 45-deg corner chamfer at Z_BASE
R_TOP = 2.26           # fuselage octagonal apothem at Z_SHOULDER
C_TOP = 0.94           # 45-deg corner chamfer at Z_SHOULDER

BAY_X_BOT = 1.54       # clear interior bay half-width at Z_BASE
BAY_X_TOP = 1.14       # clear interior bay half-width at Z_SHOULDER
BAY_Y_BOT = 1.48       # inner rear bulkhead Y at Z_BASE
BAY_Y_TOP = 1.06       # inner rear bulkhead Y at Z_SHOULDER

# Uniform inward slant angle of the lower tapered bullet fuselage (~6.47 deg)
HULL_TILT = atan2(R_BASE - R_TOP, Z_SHOULDER - Z_BASE)

# Hinged front blast door parameters (flush-contoured to the -Y tapered face)
DOOR_HINGE = (0.0, -2.99, 0.62)
DOOR_LEN = 5.42        # length along slanted front hull plane
DOOR_T = 0.26          # base slab thickness
DOOR_W_BOT = 3.24      # bottom width of door slab
DOOR_W_MID = 2.66      # width at shoulder chamfer start
DOOR_W_TOP = 1.82      # narrow bullet-shoulder top edge width
DOOR_S_MID = 4.35      # distance along door where top shoulder chamfer begins


def lerp(a, b, t):
    return a + (b - a) * t


def hull_rc(z):
    """Interpolated (apothem R, chamfer C) along the lower tapered bullet casing."""
    t = (z - Z_BASE) / (Z_SHOULDER - Z_BASE)
    return lerp(R_BASE, R_TOP, t), lerp(C_BASE, C_TOP, t)


def bay_xy(z):
    """Interpolated (half-width bay_x, rear bulkhead bay_y) inside the tapered bay."""
    t = (z - Z_BASE) / (Z_SHOULDER - Z_BASE)
    return lerp(BAY_X_BOT, BAY_X_TOP, t), lerp(BAY_Y_BOT, BAY_Y_TOP, t)


def facing(n, up=(0, 0, 1)):
    """Euler for a local-XY plate whose +Z faces normal n and local +Y aligns near up."""
    n = Vector(n).normalized()
    u = Vector(up)
    x = u.cross(n)
    if x.length < 1e-4:
        x = Vector((1, 0, 0))
    return pl.basis(x, n)


def front_plane_vectors():
    """Return (origin, up_vec, normal_vec, rot) for the slanted front (-Y) bullet face."""
    u = Vector((0.0, sin(HULL_TILT), cos(HULL_TILT))).normalized()
    n = Vector((0.0, -cos(HULL_TILT), sin(HULL_TILT))).normalized()
    rot = pl.basis((1.0, 0.0, 0.0), n)
    return Vector((0.0, -R_BASE, Z_BASE)), u, n, rot


def side_plane_vectors(side):
    """Return (origin, up_vec, normal_vec, rot) for the slanted left (-1) or right (+1) face."""
    u = Vector((-side * sin(HULL_TILT), 0.0, cos(HULL_TILT))).normalized()
    n = Vector((side * cos(HULL_TILT), 0.0, sin(HULL_TILT))).normalized()
    x_ax = u.cross(n).normalized()
    rot = pl.basis(x_ax, n)
    return Vector((side * R_BASE, 0.0, Z_BASE)), u, n, rot


def rear_plane_vectors():
    """Return (origin, up_vec, normal_vec, rot) for the slanted rear (+Y) bullet face."""
    u = Vector((0.0, -sin(HULL_TILT), cos(HULL_TILT))).normalized()
    n = Vector((0.0, cos(HULL_TILT), sin(HULL_TILT))).normalized()
    rot = pl.basis((-1.0, 0.0, 0.0), n)
    return Vector((0.0, R_BASE, Z_BASE)), u, n, rot


def recessed_furnace_grate(b, g, w, h, bars, loc, normal, up=(0, 0, 1), depth=0.20):
    """Low-tri recessed furnace grate with hot Neon core recessed behind iron bars."""
    rot = facing(normal, up=up)
    f = pl.frame(loc, rot)
    fw = min(w, h) * 0.12
    for x, y, sx, sy in ((0, h / 2 - fw / 2, w, fw), (0, -h / 2 + fw / 2, w, fw),
                         (w / 2 - fw / 2, 0, fw, h), (-w / 2 + fw / 2, 0, fw, h)):
        pl.box(b, (sx, sy, depth), f((x, y, 0)), "GunmetalDark", rot, bevel=0.0)
    inner_w = w - 2 * fw
    inner_h = h - 2 * fw
    pl.box(b, (inner_w, inner_h, depth * 0.24), f((0, 0, -depth * 0.36)), "Soot", rot, bevel=0.0)
    pl.box(g, (inner_w * 0.90, inner_h * 0.90, depth * 0.12), f((0, 0, -depth * 0.18)), rot=rot, bevel=0.0)
    for i in range(bars):
        y = -inner_h / 2 + inner_h * (i + 0.5) / bars
        pl.box(b, (inner_w, inner_h / bars * 0.30, depth * 0.44), f((0, y, depth * 0.18)),
               "Gunmetal", rot, bevel=0.0)


def build_base_and_hull(b, g):
    """Heavy impact skirt, tapered hollow octagonal bullet hull, and recessed deploy bay."""
    # Bottom forged impact keel resting flat on z = 0
    pl.loft(b, [
        pl.chamfer_rect(2.50, 2.50, 0.98, z=0.0),
        pl.chamfer_rect(2.74, 2.74, 1.07, z=0.22),
    ], color="RustDark", bevel=0.0)

    # Heavy lower breach skirt / ballistic driving-band base (z = 0.20 .. 0.70)
    pl.loft(b, [
        pl.chamfer_rect(2.76, 2.76, 1.08, z=0.20),
        pl.chamfer_rect(3.00, 3.00, 1.16, z=0.52),
        pl.chamfer_rect(2.96, 2.96, 1.15, z=0.70),
    ], color="GunmetalDark", bevel=0.04)

    # Scorched Rust artillery driving band around the base skirt
    pl.loft(b, [
        pl.chamfer_rect(3.04, 3.04, 1.18, z=0.34),
        pl.chamfer_rect(3.04, 3.04, 1.18, z=0.56),
    ], color="Rust", bevel=0.0)

    # Tapered hollow octagonal bullet hull (3 convex watertight lofted walls)
    z0, z1 = Z_BASE - 0.03, Z_SHOULDER
    r0, c0 = hull_rc(z0)
    r1, c1 = hull_rc(z1)
    bx0, by0 = bay_xy(z0)
    bx1, by1 = bay_xy(z1)

    def left_ring(r, c, bx, by, z):
        return [
            (-r, -r + c, z), (-r + c, -r, z),
            (-bx, -r, z), (-bx, by + 0.06, z), (-r, by + 0.06, z),
        ]

    def right_ring(r, c, bx, by, z):
        return [
            (bx, -r, z), (r - c, -r, z), (r, -r + c, z),
            (r, by + 0.06, z), (bx, by + 0.06, z),
        ]

    def rear_ring(r, c, by, z):
        return [
            (-r, by, z), (r, by, z),
            (r, r - c, z), (r - c, r, z),
            (-r + c, r, z), (-r, r - c, z),
        ]

    pl.loft(b, [left_ring(r0, c0, bx0, by0, z0), left_ring(r1, c1, bx1, by1, z1)],
            color="Gunmetal", bevel=0.04)
    pl.loft(b, [right_ring(r0, c0, bx0, by0, z0), right_ring(r1, c1, bx1, by1, z1)],
            color="Gunmetal", bevel=0.04)
    pl.loft(b, [rear_ring(r0, c0, by0, z0), rear_ring(r1, c1, by1, z1)],
            color="Gunmetal", bevel=0.04)

    # Solid upper bay ceiling closing the bullet hull at Z_BAY_TOP .. Z_SHOULDER + 0.06
    rc_ceil = hull_rc(Z_BAY_TOP)
    rc_sh = hull_rc(Z_SHOULDER + 0.06)
    pl.loft(b, [
        pl.chamfer_rect(rc_ceil[0], rc_ceil[0], rc_ceil[1], z=Z_BAY_TOP),
        pl.chamfer_rect(rc_sh[0], rc_sh[0], rc_sh[1], z=Z_SHOULDER + 0.06),
    ], color="Gunmetal", bevel=0.04)

    # Slanted armoured doorway frame jambs + upper chamfered slam-latch brow
    f_orig, f_up, f_n, f_rot = front_plane_vectors()
    for s in (-1, 1):
        p_bot = f_orig + Vector((s * (BAY_X_BOT + 0.14), 0.0, 0.0)) + f_up * 0.08 + f_n * 0.05
        p_top = f_orig + Vector((s * (BAY_X_TOP + 0.16), 0.0, 0.0)) + f_up * 5.40 + f_n * 0.05
        d_jamb = p_top - p_bot
        rot_j = pl.basis(f_n, d_jamb)
        pl.box(b, (0.28, 0.26, d_jamb.length), (p_bot + p_top) / 2.0, "GunmetalDark", rot_j, bevel=0.02)

        # Heavy upper slam-latch lock housing flanking the door's top shoulder cut
        p_lock = f_orig + Vector((s * 1.12, 0.0, 0.0)) + f_up * 5.38 + f_n * 0.14
        pl.box(b, (0.40, 0.42, 0.34), p_lock, "GunmetalDark", f_rot, bevel=0.0)
        pl.cyl(b, 0.09, 0.30, p_lock + f_n * 0.12 - f_up * 0.06, "Brass",
               pl.orient(f_up), segs=6, bevel=0.0)

    # Recessed twin warning visor slot on the slanted upper brow above the blast door
    p_brow = f_orig + f_up * 5.74 + f_n * 0.04
    pl.visor_slot(b, g, 1.48, 0.28, p_brow, normal=f_n, up=f_up, depth=0.20,
                  lenses=2, color="Soot", frame_color="GunmetalDark")

    # ---- Hollow Recessed Dark Deploy Bay Interior ----
    pl.box(b, (BAY_X_BOT * 2.0 - 0.06, BAY_Y_BOT + R_BASE - 0.28, 0.08),
           (0.0, (BAY_Y_BOT - R_BASE) / 2.0 + 0.10, Z_BASE + 0.03), "Grime", bevel=0.0)
    for y_rib in (-2.05, -1.35, -0.65, 0.05, 0.75):
        pl.box(b, (BAY_X_BOT * 1.72, 0.15, 0.07), (0.0, y_rib, Z_BASE + 0.09), "GunmetalDark", bevel=0.0)
    pl.hazard_stripes(b, BAY_X_BOT * 1.88, 0.40, (0.0, -R_BASE + 0.28, Z_BASE + 0.06),
                      rot=(0, 0, 0), stripes=5, c1="Hazard", c2="Oil", t=0.04)

    # Slanted dark Soot rear bulkhead liner + glowing recessed furnace grate
    rear_bay_tilt = atan2(BAY_Y_BOT - BAY_Y_TOP, Z_SHOULDER - Z_BASE)
    u_rb = Vector((0.0, -sin(rear_bay_tilt), cos(rear_bay_tilt))).normalized()
    n_rb = Vector((0.0, -cos(rear_bay_tilt), -sin(rear_bay_tilt))).normalized()
    rot_rb = facing(n_rb, up=u_rb)
    z_mid = (Z_BASE + Z_BAY_TOP) / 2.0
    bx_mid, by_mid = bay_xy(z_mid)
    bay_h = Z_BAY_TOP - Z_BASE - 0.16

    pl.box(b, (bx_mid * 1.94, bay_h, 0.10), (0.0, by_mid - 0.05, z_mid), "Soot", rot_rb, bevel=0.0)
    recessed_furnace_grate(b, g, 1.96, 2.40, 4, (0.0, by_mid - 0.20, z_mid + 0.15),
                           normal=n_rb, up=u_rb, depth=0.22)

    # Slanted interior side bay walls (Soot liners + ribs + recessed furnace slits + copper pipes)
    side_bay_tilt = atan2(BAY_X_BOT - BAY_X_TOP, Z_SHOULDER - Z_BASE)
    for s in (-1, 1):
        u_sb = Vector((-s * sin(side_bay_tilt), 0.0, cos(side_bay_tilt))).normalized()
        n_sb = Vector((-s * cos(side_bay_tilt), 0.0, -sin(side_bay_tilt))).normalized()
        rot_sb = facing(n_sb, up=u_sb)
        pl.box(b, (by_mid + R_BASE - 0.55, bay_h, 0.09),
               (s * (bx_mid - 0.04), -0.60, z_mid), "Soot", rot_sb, bevel=0.0)
        for y_rib in (-1.55, -0.30, 0.72):
            pl.box(b, (0.18, bay_h - 0.16, 0.18), (s * (bx_mid - 0.10), y_rib, z_mid),
                   "GunmetalDark", rot_sb, bevel=0.0)
        recessed_furnace_grate(b, g, 0.76, 2.25, 4, (s * (bx_mid - 0.16), -0.92, z_mid + 0.05),
                               normal=n_sb, up=u_sb, depth=0.14)
        # Interior rear-corner copper steam conduit following the inward taper
        pl.rod(b, (s * (BAY_X_BOT - 0.22), BAY_Y_BOT - 0.22, Z_BASE + 0.20),
               (s * (BAY_X_TOP - 0.16), BAY_Y_TOP - 0.16, Z_BAY_TOP - 0.20),
               0.09, "Copper", segs=6, bevel=0.0)

    # Overhead troop restraint yoke inside the bay ceiling
    pl.box(b, (2.05, 0.34, 0.26), (0.0, 0.15, Z_BAY_TOP - 0.20), "GunmetalDark", bevel=0.0)
    for s in (-1, 1):
        pl.box(b, (0.22, 1.05, 0.20), (s * 0.72, 0.0, Z_BAY_TOP - 0.42), "Rust", bevel=0.0)

    # Stationary hinge knuckles & prominent brass cog_joint gears at bottom-front threshold
    hy, hz = DOOR_HINGE[1], DOOR_HINGE[2]
    for s in (-1, 1):
        pl.box(b, (0.42, 0.58, 0.58), (s * 1.84, hy + 0.22, hz + 0.04), "GunmetalDark", bevel=0.03)
        pl.cog_joint(b, (s * 1.94, hy, hz), (1, 0, 0), r=0.46, w=0.26, color="Brass",
                     cap="GunmetalDark", teeth=10)


def build_door(door, door_glow):
    """Separate contoured Front Blast Door pivoting at DOOR_HINGE into an assault ramp."""
    hy, hz = DOOR_HINGE[1], DOOR_HINGE[2]
    _, f_up, f_n, f_rot = front_plane_vectors()
    # Local door frame: origin at DOOR_HINGE, +X = right, +Y = up along door, +Z = outward (-Y/up)
    df = pl.frame(DOOR_HINGE, f_rot)

    # Bottom hinge axle barrel spanning the hinge axis + brass hinge knuckles
    pl.cyl(door, 0.18, DOOR_W_BOT + 0.32, DOOR_HINGE, "GunmetalDark", pl.AX_X, segs=8, bevel=0.0)
    for x_kn in (-1.18, 0.0, 1.18):
        pl.cyl(door, 0.25, 0.42, (x_kn, hy, hz), "Brass", pl.AX_X, segs=8, bevel=0.0)

    # Main contoured heavy door slab (trapezoid + chamfered bullet-shoulder top cut)
    s0 = 0.06
    s_top = s0 + DOOR_LEN
    s_mid = s0 + DOOR_S_MID
    door_prof = [
        (-DOOR_W_BOT / 2.0, s0),
        (DOOR_W_BOT / 2.0, s0),
        (DOOR_W_MID / 2.0, s_mid),
        (DOOR_W_TOP / 2.0, s_top),
        (-DOOR_W_TOP / 2.0, s_top),
        (-DOOR_W_MID / 2.0, s_mid),
    ]
    z_slab = -0.02  # slab center offset slightly inward along local Z so outer face is flush
    pl.extrude(door, door_prof, DOOR_T, df((0.0, 0.0, z_slab)), "GunmetalDark",
               f_rot, plane='XY', bevel=0.04)

    # ---- Outer Blast Face (+Z in door frame) ----
    z_out = z_slab + DOOR_T / 2.0

    # Lower CogRed tapered armour plate (s = 0.82 .. 2.86)
    low_prof = [(-1.38, 0.84), (1.38, 0.84), (1.28, 2.84), (-1.28, 2.84)]
    pl.extrude(door, low_prof, 0.14, df((0.0, 0.0, z_out + 0.06)), "CogRed",
               f_rot, plane='XY', bevel=0.0)
    for x_r in (-1.14, 0.0, 1.14):
        pl.bolt(door, df((x_r, 1.08, z_out + 0.13)), f_n, r=0.075, color="Brass", segs=4)
        pl.bolt(door, df((x_r, 2.60, z_out + 0.13)), f_n, r=0.075, color="Brass", segs=4)

    # Upper CogRed bullet-shoulder tapered armour plate (s = 3.22 .. 5.14)
    up_prof = [
        (-1.24, 3.22), (1.24, 3.22),
        (1.12, 4.30), (0.76, 5.12),
        (-0.76, 5.12), (-1.12, 4.30),
    ]
    pl.extrude(door, up_prof, 0.14, df((0.0, 0.0, z_out + 0.06)), "CogRed",
               f_rot, plane='XY', bevel=0.0)
    for rx, ry in ((-1.00, 3.44), (0.0, 3.44), (1.00, 3.44),
                   (-0.92, 4.24), (0.92, 4.24), (-0.56, 4.92), (0.56, 4.92)):
        pl.bolt(door, df((rx, ry, z_out + 0.13)), f_n, r=0.075, color="Brass", segs=4)

    # Heavy horizontal waist crossbar + side slam-locking lugs
    pl.box(door, (2.94, 0.34, 0.20), df((0.0, 3.03, z_out + 0.09)), "Gunmetal", f_rot, bevel=0.0)
    for s in (-1, 1):
        pl.box(door, (0.38, 0.56, 0.26), df((s * 1.38, 3.03, z_out + 0.11)), "GunmetalDark", f_rot, bevel=0.0)
        pl.box(door, (0.34, 0.20, 0.16), df((s * 1.56, 3.03, z_out + 0.06)), "Brass", f_rot, bevel=0.0)
        # Upper diagonal latch bar along the shoulder chamfer
        pl.box(door, (0.28, 0.56, 0.22), df((s * 0.96, 4.86, z_out + 0.10)), "Gunmetal", f_rot, bevel=0.0)
        pl.bolt(door, df((s * 0.96, 4.92, z_out + 0.21)), f_n, r=0.075, color="Brass", segs=4)

    # Central Faction Mark (brass gear + recessed red-orange Cog Eye lens in DoorGlow)
    pl.cog_mark(door, door_glow, df((0.0, 3.03, z_out + 0.18)),
                normal=f_n, r=0.82, color="Brass", rim="GunmetalDark")

    # Lower exterior hazard chevron threshold band
    pl.hazard_stripes(door, 2.74, 0.46, df((0.0, 0.46, z_out + 0.04)),
                      rot=f_rot, stripes=5, c1="Hazard", c2="Oil", t=0.05)

    # Heavy forged Rust breach bumper across the chamfered top rim (impacts ground when open)
    pl.box(door, (DOOR_W_TOP + 0.06, 0.26, 0.32), df((0.0, s_top - 0.08, z_slab + 0.02)),
           "Rust", f_rot, bevel=0.03)

    # ---- Inner Assault Ramp Face (-Z in door frame; faces UP when opened ~99 deg!) ----
    z_in = z_slab - DOOR_T / 2.0
    # Dark non-slip ramp deck backing
    in_prof = [
        (-DOOR_W_BOT / 2.0 + 0.26, s0 + 0.16),
        (DOOR_W_BOT / 2.0 - 0.26, s0 + 0.16),
        (DOOR_W_MID / 2.0 - 0.24, s_mid - 0.06),
        (DOOR_W_TOP / 2.0 - 0.20, s_top - 0.20),
        (-DOOR_W_TOP / 2.0 + 0.20, s_top - 0.20),
        (-DOOR_W_MID / 2.0 + 0.24, s_mid - 0.06),
    ]
    pl.extrude(door, in_prof, 0.06, df((0.0, 0.0, z_in - 0.02)), "Soot",
               f_rot, plane='XY', bevel=0.0)

    # Tapered raised steel boarding tread cleats across the inner ramp face
    for i in range(7):
        si = s0 + 0.46 + i * 0.68
        if si < s_mid:
            t_w = (si - s0) / (s_mid - s0)
            w_cleat = lerp(DOOR_W_BOT, DOOR_W_MID, t_w) - 0.64
        else:
            t_w = (si - s_mid) / (s_top - s_mid)
            w_cleat = lerp(DOOR_W_MID, DOOR_W_TOP, t_w) - 0.56
        pl.box(door, (w_cleat, 0.18, 0.11), df((0.0, si, z_in - 0.07)), "Steel", f_rot, bevel=0.0)

    # Center traction spine + angled side guide rails with brass trim
    pl.box(door, (0.20, DOOR_LEN - 0.52, 0.09), df((0.0, s0 + DOOR_LEN / 2.0, z_in - 0.05)),
           "GunmetalDark", f_rot, bevel=0.0)
    for s in (-1, 1):
        p0 = df((s * (DOOR_W_BOT / 2.0 - 0.16), s0 + 0.22, z_in - 0.07))
        p1 = df((s * (DOOR_W_MID / 2.0 - 0.16), s_mid - 0.05, z_in - 0.07))
        d_rail = p1 - p0
        rot_r = pl.basis(f_n, d_rail)
        pl.box(door, (0.14, 0.20, d_rail.length), (p0 + p1) / 2.0, "Gunmetal", rot_r, bevel=0.0)
        pl.box(door, (0.05, 0.09, d_rail.length - 0.16),
               (p0 + p1) / 2.0 - f_n * 0.09, "Brass", rot_r, bevel=0.0)


def build_warhead_ogive(b, g):
    """Multi-stage faceted artillery-shell ogive, brass toothed collar, slit glow ring, and pointed tip."""
    # Heavy bolted collar transitioning from tapered hull into the warhead shoulder (z = 6.62 .. 7.36)
    pl.loft(b, [
        pl.chamfer_rect(2.38, 2.38, 0.99, z=6.62),
        pl.chamfer_rect(2.34, 2.34, 0.98, z=7.02),
        pl.chamfer_rect(2.14, 2.14, 0.90, z=7.36),
    ], color="GunmetalDark", bevel=0.04)

    # Prominent toothed brass warhead collar ring (Cog rule 3) at z = 7.42
    pl.gear(b, 2.30, 2.08, 16, 0.28, (0.0, 0.0, 7.42), "Brass")

    # Recessed red-orange glowing warhead slit ring caged inside 8 armoured vertical ribs (z = 7.56 .. 8.12)
    pl.cyl(b, 1.72, 0.60, (0.0, 0.0, 7.84), "Soot", segs=8, bevel=0.0)
    pl.cyl(g, 1.79, 0.34, (0.0, 0.0, 7.84), segs=8, bevel=0.0)
    for i in range(8):
        a = radians(22.5 + i * 45.0)
        d = Vector((cos(a), sin(a), 0.0))
        pl.box(b, (0.34, 0.44, 0.66), d * 1.88 + Vector((0.0, 0.0, 7.84)),
               "GunmetalDark", rot=(0.0, 0.0, a), bevel=0.0)

    # Overhanging warhead brow collar capping the glow slits (z = 8.08 .. 8.46)
    pl.loft(b, [
        pl.chamfer_rect(2.06, 2.06, 0.86, z=8.08),
        pl.chamfer_rect(2.04, 2.04, 0.85, z=8.34),
        pl.chamfer_rect(1.94, 1.94, 0.81, z=8.46),
    ], color="GunmetalDark", bevel=0.04)

    # Stage 1 & 2 Ballistic Ogive Warhead Cone (z = 8.44 .. 11.12)
    pl.loft(b, [
        pl.chamfer_rect(1.92, 1.92, 0.80, z=8.44),
        pl.chamfer_rect(1.52, 1.52, 0.63, z=9.78),
        pl.chamfer_rect(0.96, 0.96, 0.40, z=11.12),
    ], color="Gunmetal", bevel=0.04)

    # Bold CogRed tapered warhead identification band wrapping the lower ogive (z = 8.62 .. 10.12)
    pl.loft(b, [
        pl.chamfer_rect(1.92, 1.92, 0.80, z=8.62),
        pl.chamfer_rect(1.48, 1.48, 0.62, z=10.12),
    ], color="CogRed", bevel=0.0)

    # 4 heavy longitudinal ballistic armour strakes + brass bolts along the ogive cardinal faces
    for a_deg in (0, 90, 180, 270):
        a = radians(a_deg)
        d = Vector((cos(a), sin(a), 0.0))
        p0 = d * 1.96 + Vector((0.0, 0.0, 8.50))
        p1 = d * 0.98 + Vector((0.0, 0.0, 11.12))
        dv = p1 - p0
        rot_s = pl.basis(Vector((-d.y, d.x, 0.0)), dv)
        pl.taper_box(b, (0.36, 0.24), (0.20, 0.16), 0.0, dv.length,
                     color="GunmetalDark", loc=p0, rot=rot_s, bevel=0.0)
        # Brass armour bolt near mid-strake
        n_strake = (d * dv.z + Vector((0, 0, (p0.xy.length - p1.xy.length)))).normalized()
        pl.bolt(b, p0.lerp(p1, 0.45) + n_strake * 0.11, n_strake, r=0.08, color="Brass", segs=4)

    # Upper brass toothed fuze collar at z = 11.16
    pl.gear(b, 1.06, 0.90, 12, 0.22, (0.0, 0.0, 11.16), "Brass")

    # Compact recessed upper warhead beacon collar (z = 11.26 .. 11.98)
    pl.loft(b, [
        pl.chamfer_rect(0.88, 0.88, 0.37, z=11.26),
        pl.chamfer_rect(0.68, 0.68, 0.28, z=11.44),
    ], color="GunmetalDark", bevel=0.0)
    pl.cyl(b, 0.52, 0.46, (0.0, 0.0, 11.66), "Soot", segs=8, bevel=0.0)
    pl.cyl(g, 0.56, 0.24, (0.0, 0.0, 11.66), segs=8, bevel=0.0)
    for i in range(4):
        a = radians(45 + i * 90)
        d = Vector((cos(a), sin(a), 0.0))
        pl.box(b, (0.24, 0.28, 0.48), d * 0.60 + Vector((0.0, 0.0, 11.66)),
               "GunmetalDark", rot=(0.0, 0.0, a), bevel=0.0)

    # Fluted Steel & Brass Armoured Pointed Bullet / Artillery Tip (z = 11.90 .. 13.68)
    pl.loft(b, [
        pl.chamfer_rect(0.70, 0.70, 0.29, z=11.90),
        pl.chamfer_rect(0.56, 0.56, 0.23, z=12.16),
    ], color="GunmetalDark", bevel=0.0)
    pl.cyl(b, 0.56, 0.12, (0.0, 0.0, 12.22), "Brass", segs=8, bevel=0.0)

    # Sharp 8-sided armour-piercing penetrator cone
    pl.lathe(b, [
        (0.52, 12.26),
        (0.36, 12.88),
        (0.16, 13.38),
        (0.0, Z_TIP),
    ], (0.0, 0.0, 0.0), color="Steel", rot=(0.0, 0.0, radians(22.5)), segs=8, bevel=0.0)

    # 4 crisp Brass/Gunmetal ballistic fluting ribs racing up the penetrator tip
    for i in range(4):
        a = radians(45 + i * 90)
        d = Vector((cos(a), sin(a), 0.0))
        p0 = d * 0.53 + Vector((0.0, 0.0, 12.26))
        p1 = d * 0.14 + Vector((0.0, 0.0, 13.36))
        dv = p1 - p0
        rot_f = pl.basis(Vector((-d.y, d.x, 0.0)), dv)
        pl.taper_box(b, (0.12, 0.14), (0.05, 0.06), 0.0, dv.length,
                     color="Brass", loc=p0, rot=rot_f, bevel=0.0)


def build_stabilizer_fins(b):
    """Four heavy swept-back stabilizer tail-fins / ground-anchoring blast blades at 45-deg corners."""
    for sx in (-1, 1):
        for sy in (-1, 1):
            ang = radians(45 if (sx > 0 and sy > 0) else 135 if (sx < 0 and sy > 0)
                          else 225 if (sx < 0 and sy < 0) else 315)
            d = Vector((cos(ang), sin(ang), 0.0))
            tangent = Vector((-d.y, d.x, 0.0))
            rot_z = (0.0, 0.0, ang)

            # Diagonal hull corner radius at base (z=0.66) is (2.94 - 1.14/2)*sqrt(2) = 3.35
            # and at shoulder (z=6.66) is (2.26 - 0.94/2)*sqrt(2) = 2.53.
            # Main swept forged-iron blast fin blade (plane='XZ' -> local X = radial out, Z = height)
            fin_prof = [
                (2.34, 6.42),   # upper root tucked cleanly into hull shoulder
                (2.74, 6.26),   # upper leading shoulder
                (4.78, 1.82),   # fierce swept diagonal leading blade edge
                (5.26, 0.36),   # outer ground-anchor blade tip
                (5.16, 0.00),   # flat ground-anchor toe at z = 0
                (2.84, 0.00),   # inner ground-anchor heel at z = 0
                (2.96, 0.56),   # slight lower blast-relief step
                (3.04, 1.38),   # lower hull root
            ]
            pl.extrude(b, fin_prof, 0.32, (0.0, 0.0, 0.0), "GunmetalDark",
                       rot=rot_z, plane='XZ', bevel=0.02)

            # Scorched Rust armour leading-edge cap bolted down the slashing outer fin edge
            lead_prof = [
                (2.68, 6.28),
                (2.98, 6.18),
                (5.06, 1.76),
                (5.46, 0.32),
                (5.36, 0.00),
                (5.08, 0.00),
                (5.20, 0.34),
                (4.74, 1.80),
            ]
            pl.extrude(b, lead_prof, 0.22, (0.0, 0.0, 0.0), "Rust",
                       rot=rot_z, plane='XZ', bevel=0.0)

            # Chamfered CogRed armour gusset bolted to both faces of the lower-mid fin
            gus_prof = [
                (2.92, 1.35),
                (3.92, 1.35),
                (3.62, 3.10),
                (2.74, 3.45),
            ]
            pl.extrude(b, gus_prof, 0.42, (0.0, 0.0, 0.0), "CogRed",
                       rot=rot_z, plane='XZ', bevel=0.0)

            # Heavy ground-anchoring impact foot plate clamping the blade into the dirt at z = 0
            p_spade = d * 4.24 + Vector((0.0, 0.0, 0.16))
            pl.box(b, (1.82, 0.86, 0.32), p_spade, "RustDark", rot=rot_z, bevel=0.03)
            pl.loft(b, [
                [(0.58, -0.38, 0.0), (0.58, 0.38, 0.0), (1.36, 0.22, 0.0), (1.36, -0.22, 0.0)],
                [(0.58, -0.32, 0.30), (0.58, 0.32, 0.30), (1.16, 0.16, 0.12), (1.16, -0.16, 0.12)],
            ], loc=d * 4.24, rot=rot_z, color="GunmetalDark", bevel=0.0)

            # Heavy root mounting bracket saddle + proud brass cog_joint pivots (Cog rule 1)
            p_root_lo = d * 3.30 + Vector((0.0, 0.0, 1.98))
            pl.box(b, (0.72, 0.56, 1.18), d * 3.04 + Vector((0.0, 0.0, 2.02)),
                   "Gunmetal", rot=rot_z, bevel=0.03)
            pl.cog_joint(b, p_root_lo, tangent, r=0.45, w=0.66, color="Brass",
                         cap="GunmetalDark", teeth=8)

            p_root_hi = d * 2.78 + Vector((0.0, 0.0, 5.56))
            pl.box(b, (0.62, 0.48, 0.86), d * 2.56 + Vector((0.0, 0.0, 5.58)),
                   "GunmetalDark", rot=rot_z, bevel=0.02)
            pl.cog_joint(b, p_root_hi, tangent, r=0.34, w=0.58, color="Brass",
                         cap="GunmetalDark", teeth=6)

            # Diagonal armour stiffening rib spanning the outer fin flank
            p_rib0 = d * 3.06 + Vector((0.0, 0.0, 4.92))
            p_rib1 = d * 4.52 + Vector((0.0, 0.0, 1.62))
            d_rib = p_rib1 - p_rib0
            rot_rib = pl.basis(tangent, d_rib)
            pl.box(b, (0.44, 0.16, d_rib.length), (p_rib0 + p_rib1) / 2.0,
                   "Gunmetal", rot_rib, bevel=0.0)


def build_flanks(b, g):
    """Slanted CogRed flank armour plates, offset brass gear clusters, and flush exhaust louvres."""
    for s in (-1, 1):
        s_orig, s_up, s_n, s_rot = side_plane_vectors(s)
        sf = pl.frame(s_orig, s_rot)

        # Tapered CogRed flank armour slab hugging the slanted bullet wall (s = 0.55 .. 5.25)
        flank_prof = [
            (-1.46, 0.55), (1.46, 0.55),
            (1.16, 5.25), (-1.16, 5.25),
        ]
        pl.extrude(b, flank_prof, 0.18, sf((0.0, 0.0, 0.08)), "CogRed",
                   s_rot, plane='XY', bevel=0.0)

        # Brass border rivets seated flush on the tapered CogRed flank plate
        for rx, ry in (
            (-1.24, 0.80), (0.0, 0.80), (1.24, 0.80),
            (-1.18, 2.25), (1.18, 2.25),
            (-1.08, 3.70), (1.08, 3.70),
            (-0.96, 5.02), (0.0, 5.02), (0.96, 5.02),
        ):
            pl.bolt(b, sf((rx, ry, 0.17)), s_n, r=0.08, color="Brass", segs=4)

        # Heavy upper & lower GunmetalDark clamping bars across the flank plate
        pl.box(b, (3.04, 0.28, 0.24), sf((0.0, 0.46, 0.08)), "GunmetalDark", s_rot, bevel=0.0)
        pl.box(b, (2.46, 0.28, 0.24), sf((0.0, 5.34, 0.08)), "GunmetalDark", s_rot, bevel=0.0)

        # Offset brass gear_cluster on the upper-front third of the slanted flank plate (Cog rule 2)
        # Note: side_plane_vectors(+1) has local +X = +Y (rear); (-1) has local +X = -Y (front).
        if s < 0:
            pl.gear_cluster(b, sf((-0.30, 3.66, 0.16)), s_rot,
                            R=0.62, color="Brass", hub="CogRed", t=0.14, third=True, angle=-45.0)
            vent_x, gauge_x = 0.42, 0.72
        else:
            pl.gear_cluster(b, sf((0.30, 3.66, 0.16)), s_rot,
                            R=0.62, color="Brass", hub="CogRed", t=0.14, third=True, angle=-135.0)
            vent_x, gauge_x = -0.42, -0.72

        # Flush angled exhaust louvre box with subtle recessed ember slit in lower-rear flank
        pl.box(b, (1.16, 1.06, 0.16), sf((vent_x, 1.72, 0.16)), "GunmetalDark", s_rot, bevel=0.0)
        pl.box(b, (0.94, 0.84, 0.08), sf((vent_x, 1.72, 0.20)), "Soot", s_rot, bevel=0.0)
        pl.box(g, (0.82, 0.62, 0.04), sf((vent_x, 1.72, 0.21)), rot=s_rot, bevel=0.0)
        for i in range(4):
            y_slat = 1.40 + i * 0.21
            slat_rot = (pl._rot(s_rot).to_matrix() @ Matrix.Rotation(radians(28), 3, 'X')).to_euler()
            pl.box(b, (0.94, 0.14, 0.07), sf((vent_x, y_slat, 0.25)), "Gunmetal", slat_rot, bevel=0.0)

        # Brass pressure gauge on the upper-rear flank corner, clear of gear teeth
        pl.gauge(b, sf((gauge_x, 4.54, 0.18)), s_n, r=0.22)


def build_rear_machinery(b, g):
    """Compact rear steam boiler, slanted CogRed valve panel, and flush angled thruster-manifold exhausts."""
    r_orig, r_up, r_n, r_rot = rear_plane_vectors()
    rf = pl.frame(r_orig, r_rot)

    # Slanted rear CogRed armour hatch plate (s = 2.65 .. 5.20)
    rear_prof = [
        (-1.32, 2.65), (1.32, 2.65),
        (1.14, 5.20), (-1.14, 5.20),
    ]
    pl.extrude(b, rear_prof, 0.18, rf((0.0, 0.0, 0.08)), "CogRed",
               r_rot, plane='XY', bevel=0.0)
    for rx, ry in ((-1.10, 2.86), (0.0, 2.86), (1.10, 2.86),
                   (-1.02, 4.02), (1.02, 4.02),
                   (-0.92, 4.98), (0.0, 4.98), (0.92, 4.98)):
        pl.bolt(b, rf((rx, ry, 0.17)), r_n, r=0.075, color="Brass", segs=4)

    # Rear valve handwheel & pressure gauge mounted cleanly below the manifold housings
    pl.handwheel(b, rf((0.46, 3.68, 0.30)), r_n, R=0.36, stem=0.18,
                 color="Brass", stem_color="GunmetalDark")
    pl.gauge(b, rf((-0.48, 3.74, 0.18)), r_n, r=0.24)

    # Compact horizontal steam boiler drum cradled tightly against the lower rear taper
    p_boiler = rf((0.0, 1.56, 0.44))
    pl.steam_boiler(b, 0.72, 1.88, p_boiler, rot=pl.AX_X,
                    color="Rust", band_color="Brass", bands=3, rivets=False, segs=8)
    for s in (-1, 1):
        pl.box(b, (0.34, 1.16, 0.90), rf((s * 0.68, 1.48, 0.24)), "GunmetalDark", r_rot, bevel=0.0)
        pl.box(b, (0.44, 0.32, 0.78), rf((s * 0.68, 0.88, 0.30)), "Gunmetal", r_rot, bevel=0.0)

    # Lower rear hazard warning strip beneath the boiler cradle
    pl.hazard_stripes(b, 2.58, 0.42, rf((0.0, 0.44, 0.05)),
                      rot=r_rot, stripes=5, c1="Hazard", c2="Oil", t=0.05)

    # Twin compact angled thruster-manifold exhausts hugging the rear bullet taper
    stack_tips = {}
    for s in (-1, 1):
        # Manifold base bolted high on the upper rear shoulder, clear of rear valve/gauge
        p_m0 = rf((-s * 0.88, 5.14, 0.22))
        # Sweeps inward along the bullet taper up to z ~ 7.92
        p_m1 = Vector((s * 0.84, 2.26, 7.92))
        d_m = (p_m1 - p_m0).normalized()
        rot_m = pl.orient(d_m)

        # Armoured manifold collar & clamp onto the hull
        pl.box(b, (0.60, 0.74, 0.52), p_m0 - d_m * 0.14, "GunmetalDark", r_rot, bevel=0.0)
        # Main compact angled exhaust barrel hugging the shoulder collar
        pl.rod(b, p_m0, p_m1, 0.32, "Gunmetal", segs=8, r2=0.28, bevel=0.0)
        # Brass collar clamp mid-pipe
        pl.cyl(b, 0.38, 0.20, p_m0.lerp(p_m1, 0.55), "Brass", rot_m, segs=8, bevel=0.0)
        # Flared Rust exhaust cowl mouth with deeply recessed red-orange ember glow
        pl.lathe(b, [
            (0.26, -0.10),
            (0.40, 0.24),
            (0.34, 0.28),
            (0.20, 0.08),
            (0.0, 0.08),
        ], p_m1, "Rust", rot_m, segs=8, bevel=0.0)
        pl.cyl(g, 0.19, 0.03, p_m1 + d_m * 0.10, rot=rot_m, segs=8, bevel=0.0)
        stack_tips[s] = p_m1 + d_m * 0.28

        # Copper steam feed pipe hugging the outer edge of the rear plate up into the manifold
        pl.pipe(b, [
            (s * 0.94, p_boiler.y, p_boiler.z + 0.34),
            (s * 1.28, 2.74, 3.65),
            (s * 1.18, 2.54, 5.38),
            (p_m0.x, p_m0.y + 0.06, p_m0.z + 0.18),
        ], r=0.12, color="Copper", joint="Brass", sides=6)

    return stack_tips


def build():
    k = pl.Kit(KEY, palette="cogwork", category="heavy", reset=True)
    b = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Gunmetal")
    g = k.glow("Glow", role="glow", pivot=(0, 0, 0), parent="Body")
    door = k.part("Door", "limb", "Metal", pivot=DOOR_HINGE, parent="Body", color="Gunmetal")
    door_glow = k.glow("DoorGlow", role="glow", pivot=DOOR_HINGE, parent="Door")

    build_base_and_hull(b, g)
    build_door(door, door_glow)
    build_warhead_ogive(b, g)
    build_stabilizer_fins(b)
    build_flanks(b, g)
    stack_tips = build_rear_machinery(b, g)

    # Named attachments for Luau wiring
    k.attachment("DoorHinge", DOOR_HINGE, part="Body")
    k.attachment("Beacon", (0.0, 0.0, 11.66), part="Body")
    k.attachment("StackL", tuple(stack_tips[-1]), part="Body")
    k.attachment("StackR", tuple(stack_tips[1]), part="Body")
    k.attachment("DeployExit", (0.0, -4.35, 1.35), part="Body")

    k.build()
    return k


def render_previews(k, root):
    """Render 3 clean preview PNGs directly into art/images/."""
    img_dir = os.path.join(root, "art", "images")
    os.makedirs(img_dir, exist_ok=True)
    shots = [
        ("", None, (0.66, -1.0, 0.42), 1.06),
        ("_open", {"Door": (radians(99), 0, 0)}, (0.50, -1.0, 0.36), 1.04),
        ("_back", None, (-0.68, 1.0, 0.42), 1.06),
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
