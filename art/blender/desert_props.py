"""Desert dressing prop kit for Orbitfall (Batch 1).

Props (1 BU = 1 Roblox stud, front = -Y, origin at ground centre):
  desert_crate_small    Small ammo/field supply crate (Olive/Charcoal, Steel clasps, Orange tabs)
  desert_crate_large    Heavy desert cargo crate (Tan/Charcoal, forklift skids, hazard strip, amber lamp)
  desert_barrel         Upright octagonal fuel barrel (Charcoal/Tan band, Orange cap, hazard collar)
  desert_barrel_tipped  Tipped-over fuel barrel on its side with knocked-loose bung and dark spill slick
  desert_pipe           Bolted desert pipeline segment on concrete saddles with Orange valve handwheel
  desert_pylon          Field power pylon with transformer box, insulators, beacon cage and severed cable stub
  desert_barrier        Short perimeter fence / armoured low-cover barrier segment with angled top rails
  desert_shrub          Spiky low-poly desert agave/scrub bush (terrain palette)
  desert_stalk          Tall dry desert stalk with basal spiky rosette and sun-bleached seed pods (terrain palette)

Headless:
  Blender -b -P art/blender/desert_props.py -- [--out <root>] [--only k1,k2] [--no-export] [--no-preview]
"""
import math
import os
import random
import sys
from math import cos, pi, radians, sin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.normpath(os.path.join(HERE, "..", "..", "helper")))
sys.path.insert(0, HERE)

import bpy
import bmesh
from mathutils import Euler, Matrix, Vector
import parts_lib as pl


# ---------------------------------------------------------------------
# SMALL GEOMETRY HELPERS
# ---------------------------------------------------------------------
def _facing(normal, up=(0, 0, 1)):
    """Euler for a local-XY plate whose +Z points along `normal`."""
    n = Vector(normal).normalized()
    u = Vector(up)
    x = u.cross(n)
    if x.length < 1e-4:
        x = Vector((1, 0, 0))
    return pl.basis(x, n)


def _poly_ring(center, x_ax, y_ax, rx, ry, sides=4, twist=0.0):
    c = Vector(center)
    pts = []
    for i in range(sides):
        a = twist + 2 * pi * i / sides
        pts.append(tuple(c + x_ax * (cos(a) * rx) + y_ax * (sin(a) * ry)))
    return pts


def _faceted_blade(part, origin, yaw, pitch, length, width, thick, bend=0.35, color="Swamp"):
    """Hard-faceted 3-ring diamond-section spiky desert leaf/frond (~20 tris, watertight)."""
    o = Vector(origin)
    horiz = Vector((cos(yaw), sin(yaw), 0.0))
    side = Vector((-sin(yaw), cos(yaw), 0.0))
    up = Vector((0.0, 0.0, 1.0))

    def pt_at(t):
        ang = pitch - bend * t * t
        r = length * t
        return o + horiz * (cos(ang) * r) + up * (sin(ang) * r)

    p0 = pt_at(0.0)
    p1 = pt_at(0.45)
    p2 = pt_at(1.0)

    def frame_axes(pa, pb):
        fwd = (pb - pa).normalized()
        n = side.cross(fwd).normalized()
        return side, n

    s0, n0 = frame_axes(p0, p1)
    s1, n1 = frame_axes(p0, p2)
    s2, n2 = frame_axes(p1, p2)

    r0 = _poly_ring(p0, s0, n0, width * 0.50, thick * 0.55, sides=4)
    r1 = _poly_ring(p1, s1, n1, width * 0.58, thick * 0.45, sides=4)
    r2 = _poly_ring(p2, s2, n2, width * 0.04, thick * 0.04, sides=4)
    pl.loft(part, [r0, r1, r2], color=color)


def _valve_wheel(part, loc, normal, R=0.42, color="Orange", hub_color="CharcoalDark"):
    """Low-poly octagonal valve handwheel (6 spokes, 8-sided rim)."""
    n = Vector(normal).normalized()
    o = Vector(loc)
    rot = pl.orient(n)
    m = rot.to_matrix()
    # Stem + hub
    pl.cyl(part, R * 0.22, R * 0.55, o - n * (R * 0.22), hub_color, rot, segs=6, bevel=0)
    pl.cyl(part, R * 0.28, R * 0.22, o, color, rot, segs=6, bevel=0)
    # Octagonal rim built from 8 short bars or low-poly torus
    pl.torus(part, R, R * 0.13, o, color, rot, segs=8, csegs=4)
    # 4 sturdy spokes
    for i in range(4):
        a = i * pi / 2 + pi / 4
        d = m @ Vector((cos(a), sin(a), 0.0))
        pl.rod(part, o + d * (R * 0.2), o + d * (R * 0.96), R * 0.09, color, segs=4)


# ---------------------------------------------------------------------
# 1. SUPPLY CRATE (SMALL — AMMO / FIELD CASE)
# ---------------------------------------------------------------------
def crate_small(reset=True):
    """Compact reinforced field ammo crate (2.6 x 1.8 x 1.6 studs)."""
    k = pl.Kit("desert_crate_small", palette="human", category="small_prop", reset=reset, seed=11)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")

    sx, sy, sz = 2.5, 1.7, 1.45
    z0 = 0.14  # skid height

    # Two heavy charcoal bottom skids (grime/dark lower contact)
    for x in (-sx * 0.34, sx * 0.34):
        pl.box(b, (0.36, sy * 1.04, z0), (x, 0, z0 / 2), "CharcoalDark", bevel=0.02)

    # Main olive ammo hull (chamfered)
    pl.box(b, (sx - 0.14, sy - 0.14, sz * 0.72), (0, 0, z0 + sz * 0.36), "Olive", bevel=0.04)
    # Darker lower grime cuff around base of box
    pl.box(b, (sx - 0.08, sy - 0.08, 0.22), (0, 0, z0 + 0.11), "CharcoalDark", bevel=0)

    # Overhanging heavy charcoal lid
    lid_h = sz * 0.26
    lid_z = z0 + sz - lid_h / 2
    pl.box(b, (sx + 0.04, sy + 0.04, lid_h), (0, 0, lid_z), "Charcoal", bevel=0.04)
    # Recessed olive top lid insert + two protective top ribs
    pl.box(b, (sx * 0.72, sy * 0.68, 0.08), (0, 0, z0 + sz + 0.02), "Olive", bevel=0)
    for x in (-sx * 0.24, sx * 0.24):
        pl.box(b, (0.18, sy * 0.86, 0.11), (x, 0, z0 + sz + 0.04), "CharcoalDark", bevel=0)

    # Heavy corner bumper pillars
    for x in (-1, 1):
        for y in (-1, 1):
            pl.box(b, (0.28, 0.28, sz + 0.04),
                   (x * (sx / 2 - 0.06), y * (sy / 2 - 0.06), z0 + sz / 2),
                   "CharcoalDark", bevel=0.02)

    # Twin steel clasp latches on front (-Y) with bright orange pull-tabs
    for x in (-sx * 0.28, sx * 0.28):
        pl.box(b, (0.22, 0.14, 0.42), (x, -sy / 2 - 0.05, z0 + sz * 0.68), "Steel", bevel=0)
        pl.box(b, (0.16, 0.18, 0.12), (x, -sy / 2 - 0.09, z0 + sz * 0.56), "Orange", bevel=0)
    # Rear hinges (+Y)
    for x in (-sx * 0.28, sx * 0.28):
        pl.box(b, (0.26, 0.14, 0.24), (x, sy / 2 + 0.05, z0 + sz * 0.74), "Steel", bevel=0)

    # Front stencil mark + orange ordnance stripe across lid lip
    pl.stencil_panel(b, 0.9, 0.46, (0, -sy / 2 - 0.05, z0 + sz * 0.38),
                     rot=(pi / 2, 0, 0), color="Charcoal", mark_color="Stencil", t=0.04)
    pl.box(b, (sx * 0.46, 0.06, 0.14), (0, -sy / 2 - 0.04, lid_z), "Orange", bevel=0)

    # Side bail carry handles
    for s in (-1, 1):
        pl.box(b, (0.14, 0.66, 0.12), (s * (sx / 2 + 0.05), 0, z0 + sz * 0.56), "Steel", bevel=0)
        for y in (-0.28, 0.28):
            pl.box(b, (0.12, 0.10, 0.16), (s * (sx / 2 + 0.02), y, z0 + sz * 0.56), "CharcoalDark", bevel=0)

    return k


# ---------------------------------------------------------------------
# 2. SUPPLY CRATE (LARGE — HEAVY CARGO CONTAINER)
# ---------------------------------------------------------------------
def crate_large(reset=True):
    """Heavy reinforced desert cargo crate (4.4 x 2.8 x 2.6 studs)."""
    k = pl.Kit("desert_crate_large", palette="human", category="prop", reset=reset, seed=22)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")
    g = k.glow("Glow", role="glow", parent="Body")

    sx, sy, sz = 4.3, 2.7, 2.35
    z0 = 0.24  # heavy forklift skids

    # Forklift skid runners + cross-ties
    for x in (-sx * 0.36, 0.0, sx * 0.36):
        pl.box(b, (0.48, sy + 0.12, z0), (x, 0, z0 / 2), "CharcoalDark", bevel=0.03)
    pl.box(b, (sx + 0.08, sy + 0.04, 0.18), (0, 0, z0 + 0.09), "CharcoalDark", bevel=0.02)

    # Inner armoured industrial burnt-orange cargo body with weathered rust lower grime band
    pl.box(b, (sx - 0.24, sy - 0.24, sz - 0.18), (0, 0, z0 + 0.09 + (sz - 0.18) / 2), "Orange", bevel=0.05)
    pl.box(b, (sx - 0.16, sy - 0.16, 0.46), (0, 0, z0 + 0.31), "Rebar", bevel=0)

    # Heavy exoskeleton Charcoal frame: 4 corner posts + mid ribs + upper collar
    for x in (-1, 1):
        for y in (-1, 1):
            pl.box(b, (0.46, 0.46, sz + 0.06),
                   (x * (sx / 2 - 0.14), y * (sy / 2 - 0.14), z0 + sz / 2),
                   "Charcoal", bevel=0.04)
            # Corner lifting lugs on top
            pl.box(b, (0.28, 0.28, 0.16),
                   (x * (sx / 2 - 0.16), y * (sy / 2 - 0.16), z0 + sz + 0.10),
                   "Steel", bevel=0)

    # Upper lid cap + bevelled deck
    pl.box(b, (sx + 0.06, sy + 0.06, 0.34), (0, 0, z0 + sz - 0.15), "Charcoal", bevel=0.04)
    pl.box(b, (sx * 0.72, sy * 0.66, 0.16), (0, 0, z0 + sz + 0.06), "Rebar", bevel=0.03)
    # Two cross clamping straps across top
    for x in (-sx * 0.22, sx * 0.22):
        pl.box(b, (0.26, sy + 0.12, 0.14), (x, 0, z0 + sz + 0.10), "CharcoalDark", bevel=0)
        pl.box(b, (0.26, 0.16, sz * 0.85), (x, -sy / 2 - 0.04, z0 + sz * 0.52), "CharcoalDark", bevel=0)
        pl.box(b, (0.26, 0.16, sz * 0.85), (x, sy / 2 + 0.04, z0 + sz * 0.52), "CharcoalDark", bevel=0)
        # Hazard latch cam on front strap
        pl.box(b, (0.30, 0.22, 0.34), (x, -sy / 2 - 0.10, z0 + sz * 0.76), "Hazard", bevel=0)

    # Side reinforcement ribs + heavy grab bars
    for s in (-1, 1):
        pl.box(b, (0.16, sy * 0.62, 0.20), (s * (sx / 2 - 0.04), 0, z0 + sz * 0.45), "CharcoalDark", bevel=0)
        pl.box(b, (0.18, 0.90, 0.14), (s * (sx / 2 + 0.06), 0, z0 + sz * 0.66), "Steel", bevel=0)

    # Hazard stripe across upper front lid lip + stencil on centre panel
    pl.hazard_stripes(b, sx * 0.42, 0.26, (0, -sy / 2 - 0.05, z0 + sz - 0.14),
                      rot=(pi / 2, 0, 0), stripes=4, c1="Hazard", c2="Black", t=0.04)
    pl.stencil_panel(b, 1.35, 0.72, (0, -sy / 2 - 0.06, z0 + sz * 0.44),
                     rot=(pi / 2, 0, 0), color="CharcoalDark", mark_color="Stencil", t=0.05)

    # Recessed warm amber status lamp on top corner
    pl.lamp(b, g, (-sx * 0.34, -sy * 0.20, z0 + sz + 0.03), (0, 0, 1), r=0.14, color="CharcoalDark", cage=True)

    return k


# ---------------------------------------------------------------------
# 3 & 4. FUEL BARREL (UPRIGHT + TIPPED-OVER)
# ---------------------------------------------------------------------
def _build_barrel_body(b, loc=(0, 0, 0), rot=(0, 0, 0), open_bung=False):
    """Build a faceted octagonal industrial fuel barrel in local space (bottom centre at loc)."""
    f = pl.frame(loc, rot)
    m = pl._rot(rot).to_matrix()
    h = 2.75
    r = 0.88

    # Lower grime drum + main charcoal hull (8-sided hard-faceted)
    pl.cyl(b, r, 0.68, f((0, 0, 0.34)), "Rebar", rot, segs=8, bevel=0)
    pl.cyl(b, r, h - 0.68, f((0, 0, 0.68 + (h - 0.68) / 2)), "Charcoal", rot, segs=8, bevel=0.03)

    # Industrial Orange painted fuel band around the waist
    pl.cyl(b, r + 0.025, 0.84, f((0, 0, h * 0.50)), "Orange", rot, segs=8, bevel=0)
    # Thin hazard warning band above waist
    pl.cyl(b, r + 0.03, 0.16, f((0, 0, h * 0.72)), "Hazard", rot, segs=8, bevel=0)

    # Rolled chime rims (bottom & top) + 2 chunky rolling hoops
    for z, rr, hh, col in (
        (0.08, r + 0.07, 0.16, "CharcoalDark"),
        (h * 0.32, r + 0.08, 0.14, "CharcoalDark"),
        (h * 0.66, r + 0.08, 0.14, "CharcoalDark"),
        (h - 0.09, r + 0.07, 0.18, "CharcoalDark"),
    ):
        pl.cyl(b, rr, hh, f((0, 0, z)), col, rot, segs=8, bevel=0.02)

    # Recessed top lid rim + recessed deck
    pl.cyl(b, r - 0.10, 0.08, f((0, 0, h - 0.06)), "Steel", rot, segs=8, bevel=0)
    # Vertical bolted weld seam strip down one facet
    pl.box(b, (0.14, 0.08, h - 0.24), f((0, -r - 0.01, h / 2)), "CharcoalDark", rot, bevel=0)

    # Top filler bung collar + vent plug + tie-down loop
    if not open_bung:
        pl.cyl(b, 0.18, 0.16, f((0.34, -0.20, h + 0.04)), "Orange", rot, segs=6, bevel=0)
        pl.cyl(b, 0.11, 0.18, f((0.34, -0.20, h + 0.07)), "CharcoalDark", rot, segs=6, bevel=0)
    else:
        # Open empty bung socket ring
        pl.cyl(b, 0.17, 0.10, f((0.34, -0.20, h + 0.01)), "CharcoalDark", rot, segs=6, bevel=0)
        pl.cyl(b, 0.10, 0.11, f((0.34, -0.20, h + 0.02)), "Black", rot, segs=6, bevel=0)
    pl.cyl(b, 0.11, 0.12, f((-0.36, 0.22, h + 0.02)), "Steel", rot, segs=6, bevel=0)

    # Stencil mark on front (-Y) of the orange band
    fr = m @ Euler((pi / 2, 0, 0)).to_matrix()
    pl.stencil_panel(b, 0.62, 0.44, f((0, -r - 0.03, h * 0.50)), fr, "CharcoalDark", "Stencil", t=0.03)


def fuel_barrel(reset=True):
    """Upright octagonal fuel drum (1.9 dia x 2.85 tall studs)."""
    k = pl.Kit("desert_barrel", palette="human", category="small_prop", reset=reset, seed=33)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")
    _build_barrel_body(b, loc=(0, 0, 0), rot=(0, 0, radians(22.5)), open_bung=False)
    return k


def fuel_barrel_tipped(reset=True):
    """Tipped-over fuel barrel lying on its side with knocked-loose cap and dark fuel spill."""
    k = pl.Kit("desert_barrel_tipped", palette="human", category="small_prop", reset=reset, seed=34)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")

    # Lie barrel along +X (top lid facing +X / slightly toward camera), rotated onto an octagonal flat
    rot = Euler((0, pi / 2, radians(-14)))
    _build_barrel_body(b, loc=(-1.35, 0.18, 0.92), rot=rot, open_bung=True)

    # Knocked-loose orange bung cap resting on the ground beside the spill
    pl.cyl(b, 0.17, 0.14, (1.45, -0.82, 0.07), "Orange", rot=(0, 0, radians(15)), segs=6, bevel=0)
    pl.cyl(b, 0.10, 0.16, (1.45, -0.82, 0.09), "CharcoalDark", rot=(0, 0, radians(15)), segs=6, bevel=0)

    # Low-poly dark fuel/oil spill slick seeping from the open mouth
    spill = [
        (0.95, -0.52, 0.0), (1.60, -0.70, 0.0), (2.30, -0.42, 0.0),
        (2.45, 0.15, 0.0), (2.02, 0.62, 0.0), (1.30, 0.52, 0.0), (0.90, 0.08, 0.0),
    ]
    spill_top = [(x * 0.97 + 0.05, y * 0.97, 0.035) for x, y, _ in spill]
    pl.loft(b, [spill, spill_top], color="Black")

    return k


# ---------------------------------------------------------------------
# 5. PIPE SECTION
# ---------------------------------------------------------------------
def pipe_section(reset=True):
    """Bolted desert pipeline segment on concrete saddles with Orange valve wheel (6.4 x 2.4 x 2.5 studs)."""
    k = pl.Kit("desert_pipe", palette="human", category="prop", reset=reset, seed=44)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")

    length = 6.2
    pr = 0.62
    pz = 1.25

    # Two heavy chamfered concrete footing blocks + charcoal steel saddle cradles
    for x in (-2.05, 2.05):
        pl.taper_box(b, (1.05, 2.10), (0.85, 1.75), 0.0, 0.72, "ConcreteDark", loc=(x, 0, 0), bevel=0.04)
        # Cradle cheeks hugging the pipe
        for y in (-0.62, 0.62):
            pl.box(b, (0.62, 0.34, 0.62), (x, y, 0.92), "CharcoalDark", bevel=0.02)
        # Over-top clamping strap + bolts
        pl.cyl(b, pr + 0.11, 0.32, (x, 0, pz), "CharcoalDark", pl.AX_X, segs=8, bevel=0)
        for y in (-0.72, 0.72):
            pl.bolt(b, (x, y, 1.22), (0, 0, 1), r=0.08, color="Steel", segs=6)

    # Main 8-sided pipe trunk along X
    pl.cyl(b, pr, length, (0, 0, pz), "Charcoal", pl.AX_X, segs=8, bevel=0)

    # Weathered rust-orange insulated mid-jacket sleeve + industrial orange collar + hazard ring
    pl.cyl(b, pr + 0.06, 2.5, (-0.35, 0, pz), "Rebar", pl.AX_X, segs=8, bevel=0.02)
    pl.cyl(b, pr + 0.075, 0.75, (-0.85, 0, pz), "Orange", pl.AX_X, segs=8, bevel=0)
    pl.cyl(b, pr + 0.08, 0.22, (1.02, 0, pz), "Hazard", pl.AX_X, segs=8, bevel=0)
    # Retention bands on sleeve
    for x in (-1.45, 0.75):
        pl.cyl(b, pr + 0.09, 0.14, (x, 0, pz), "CharcoalDark", pl.AX_X, segs=8, bevel=0)

    # Heavy bolted end flanges (modular connection ends)
    for s in (-1, 1):
        fx = s * (length / 2 - 0.14)
        pl.cyl(b, pr + 0.28, 0.26, (fx, 0, pz), "CharcoalDark", pl.AX_X, segs=8, bevel=0.03)
        pl.cyl(b, pr - 0.12, 0.08, (s * (length / 2 + 0.01), 0, pz), "Black", pl.AX_X, segs=8, bevel=0)
        pl.bolt_ring(b, (fx + s * 0.13, 0, pz), (s, 0, 0), pr + 0.17, 6, r=0.07, color="Steel")

    # Side junction tee + bright Hazard valve handwheel facing front (-Y) + top pressure gauge stub
    pl.cyl(b, 0.36, 0.55, (0.15, -0.58, pz), "CharcoalDark", pl.AX_Y, segs=8, bevel=0)
    pl.cyl(b, 0.44, 0.14, (0.15, -0.82, pz), "Steel", pl.AX_Y, segs=8, bevel=0)
    _valve_wheel(b, (0.15, -1.06, pz), (0, -1, 0), R=0.44, color="Hazard", hub_color="CharcoalDark")

    # Top pressure relief stub + dial cap
    pl.cyl(b, 0.14, 0.55, (-0.85, 0, pz + pr + 0.20), "Steel", segs=6, bevel=0)
    pl.cyl(b, 0.24, 0.16, (-0.85, 0, pz + pr + 0.50), "CharcoalDark", segs=8, bevel=0)
    pl.cyl(b, 0.17, 0.18, (-0.85, -0.02, pz + pr + 0.50), "Stencil", rot=pl.AX_Y, segs=6, bevel=0)

    return k


# ---------------------------------------------------------------------
# 6. POWER PYLON WITH CABLE STUB
# ---------------------------------------------------------------------
def power_pylon(reset=True):
    """Field utility power pylon with transformer box, insulators, lamp cage and sagging severed cable stub."""
    k = pl.Kit("desert_pylon", palette="human", category="prop", reset=reset, seed=55)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")
    g = k.glow("Glow", role="glow", parent="Body")

    # Concrete plinth base + bolted charcoal steel anchor plate
    pl.taper_box(b, (3.2, 3.0), (2.7, 2.5), 0.0, 0.65, "ConcreteDark", bevel=0.05)
    pl.box(b, (2.2, 2.0, 0.22), (0, 0, 0.76), "CharcoalDark", bevel=0.03)
    for sx in (-0.88, 0.88):
        for sy in (-0.78, 0.78):
            pl.bolt(b, (sx, sy, 0.88), (0, 0, 1), r=0.10, color="Steel", segs=6)

    # Four angled lower A-frame steel legs converging to a collar at z = 4.6
    for sx in (-1, 1):
        for sy in (-1, 1):
            pl.rod(b, (sx * 0.92, sy * 0.82, 0.82), (sx * 0.44, sy * 0.38, 4.6),
                   0.14, "Charcoal", segs=6)
    # Cross-bracing horizontal bars on lower lattice
    for z, w, d in ((2.1, 0.76, 0.68), (3.4, 0.59, 0.52)):
        pl.rod(b, (-w, -d, z), (w, -d, z), 0.07, "Steel", segs=4)
        pl.rod(b, (-w, d, z), (w, d, z), 0.07, "Steel", segs=4)
        pl.rod(b, (-w, -d, z), (-w, d, z), 0.07, "Steel", segs=4)
        pl.rod(b, (w, -d, z), (w, d, z), 0.07, "Steel", segs=4)

    # Central armoured spine column rising through lattice up to z = 10.6
    pl.taper_box(b, (0.76, 0.72), (0.64, 0.60), 0.82, 4.6, "CharcoalDark", bevel=0.03)
    # Mid collar with Tan armour sleeve + hazard band
    pl.taper_box(b, (1.18, 1.08), (0.96, 0.88), 4.45, 5.15, "CharcoalDark", bevel=0.04)
    pl.taper_box(b, (0.72, 0.68), (0.52, 0.50), 5.15, 10.5, "Charcoal", bevel=0.03)
    # Industrial Orange armoured collar wrap on mid-mast with weathered rust skirt
    pl.box(b, (0.82, 0.78, 1.65), (0, 0, 6.25), "Orange", bevel=0.03)
    pl.box(b, (0.84, 0.80, 0.34), (0, 0, 5.58), "Rebar", bevel=0)
    pl.hazard_stripes(b, 0.72, 0.28, (0, -0.40, 5.82), rot=(pi / 2, 0, 0), stripes=3)

    # Climbing pegs up the +X side of upper mast
    for z in (5.6, 6.5, 7.4, 8.3):
        pl.box(b, (0.34, 0.10, 0.08), (0.48, 0, z), "Steel", bevel=0)

    # Ground-side industrial Orange transformer / junction box with weathered rust base
    pl.box(b, (1.15, 0.90, 1.45), (-0.42, -0.82, 1.56), "Orange", bevel=0.04)
    pl.box(b, (1.18, 0.93, 0.34), (-0.42, -0.82, 1.00), "Rebar", bevel=0)
    pl.box(b, (1.22, 0.96, 0.16), (-0.42, -0.82, 2.32), "CharcoalDark", bevel=0.02)
    pl.vent_grille(b, 0.74, 0.46, 3, (-0.42, -1.28, 1.65), rot=(pi / 2, 0, 0),
                   color="CharcoalDark", slat_color="Black", depth=0.08)
    pl.hazard_stripes(b, 0.76, 0.20, (-0.42, -1.28, 1.15), rot=(pi / 2, 0, 0), stripes=4)
    # Conduit pipe from transformer box into central mast
    pl.tube(b, [(-0.42, -0.65, 2.32), (-0.42, -0.35, 3.1), (0.0, -0.35, 3.7)], 0.08, "CharcoalDark", sides=6)

    # Upper cross-arm at z = 9.2 with diagonal braces
    arm_z = 9.2
    pl.box(b, (4.3, 0.36, 0.36), (0, 0, arm_z), "CharcoalDark", bevel=0.03)
    for s in (-1, 1):
        pl.rod(b, (s * 0.30, 0, arm_z - 1.35), (s * 1.55, 0, arm_z - 0.10), 0.10, "Steel", segs=5)
        pl.box(b, (0.20, 0.42, 0.42), (s * 2.15, 0, arm_z), "Orange", bevel=0)

    # Three ceramic ribbed insulators (left, centre-offset, right)
    for ix in (-1.75, 1.75):
        pl.cyl(b, 0.09, 0.85, (ix, 0, arm_z + 0.48), "Steel", segs=6, bevel=0)
        for dz in (0.30, 0.50, 0.70):
            pl.cyl(b, 0.24, 0.11, (ix, 0, arm_z + dz), "Stencil", segs=8, bevel=0)
        pl.cyl(b, 0.16, 0.14, (ix, 0, arm_z + 0.88), "CharcoalDark", segs=6, bevel=0)

    # Recessed warm amber top beacon inside a protective cage
    pl.box(b, (0.72, 0.72, 0.24), (0, 0, 10.55), "CharcoalDark", bevel=0.02)
    pl.cyl(g, 0.24, 0.42, (0, 0, 10.88), segs=8, bevel=0)
    for i in range(4):
        a = i * pi / 2 + pi / 4
        pl.rod(b, (cos(a) * 0.32, sin(a) * 0.32, 10.65), (cos(a) * 0.30, sin(a) * 0.30, 11.18),
               0.04, "CharcoalDark", segs=4)
    pl.taper_box(b, (0.76, 0.76), (0.36, 0.36), 11.15, 11.40, "CharcoalDark", bevel=0)

    # Severed heavy power cable stub hanging from the right insulator (+X)
    cable_pts = [
        (1.75, 0.0, arm_z + 0.86),
        (2.15, -0.18, arm_z + 0.55),
        (2.38, -0.35, arm_z - 0.35),
        (2.26, -0.45, arm_z - 1.55),
        (2.05, -0.40, arm_z - 2.65),
        (2.18, -0.52, arm_z - 3.35),
    ]
    pl.tube(b, cable_pts, 0.10, "Black", sides=6)
    # Orange clamp collar near insulator + frayed steel/orange cut tip at end of stub
    pl.cyl(b, 0.15, 0.20, (2.02, -0.12, arm_z + 0.66), "Orange",
           pl.orient(Vector(cable_pts[1]) - Vector(cable_pts[0])), segs=6, bevel=0)
    end_p = Vector(cable_pts[-1])
    end_d = (end_p - Vector(cable_pts[-2])).normalized()
    pl.cyl(b, 0.13, 0.18, end_p, "CharcoalDark", pl.orient(end_d), segs=6, bevel=0)
    for ox, oy in ((-0.05, 0.04), (0.06, -0.03), (0.0, 0.06)):
        tip0 = end_p + Vector((ox, oy, 0))
        pl.rod(b, tip0, tip0 + end_d * 0.32 + Vector((ox * 1.8, oy * 1.8, -0.08)), 0.035, "Orange", segs=4)

    # Short taut stub on left insulator (-X) to imply broken line on both sides
    stub_l = [(-1.75, 0.0, arm_z + 0.86), (-2.18, 0.12, arm_z + 0.68), (-2.42, 0.20, arm_z + 0.25)]
    pl.tube(b, stub_l, 0.09, "Black", sides=6)

    return k


# ---------------------------------------------------------------------
# 7. SHORT FENCE / BARRIER SEGMENT
# ---------------------------------------------------------------------
def barrier_segment(reset=True):
    """Short armoured field fence / barrier segment (8.0 x 2.0 x 3.6 studs)."""
    k = pl.Kit("desert_barrier", palette="human", category="prop", reset=reset, seed=66)
    b = k.part("Body", role="body", material="Metal", color="Charcoal")

    W = 7.6
    H_low = 1.95
    H_top = 3.45

    # Two heavy concrete footing pads + Charcoal H-posts + rear diagonal braces
    for s in (-1, 1):
        px = s * (W / 2 - 0.15)
        pl.taper_box(b, (1.15, 1.85), (0.90, 1.50), 0.0, 0.50, "ConcreteDark", loc=(px, 0.10, 0), bevel=0.04)
        pl.box(b, (0.42, 0.42, H_top), (px, 0, H_top / 2), "CharcoalDark", bevel=0.03)
        # Angled security overhang bracket at top of post
        pl.rod(b, (px, 0, H_top - 0.08), (px, -0.58, H_top + 0.42), 0.12, "CharcoalDark", segs=6)
        # Orange end-cap marker on post cap
        pl.box(b, (0.46, 0.46, 0.14), (px, 0, H_top + 0.04), "Orange", bevel=0)
        # Rear stabilizer strut down to concrete foot
        pl.rod(b, (px, 0.16, 2.25), (px, 0.92, 0.38), 0.11, "Charcoal", segs=6)
        pl.box(b, (0.54, 0.56, 0.24), (px, 0.92, 0.12), "ConcreteDark", bevel=0.02)

    # Lower solid blast/cover wall: Charcoal base rail + Tan armoured shield plate
    pl.box(b, (W - 0.2, 0.52, 0.34), (0, 0, 0.17), "CharcoalDark", bevel=0.02)
    pl.box(b, (W - 0.5, 0.30, H_low - 0.36), (0, 0, 0.34 + (H_low - 0.36) / 2), "Charcoal", bevel=0.03)

    # Two bolted industrial burnt-orange front armour panels with weathered rust-grime lower band
    for x in (-1.75, 1.75):
        pl.box(b, (3.1, 0.14, 1.18), (x, -0.18, 1.12), "Orange", bevel=0.03)
        # Weathered grime/rust lower third on armour plate
        pl.box(b, (3.12, 0.16, 0.42), (x, -0.18, 0.72), "Rebar", bevel=0)
        for bx in (-1.35, 1.35):
            for bz in (0.72, 1.54):
                pl.bolt(b, (x + bx, -0.26, bz), (0, -1, 0), r=0.06, color="Steel", segs=6)

    # Centre reinforcing upright + stencil plate
    pl.box(b, (0.34, 0.44, H_low + 0.15), (0, 0, (H_low + 0.15) / 2), "CharcoalDark", bevel=0.02)
    pl.stencil_panel(b, 1.10, 0.52, (-1.75, -0.26, 1.18), rot=(pi / 2, 0, 0),
                     color="CharcoalDark", mark_color="Stencil", t=0.03)

    # Mid-rail coping beam with hazard stripe along front face
    pl.box(b, (W - 0.1, 0.42, 0.24), (0, 0, H_low + 0.08), "CharcoalDark", bevel=0.02)
    pl.hazard_stripes(b, 2.4, 0.20, (1.75, -0.22, H_low + 0.08), rot=(pi / 2, 0, 0), stripes=5)

    # Upper open security fence: horizontal rails + sturdy vertical steel bars + top overhang wire rail
    for z in (2.55, 3.22):
        pl.box(b, (W - 0.2, 0.14, 0.14), (0, 0, z), "Charcoal", bevel=0)
    # Overhang rail along the angled brackets
    pl.box(b, (W - 0.1, 0.12, 0.12), (0, -0.52, H_top + 0.36), "Steel", bevel=0)
    # Vertical fence pickets
    for i in range(7):
        x = -2.7 + i * 0.90
        pl.box(b, (0.10, 0.10, 1.38), (x, 0, 2.74), "Steel", bevel=0)

    return k


# ---------------------------------------------------------------------
# 8. DRY DESERT PLANT A — SPIKY SHRUB
# ---------------------------------------------------------------------
def desert_shrub(reset=True):
    """Hard-faceted chunky spiky desert agave/scrub shrub (terrain palette, < 400 tris)."""
    k = pl.Kit("desert_shrub", palette="terrain", category="plant", reset=reset, seed=77)
    b = k.part("Body", role="body", material="Slate", color="Bark")

    rng = random.Random(77)

    # Gnarled woody root crown base gripping the sand
    pl.taper_box(b, (1.35, 1.25), (0.85, 0.78), 0.0, 0.52, "Bark", rot=(0, 0, radians(18)), bevel=0)
    pl.taper_box(b, (0.90, 0.82), (0.52, 0.48), 0.0, 0.42, "RockDark", loc=(0.40, -0.22, 0.0),
                 rot=(0, 0, radians(-28)), bevel=0)

    # Outer ring: 7 broad chunky splayed dry agave blades
    n_outer = 7
    for i in range(n_outer):
        yaw = i * 2 * pi / n_outer + rng.uniform(-0.16, 0.16)
        pitch = radians(rng.uniform(24, 36))
        length = rng.uniform(1.65, 2.15)
        col = "Swamp" if i % 2 == 0 else "Moss"
        _faceted_blade(b, (cos(yaw) * 0.24, sin(yaw) * 0.24, 0.20),
                       yaw, pitch, length, width=0.52, thick=0.22,
                       bend=radians(20), color=col)

    # Inner ring: 5 steeper spiky fronds rising higher
    n_mid = 5
    for i in range(n_mid):
        yaw = i * 2 * pi / n_mid + 0.42 + rng.uniform(-0.14, 0.14)
        pitch = radians(rng.uniform(50, 64))
        length = rng.uniform(1.50, 1.95)
        _faceted_blade(b, (cos(yaw) * 0.14, sin(yaw) * 0.14, 0.34),
                       yaw, pitch, length, width=0.42, thick=0.19,
                       bend=radians(14), color="Moss" if i % 2 == 0 else "Bark")

    # 3 sun-bleached pale dry crown spears (subtle dry-bone accent)
    for yaw, pitch, length in ((0.85, 1.24, 1.85), (3.05, 1.12, 1.65), (5.05, 1.18, 1.75)):
        _faceted_blade(b, (0, 0, 0.38), yaw, pitch, length, width=0.26, thick=0.18,
                       bend=radians(8), color="Bone")

    return k


# ---------------------------------------------------------------------
# 9. DRY DESERT PLANT B — TALL DRY STALK / GNARLED DESERT TREE
# ---------------------------------------------------------------------
def _sharp_spike(part, base, direction, length, r, color, segs=3):
    """Ultra-low-poly hard-faceted pyramid spike (4–6 tris, zero bevel)."""
    d = Vector(direction).normalized()
    c = Vector(base) + d * (length * 0.5)
    pl.cyl(part, r, length, c, color, pl.orient(d), segs=segs, r2=0.0, bevel=0)


def _crown_tuft(part, origin, scale=1.0, seed=0):
    """Spiky Joshua-tree / desert yucca crown: drooping dead skirt, radiating dry fronds, bleached spire."""
    rng = random.Random(seed)
    o = Vector(origin)
    # Central dry woody knot
    pl.cyl(part, 0.18 * scale, 0.26 * scale, o, "Bark", segs=3, bevel=0)
    # Drooping dead brown/rust collar leaves underneath the tuft
    for i in range(3):
        yaw = i * 2 * pi / 3 + rng.uniform(-0.22, 0.22)
        d = Vector((cos(yaw) * 0.72, sin(yaw) * 0.72, -0.70)).normalized()
        _sharp_spike(part, o + Vector((0, 0, -0.05 * scale)), d, 0.65 * scale, 0.14 * scale,
                     color="Strata" if i % 2 == 0 else "Bark", segs=3)
    # 5 outward-radiating spiky dry desert fronds (Swamp/Moss)
    for i in range(5):
        yaw = i * 2 * pi / 5 + 0.3 + rng.uniform(-0.18, 0.18)
        elev = rng.uniform(0.18, 0.62)
        d = Vector((cos(yaw), sin(yaw), elev)).normalized()
        _sharp_spike(part, o + Vector((0, 0, 0.04 * scale)), d, rng.uniform(0.82, 1.12) * scale,
                     0.15 * scale, color="Moss" if i % 2 == 0 else "Swamp", segs=3)
    # 2 steeper sun-bleached pale inner needles + central dry seed spire
    for i in range(2):
        yaw = i * pi + 0.4 + rng.uniform(-0.2, 0.2)
        d = Vector((cos(yaw) * 0.36, sin(yaw) * 0.36, 0.93)).normalized()
        _sharp_spike(part, o + Vector((0, 0, 0.08 * scale)), d, 0.78 * scale, 0.11 * scale,
                     color="Bone", segs=3)
    _sharp_spike(part, o + Vector((0, 0, 0.08 * scale)), (0, 0, 1), 0.72 * scale, 0.21 * scale,
                 color="Sand", segs=4)


def desert_stalk(reset=True):
    """Detailed gnarled dry desert tree / stalk with buttressed roots, multi-fork branches & spiky crown tufts."""
    k = pl.Kit("desert_stalk", palette="terrain", category="small_prop", reset=reset, seed=88)
    b = k.part("Body", role="body", material="Slate", color="Bark")

    rng = random.Random(88)

    # Root mound + 4 flared angular surface roots gripping the desert floor
    pl.taper_box(b, (1.25, 1.15), (0.72, 0.68), 0.0, 0.52, "Bark", rot=(0, 0, radians(14)), bevel=0)
    for i in range(4):
        yaw = i * pi / 2 + 0.35 + rng.uniform(-0.2, 0.2)
        p0 = Vector((cos(yaw) * 0.28, sin(yaw) * 0.28, 0.62))
        p1 = Vector((cos(yaw) * 0.82, sin(yaw) * 0.82, 0.24))
        p2 = Vector((cos(yaw) * 1.25, sin(yaw) * 1.25, 0.04))
        pl.rod(b, p0, p1, 0.18, "Bark", segs=4, r2=0.13)
        pl.rod(b, p1, p2, 0.13, "RockDark", segs=4, r2=0.06)

    # 6 chunky spiky basal scrub blades around the root crown
    for i in range(6):
        yaw = i * 2 * pi / 6 + 0.12 + rng.uniform(-0.15, 0.15)
        d = Vector((cos(yaw), sin(yaw), rng.uniform(0.35, 0.68))).normalized()
        _sharp_spike(b, (cos(yaw) * 0.32, sin(yaw) * 0.32, 0.18), d, rng.uniform(1.18, 1.58), 0.20,
                     color="Swamp" if i % 2 == 0 else "Strata", segs=3)

    # Main twisted 5-sided gnarled trunk with bark collars rising to the main fork at z = 4.6
    trunk_pts = [
        ((0.0, 0.0, 0.22), 0.42),
        ((0.14, -0.08, 1.45), 0.34),
        ((-0.10, 0.12, 2.75), 0.28),
        ((0.08, 0.06, 4.10), 0.23),
        ((0.02, -0.04, 5.45), 0.17),
        ((0.12, -0.10, 6.65), 0.12),
    ]
    rings = []
    for idx, ((x, y, z), rad) in enumerate(trunk_pts):
        tw = idx * 0.22
        rings.append([(x + cos(tw + 2 * pi * i / 5) * rad, y + sin(tw + 2 * pi * i / 5) * rad, z) for i in range(5)])
    pl.loft(b, rings[:4], color="Bark")
    pl.loft(b, rings[3:], color="SandDark")

    # Knobby dry bark collar rings along the lower trunk
    for (x, y, z), rad in trunk_pts[1:4]:
        pl.cyl(b, rad * 1.24, 0.20, (x, y, z), "RockDark", segs=5, bevel=0)

    # Snapped dry dead stub sticking out mid-trunk for asymmetric character
    pl.rod(b, (0.10, -0.06, 2.05), (0.68, -0.42, 2.48), 0.13, "Bark", segs=4, r2=0.07)
    _sharp_spike(b, (0.66, -0.41, 2.47), (0.75, -0.45, 0.55), 0.38, 0.08, color="SandDark", segs=3)

    # Multi-forked crooked boughs (primary limbs + secondary forks)
    limbs = [
        # Left major bough + sub-fork
        (Vector((-0.08, 0.10, 2.95)), Vector((-0.92, -0.32, 3.65)), Vector((-1.42, -0.52, 4.88)), 0.20, 0.11),
        (Vector((-0.92, -0.32, 3.65)), Vector((-1.10, 0.38, 4.25)), Vector((-1.32, 0.68, 5.15)), 0.13, 0.08),
        # Right major bough + sub-fork
        (Vector((0.06, 0.05, 3.85)), Vector((0.95, 0.34, 4.45)), Vector((1.40, 0.52, 5.65)), 0.18, 0.10),
        (Vector((0.95, 0.34, 4.45)), Vector((1.28, -0.25, 4.92)), Vector((1.52, -0.48, 5.60)), 0.12, 0.08),
        # Upper front-left offshoot
        (Vector((0.04, -0.02, 5.05)), Vector((-0.58, -0.46, 5.65)), Vector((-0.78, -0.62, 6.45)), 0.13, 0.08),
    ]
    for p0, p1, p2, r0, r1 in limbs:
        mid_r = (r0 + r1) * 0.54
        pl.rod(b, p0, p1, r0, "Bark", segs=4, r2=mid_r)
        pl.rod(b, p1, p2, mid_r, "SandDark", segs=4, r2=r1)
        # Elbow bark knot
        pl.cyl(b, mid_r * 1.32, 0.16, p1, "Bark", segs=4, bevel=0)

    # Rich spiky Joshua-tree / yucca crown tufts on apex + every branch tip
    tufts = [
        ((0.12, -0.10, 6.68), 1.12, 101),
        ((-1.42, -0.52, 4.90), 0.96, 102),
        ((-1.32, 0.68, 5.18), 0.78, 103),
        ((1.40, 0.52, 5.68), 0.95, 104),
        ((1.52, -0.48, 5.62), 0.76, 105),
        ((-0.78, -0.62, 6.48), 0.82, 106),
    ]
    for pos, sc, sd in tufts:
        _crown_tuft(b, pos, scale=sc, seed=sd)

    return k


BUILDERS = {
    "desert_crate_small": crate_small,
    "desert_crate_large": crate_large,
    "desert_barrel": fuel_barrel,
    "desert_barrel_tipped": fuel_barrel_tipped,
    "desert_pipe": pipe_section,
    "desert_pylon": power_pylon,
    "desert_barrier": barrier_segment,
    "desert_shrub": desert_shrub,
    "desert_stalk": desert_stalk,
}


# ---------------------------------------------------------------------
# BUILD + GROUND + EXPORT + BATCH PREVIEW
# ---------------------------------------------------------------------
def _finalize_kit(k):
    """Center X/Y, build merged meshes, ground true mesh minimum to z=0."""
    k.center()
    k.build()
    lo, _ = k.bbox()
    if abs(lo.z) > 1e-4:
        for p in k.parts:
            p.obj.location.z -= lo.z
            p.pivot.z -= lo.z
        bpy.context.view_layer.update()
    return k


def _rebind_palettes(kits):
    """Point all kits on shared palettes at the live image (avoids orphaned images)."""
    for k in kits:
        img = bpy.data.images.get(f"palette_{k.palette_name}")
        if img:
            k.image = img
            for p in k.parts:
                for n in p.obj.data.materials[0].node_tree.nodes:
                    if n.type == "TEX_IMAGE":
                        n.image = img


def _lin(rgb):
    return (*pl.srgb_to_linear(tuple(c / 255.0 for c in rgb)), 1.0)


def render_batch_preview(out_png, keys, size=(1920, 1080)):
    """Render all props in a crisp 2-row 3/4 lineup on a plain neutral background."""
    kits = []
    for i, key in enumerate(keys):
        k = _finalize_kit(BUILDERS[key](reset=(i == 0)))
        kits.append(k)
    _rebind_palettes(kits)

    # Arrange in two neat staggered rows so tall pieces don't dwarf small props:
    # Back row (tall / wide): pylon, stalk, barrier, pipe
    # Front row (compact): crate_large, crate_small, barrel, barrel_tipped, shrub
    back_order = [k for k in ("desert_pylon", "desert_stalk", "desert_barrier", "desert_pipe") if k in keys]
    front_order = [k for k in ("desert_crate_large", "desert_crate_small", "desert_barrel",
                               "desert_barrel_tipped", "desert_shrub") if k in keys]
    # Any remaining keys go in front row
    placed_keys = set(back_order) | set(front_order)
    front_order += [k for k in keys if k not in placed_keys]

    by_key = {k.key: k for k in kits}

    def layout_row(row_keys, y_pos, gap):
        widths = []
        for rk in row_keys:
            lo, hi = by_key[rk].bbox()
            widths.append(hi.x - lo.x)
        total_w = sum(widths) + gap * max(0, len(row_keys) - 1)
        x = -total_w / 2.0
        for rk, w in zip(row_keys, widths):
            k = by_key[rk]
            lo, hi = k.bbox()
            dx = x - lo.x
            dy = y_pos - (lo.y + hi.y) / 2.0
            for p in k.parts:
                p.obj.location.x += dx
                p.obj.location.y += dy
            x += w + gap

    if back_order:
        layout_row(back_order, y_pos=3.8, gap=2.0)
    if front_order:
        layout_row(front_order, y_pos=-2.4, gap=1.8)

    bpy.context.view_layer.update()

    # Compute overall bounds
    lo_all = Vector((1e9, 1e9, 1e9))
    hi_all = Vector((-1e9, -1e9, -1e9))
    for k in kits:
        lo, hi = k.bbox()
        lo_all = Vector((min(lo_all.x, lo.x), min(lo_all.y, lo.y), min(lo_all.z, lo.z)))
        hi_all = Vector((max(hi_all.x, hi.x), max(hi_all.y, hi.y), max(hi_all.z, hi.z)))

    sc = bpy.context.scene
    col = bpy.data.collections.new("_preview_stage")
    sc.collection.children.link(col)

    # Plain studio matte ground catching soft contact shadows
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=240)
    gme = bpy.data.meshes.new("_ground")
    bm.to_mesh(gme)
    bm.free()
    g_ob = bpy.data.objects.new("_ground", gme)
    g_ob.location = ((lo_all.x + hi_all.x) / 2, (lo_all.y + hi_all.y) / 2, -0.01)
    gm = bpy.data.materials.new("_ground_mat")
    gm.use_nodes = True
    gb = gm.node_tree.nodes.get("Principled BSDF")
    gb.inputs["Base Color"].default_value = _lin((176, 172, 165))
    gb.inputs["Roughness"].default_value = 0.96
    gme.materials.append(gm)
    col.objects.link(g_ob)

    # Clean 3-point studio sun rig
    for name, rot, energy, ang in (
        ("_key", (radians(52), 0, radians(-28)), 3.4, 3.0),
        ("_fill", (radians(65), 0, radians(140)), 1.0, 22.0),
        ("_rim", (radians(42), 0, radians(195)), 1.2, 8.0),
    ):
        ld = bpy.data.lights.new(name, "SUN")
        ld.energy = energy
        ld.angle = radians(ang)
        lob = bpy.data.objects.new(name, ld)
        lob.rotation_euler = rot
        col.objects.link(lob)

    world = sc.world or bpy.data.worlds.new("World")
    sc.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = _lin((194, 190, 184))
    bg.inputs[1].default_value = 0.85

    # Camera: crisp 3/4 view framing all props cleanly
    camd = bpy.data.cameras.new("_cam")
    camd.lens = 45
    cam = bpy.data.objects.new("_cam", camd)
    col.objects.link(cam)
    sc.camera = cam

    ctr = Vector(((lo_all.x + hi_all.x) / 2, (lo_all.y + hi_all.y) / 2 - 0.3, (lo_all.z + hi_all.z) * 0.44))
    cam_dir = Vector((0.42, -1.0, 0.42)).normalized()

    # Exact projected bounding fit so nothing clips and margins stay tight
    rot_q = (-cam_dir).to_track_quat("-Z", "Y")
    right = rot_q @ Vector((1, 0, 0))
    up_v = rot_q @ Vector((0, 1, 0))
    corners = [
        Vector((x, y, z)) - ctr
        for x in (lo_all.x, hi_all.x)
        for y in (lo_all.y, hi_all.y)
        for z in (lo_all.z, hi_all.z)
    ]
    aspect = size[0] / size[1]
    fov_x = 2 * math.atan(18.0 / camd.lens)  # 36mm sensor
    fov_y = 2 * math.atan(math.tan(fov_x / 2) / aspect)
    dist = 8.0
    for c in corners:
        px = abs(c.dot(right))
        py = abs(c.dot(up_v))
        pz = c.dot(cam_dir)
        dist = max(dist, pz + px / math.tan(fov_x / 2) * 1.04, pz + py / math.tan(fov_y / 2) * 1.06)

    cam.location = ctr + cam_dir * dist
    cam.rotation_euler = rot_q.to_euler()
    camd.clip_start, camd.clip_end = 0.1, dist * 6

    r = sc.render
    r.resolution_x, r.resolution_y = size
    r.resolution_percentage = 100
    r.image_settings.file_format = "PNG"
    sc.view_settings.view_transform = "Standard"
    for eng in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "BLENDER_WORKBENCH"):
        try:
            r.engine = eng
            break
        except Exception:
            pass
    try:
        sc.eevee.use_shadows = True
    except Exception:
        pass

    os.makedirs(os.path.dirname(out_png), exist_ok=True)
    r.filepath = out_png
    bpy.ops.render.render(write_still=True)
    print(f"[desert_props] preview -> {out_png}")
    return out_png


def main():
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = os.path.abspath(a[a.index("--out") + 1]) if "--out" in a else os.path.normpath(os.path.join(HERE, "..", ".."))
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = "FBX_SCALE_ALL"

    keys = a[a.index("--only") + 1].split(",") if "--only" in a else list(BUILDERS)
    do_export = "--no-export" not in a
    do_preview = "--no-preview" not in a

    # Build + check + export each prop cleanly in its own scene
    for key in keys:
        k = _finalize_kit(BUILDERS[key](reset=True))
        k.report()
        if do_export:
            k.export_fbx()
            k.write_manifest()

    if do_preview:
        out_png = os.path.join(root, "art", "images", "previews", "desert_props_batch1.png")
        render_batch_preview(out_png, keys)


if __name__ == "__main__":
    main()
