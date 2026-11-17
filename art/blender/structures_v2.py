"""Structures v2: fabricator, env_cog_pylon (Cog family), sample_pod, courier_wreck (Squad family).

Drop-in rebuilds of the old models in the call-in art style (art/STYLE.md, helper/COGWORK_STYLE.md),
built with helper/parts_lib.py. Same part names / roles / parents / pivots as the old manifest entries,
same facing (Blender -Y front, Z up) and the same origin convention.

Headless:
  Blender -b --factory-startup --python art/blender/structures_v2.py -- <scratch root> [key ...]
Each model is built in its own fresh scene, exported (FBX_SCALE_ALL) BEFORE it is rendered, then copied to
art/fbx/new/<key>.fbx (+ palette png + <key>.entry.json). Previews go to art/images/<key>_new_front|back.png.
"""
import json
import os
import shutil
import sys
from math import pi, radians, atan2, tan

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "helper"))
sys.path.insert(0, HERE)
import bpy
import env_set1            # imports (and reloads) parts_lib; used for stage()
import parts_lib as pl
from mathutils import Vector, Matrix

FR = (pi / 2, 0, 0)        # a plate's local +Z -> world -Y (faces the front)
RX = (0, pi / 2, 0)        # local +Z -> +X
LX = (0, -pi / 2, 0)       # local +Z -> -X


# ------------------------------------------------------------------ local frame helper (posed sections)
class G:
    """A posed local frame: place pieces in section coordinates, they land in world coordinates."""

    def __init__(self, loc=(0, 0, 0), rot=(0, 0, 0)):
        self.o = Vector(loc)
        self.m = pl._rot(rot).to_matrix()

    def P(self, p):
        return self.o + self.m @ Vector(p)

    def R(self, rot=(0, 0, 0)):
        return self.m @ pl._rot(rot).to_matrix()

    def sub(self, loc, rot=(0, 0, 0)):
        g = G()
        g.o, g.m = self.P(loc), self.R(rot)
        return g

    def box(self, part, size, loc, color=None, rot=(0, 0, 0), bevel=None):
        return pl.box(part, size, self.P(loc), color, self.R(rot), bevel)

    def cyl(self, part, r, depth, loc, color=None, rot=(0, 0, 0), segs=12, r2=None, bevel=None):
        return pl.cyl(part, r, depth, self.P(loc), color, self.R(rot), segs, r2, bevel)

    def loft(self, part, rings, color=None, bevel=0, cap=True):
        return pl.loft(part, rings, self.o, color, self.m, cap=cap, bevel=bevel)

    def taper_box(self, part, bot, top, z0, z1, color=None, top_offset=(0, 0), loc=(0, 0, 0), rot=(0, 0, 0), bevel=None):
        return pl.taper_box(part, bot, top, z0, z1, color, top_offset, self.P(loc), self.R(rot), bevel)

    def rod(self, part, p0, p1, r, color=None, segs=8, r2=None, bevel=0):
        return pl.rod(part, self.P(p0), self.P(p1), r, color, segs, r2, bevel)

    def extrude(self, part, profile, depth, loc, color=None, rot=(0, 0, 0), plane='XZ', bevel=None):
        return pl.extrude(part, profile, depth, self.P(loc), color, self.R(rot), plane, bevel)

    def plate(self, part, w, h, t, loc, rot=(0, 0, 0), color=None, chamfer=0.25, bevel=None):
        return pl.plate(part, w, h, t, self.P(loc), self.R(rot), color, chamfer, bevel)

    def riveted(self, part, w, h, t, loc, rot, color, rivet_color, **kw):
        return pl.riveted_plate(part, w, h, t, self.P(loc), self.R(rot), color, rivet_color, **kw)

    def haz(self, part, w, h, loc, rot=(0, 0, 0), **kw):
        return pl.hazard_stripes(part, w, h, self.P(loc), self.R(rot), **kw)

    def fin(self, part, root, tip, span, loc, rot=(0, 0, 0), sweep=None, t=0.1, color=None):
        return pl.fin(part, root, tip, span, self.P(loc), self.R(rot), sweep, t, color)

    def ico(self, part, r, loc, color=None, subdiv=1, scale=(1, 1, 1), rot=(0, 0, 0), jitter=0.0, seed=None):
        return pl.ico(part, r, self.P(loc), color, subdiv, scale, self.R(rot), jitter, seed)


def ring(y, hx, hz, c, cz=0.0, dx=0.0):
    """Octagon cross-section ring at station y (axis along Y)."""
    return [(dx + x, y, cz + z) for x, z in pl.chamfer_rect(hx, hz, c)]


def cog_lens_mark(part, loc, normal, r):
    """Cog faction mark on a front face: brass gear, dark rim, recessed dark-red lens (no glow)."""
    n = Vector(normal).normalized()
    o = Vector(loc)
    pl.gear(part, r, r * 0.8, 10, r * 0.22, o + n * r * 0.1, "Brass", pl.orient(n))
    pl.torus(part, r * 0.44, r * 0.1, o + n * r * 0.3, "GunmetalDark", pl.orient(n), segs=10, csegs=4)
    pl.cyl(part, r * 0.46, r * 0.06, o + n * r * 0.22, "Lens", pl.orient(n), segs=10, bevel=0)


# ================================================================== FABRICATOR (Cog, enemy_building)
def fabricator():
    """Cog forge-hall: riveted gunmetal hall on a rust-skirted plinth, loading bay with a furnace door and a
    conveyor ramp, CogRed front panels with a gear cluster and the Cog mark, rear boiler drum, three smokestacks,
    and the glowing grille Vent (weak spot) on a hazard-marked pedestal on the roof."""
    k = pl.Kit("fabricator", palette="cogwork", category="set_piece", reset=True)
    b = k.part("Body", "body", "SmoothPlastic", pivot=(0, 0, 0), color="Gunmetal")
    v = k.glow("Vent", role="weak", pivot=(4.4, -2.2, 8.15), parent="Body")

    HX, FY, BY = 7.2, -6.2, 4.6          # hall half width, front face y, back face y
    Z0, ZW, ZR = 0.5, 6.4, 6.9           # plinth top, wall top, roof top
    DW, DT = 2.2, 4.6                    # bay half width, bay top

    # plinth: dark slab with a rust lower edge, apron in front
    pl.taper_box(b, (16.2, 13.0), (15.9, 12.7), 0, Z0, "GunmetalDark", loc=(0, -0.4, 0))
    pl.box(b, (16.4, 13.2, 0.22), (0, -0.4, 0.11), "Rust", bevel=0)
    pl.hazard_stripes(b, 4.4, 0.6, (0, -6.62, Z0 + 0.02), stripes=6)          # apron warning strip

    # hall: two wing blocks, rear mass, lintel and corner wedges that make the bay an octagon
    wh = ZW - Z0
    for s in (1, -1):
        pl.box(b, (HX - DW, BY - FY, wh), (s * (HX + DW) / 2, (FY + BY) / 2, Z0 + wh / 2), "Gunmetal", bevel=0.06)
        pl.extrude(b, [(s * DW, DT - 0.9), (s * DW, DT), (s * (DW - 0.9), DT)], 3.0, (0, -4.7, 0),
                   "Gunmetal", plane='XZ', bevel=0)
    pl.box(b, (2 * DW, BY + 3.2, wh), (0, (BY - 3.2) / 2, Z0 + wh / 2), "Gunmetal", bevel=0)
    pl.box(b, (2 * DW, 3.0, ZW - DT), (0, -4.7, (DT + ZW) / 2), "Gunmetal", bevel=0)
    # bay interior: dark back wall, furnace door (brass ring, bolts, dark red lens), floor
    pl.box(b, (2 * DW - 0.1, 0.1, 4.1), (0, -3.25, Z0 + 2.05), "Oil", bevel=0)
    fn = pl.orient((0, -1, 0))
    pl.torus(b, 1.15, 0.14, (0, -3.34, 2.6), "Brass", fn, segs=12, csegs=4)
    pl.cyl(b, 1.12, 0.08, (0, -3.31, 2.6), "Lens", fn, segs=12, bevel=0)
    pl.bolt_ring(b, (0, -3.36, 2.6), (0, -1, 0), 0.82, 4, 0.06, "Steel")
    pl.box(b, (1.8, 0.1, 0.12), (0, -3.38, 2.6), "Brass", bevel=0)
    pl.box(b, (2 * DW, 3.0, 0.12), (0, -4.7, Z0 + 0.06), "GunmetalDark", bevel=0)
    # corner pilasters
    for sx in (1, -1):
        for yy in (FY + 0.2, BY - 0.2):
            pl.box(b, (0.55, 0.55, wh + 0.1), (sx * (HX - 0.05), yy, Z0 + wh / 2), "GunmetalDark", bevel=0)
    # roof slab (dark, overhanging), CogRed brow over the bay
    pl.taper_box(b, (15.2, 11.8), (14.6, 11.2), ZW, ZR, "GunmetalDark", loc=(0, -0.8, 0))
    pl.taper_box(b, (5.8, 1.3), (5.3, 1.0), ZW - 0.45, ZW + 0.05, "CogRed", loc=(0, -6.75, 0))
    pl.box(b, (14.6, 0.14, 0.2), (0, FY - 0.05, 5.95), "Brass", bevel=0)           # brass trim band
    for s in (1, -1):
        pl.box(b, (HX - DW, 0.14, 0.5), (s * (HX + DW) / 2, FY - 0.05, 0.78), "Rust", bevel=0)   # worn skirt

    # front: two CogRed riveted panels, gear cluster on the left third of the left one, Cog mark over the bay
    for s in (1, -1):
        pl.riveted_plate(b, 3.6, 3.2, 0.2, (s * 4.8, FY - 0.1, 3.0), FR, "CogRed", "Brass", spacing=1.3,
                         chamfer=0.2, rivet_segs=4, bevel=0)
    pl.gear_cluster(b, (-5.55, FY - 0.2, 2.85), FR, R=0.75, t=0.12, third=False)
    cog_lens_mark(b, (0, FY - 0.08, 5.15), (0, -1, 0), 0.6)

    # right side (+X): CogRed panel with a gear cluster on its front third; left side (-X): flywheel, pipe run
    pl.riveted_plate(b, 3.4, 7.2, 0.2, (HX + 0.1, -0.8, 3.1), RX, "CogRed", "Brass", spacing=1.7, chamfer=0.15,
                     rivet_segs=4, bevel=0)
    pl.gear_cluster(b, (HX + 0.22, -3.0, 3.0), RX, R=0.85, t=0.12, third=False)
    pl.cyl(b, 0.55, 0.7, (-HX - 0.35, -0.8, 3.7), "GunmetalDark", pl.AX_X, segs=10)
    pl.gear(b, 1.6, 1.3, 10, 0.24, (-HX - 0.7, -0.8, 3.7), "Brass", LX, hub=0.45)
    pl.gear(b, 0.8, 0.62, 8, 0.22, (-HX - 0.7, -3.05, 2.2), "Brass", LX, hub=0.3)
    pl.pipe(b, [(-HX - 0.35, -5.2, 1.5), (-HX - 0.35, 3.6, 1.5), (-HX - 0.35, 3.6, 5.9)], 0.13, sides=6)
    pl.pipe(b, [(-HX - 0.3, -5.2, 2.0), (-HX - 0.3, 2.6, 2.0), (-HX - 0.3, 2.6, 5.4)], 0.1, sides=6)
    pl.gauge(b, (-HX - 0.05, -4.6, 4.6), (-1, 0, 0), 0.32)

    # roof forge block: tapered, CogRed riveted face with a gear cluster, brass band
    pl.taper_box(b, (10.4, 4.0), (9.4, 3.4), ZR, 8.5, "Gunmetal", loc=(0, 2.4, 0))
    pl.riveted_plate(b, 7.0, 1.15, 0.15, (0, 0.33, 7.65), FR, "CogRed", "Brass", spacing=1.2, chamfer=0.15,
                     rivet_segs=4, bevel=0)
    pl.gear(b, 0.45, 0.36, 8, 0.1, (-2.4, 0.2, 7.65), "Brass", FR, hub=0.14)
    pl.box(b, (9.6, 3.5, 0.14), (0, 2.4, 8.57), "GunmetalDark", bevel=0)
    for y in (1.7, 3.1):
        pl.steam_boiler(b, 0.5, 6.4, (0.4, y, 9.2), rot=pl.AX_X, color="Rust", bands=2, segs=8)
    pl.pipe(b, [(-3.4, 2.4, 9.3), (-4.6, 2.4, 9.5), (-5.45, 2.9, 8.4)], 0.11, sides=6)
    pl.box(b, (0.5, 0.6, 0.6), (-3.9, 2.4, 8.9), "GunmetalDark")

    # roof ribs and a skylight vent on the front half of the roof
    for y in (-5.6, -4.5):
        pl.box(b, (8.6, 0.3, 0.2), (-2.6, y, ZR + 0.1), "GunmetalDark", bevel=0)
    pl.vent_grille(b, 2.6, 2.0, 4, (-3.6, -1.6, ZR + 0.07), (0, 0, 0), "Rust", "Soot", depth=0.14)
    # smokestacks (rust rims, soot mouths): two tall on the left, one short on the right
    for x, y, h in ((-6.1, 3.0, 3.15), (-6.1, 0.4, 3.15), (6.1, 3.2, 2.4)):
        pl.smokestack(b, (x, y, ZR), 0.7, h, segs=8)
        pl.cyl(b, 0.6, 0.03, (x, y, ZR + h * 0.985), "Soot", segs=8, bevel=0)

    # rear: horizontal boiler drum on cradles, copper pipes up to the roof
    pl.steam_boiler(b, 0.85, 10.5, (0, 5.35, 4.2), rot=pl.AX_X, color="Rust", bands=4, segs=10)
    for x in (-3.6, 3.6):
        pl.box(b, (0.7, 1.4, 2.85), (x, 5.3, 1.93), "GunmetalDark", bevel=0)
    pl.pipe(b, [(-2.2, 5.35, 5.0), (-2.2, 5.35, 7.4), (-2.2, 4.0, 7.4)], 0.12, sides=6)

    # vent pedestal: the glowing grille (weak spot) on top, a glowing slit on the front, hazard on the +X face
    vx, vy, vz = 4.4, -2.2, 8.15
    VW, VD = 3.2, 2.6
    pl.box(b, (3.8, 3.2, 1.15), (vx, vy, 7.475), "GunmetalDark", bevel=0)
    for cx, cy, sx, sy in ((0, VD / 2 - 0.18, VW, 0.36), (0, -VD / 2 + 0.18, VW, 0.36),
                           (VW / 2 - 0.18, 0, 0.36, VD), (-VW / 2 + 0.18, 0, 0.36, VD)):
        pl.box(b, (sx, sy, 0.37), (vx + cx, vy + cy, 8.235), "Rust", bevel=0.04)
    pl.box(v, (VW - 0.7, VD - 0.7, 0.2), (vx, vy, vz), bevel=0)                      # hot plate, 0.25 below the rim
    for i in range(4):
        pl.box(b, (VW - 0.7, 0.14, 0.14), (vx, vy - 0.85 + i * 0.57, 8.33), "Soot", bevel=0)
    pl.box(v, (2.2, 0.08, 0.26), (vx, vy - 1.62, 7.45), bevel=0)                      # front slit glow
    for z in (7.72, 7.18):
        pl.box(b, (2.6, 0.2, 0.12), (vx, vy - 1.7, z), "Rust", bevel=0)
    pl.hazard_stripes(b, 0.7, 2.8, (vx + 1.93, vy, 7.45), RX, stripes=4)
    # conveyor ramp out of the bay: belt, rollers, rails with hazard dashes
    ang = atan2(0.40, 5.5)
    surf = lambda y: 0.62 - (FY - y) * tan(ang)
    pl.box(b, (3.2, 5.5, 0.22), (0, -8.95, surf(-8.95) - 0.11), "Tread", rot=(ang, 0, 0), bevel=0)
    for i in range(8):
        y = -6.5 - i * 0.7
        pl.cyl(b, 0.12, 3.0, (0, y, surf(y) + 0.08), "Steel", pl.AX_X, segs=6, bevel=0)
    for s in (1, -1):
        pl.box(b, (0.3, 5.5, 0.5), (s * 1.75, -8.95, surf(-8.95) + 0.1), "Gunmetal", rot=(ang, 0, 0), bevel=0)
        for i in range(5):
            y = -6.9 - i * 1.0
            pl.box(b, (0.32, 0.5, 0.06), (s * 1.75, y, surf(y) + 0.38), "Hazard", rot=(ang, 0, 0), bevel=0)
    pl.box(b, (3.8, 0.3, 0.3), (0, -11.55, 0.15), "Rust", bevel=0)               # end lip
    return k


# ================================================================== ENV COG PYLON
def env_cog_pylon():
    """Cog power pylon: four-legged braced tower round a gunmetal column, steam drum, CogRed armour sleeve with gear
    cluster and the Cog mark, crossarm with ceramic insulators, cable drums at ~0.86 height (the game hangs the
    cables there), caged red beacon lamp on top."""
    k = pl.Kit("env_cog_pylon", palette="cogwork", category="prop", reset=True)
    b = k.part("Body", "body", "Metal", color="Gunmetal")
    pt = k.part("Plates", "trim", "SmoothPlastic", color="CogRed")
    dk = k.part("Dark", "trim", "SmoothPlastic", color="GunmetalDark")
    tr = k.part("Trim", "trim", "SmoothPlastic", color="Brass")
    bc = k.glow("Beacon", role="glow")

    # base: rust skirt + dark slab (octagon)
    pl.loft(pt, [pl.chamfer_rect(3.27, 3.73, 1.1, 0), pl.chamfer_rect(3.27, 3.73, 1.1, 0.22)], color="Rust")
    pl.loft(dk, [pl.chamfer_rect(3.15, 3.6, 1.0, 0.22), pl.chamfer_rect(3.0, 3.45, 1.0, 0.55)], color="GunmetalDark")
    # braced legs
    LZ0, LZ1 = 0.75, 8.6

    def legp(sx, sy, z):
        t = (z - LZ0) / (LZ1 - LZ0)
        return (sx * (2.55 - 1.8 * t), sy * (3.0 - 2.25 * t), z)
    for sx in (1, -1):
        for sy in (1, -1):
            pl.rod(b, legp(sx, sy, LZ0), legp(sx, sy, LZ1), 0.28, "Gunmetal", segs=8, r2=0.2)
            pl.box(dk, (1.0, 1.0, 0.4), (sx * 2.55, sy * 3.0, 0.75), "GunmetalDark")
    for z in (3.0, 5.8):
        pts = [legp(1, -1, z), legp(1, 1, z), legp(-1, 1, z), legp(-1, -1, z)]
        for i in range(4):
            pl.rod(b, pts[i], pts[(i + 1) % 4], 0.09, "Steel", segs=6)
    for sx, sy in ((1, 1), (-1, 1)):                                    # diagonal bracing on the +Y/-Y faces
        for sy2 in (1, -1):
            pl.rod(b, legp(sx, sy2, 3.0), legp(-sx, sy2, 5.8), 0.07, "Steel", segs=4)
    # column
    pl.loft(b, [pl.chamfer_rect(0.95, 0.95, 0.3, 0.55), pl.chamfer_rect(0.85, 0.85, 0.28, 8.6),
                pl.chamfer_rect(0.55, 0.55, 0.2, 13.0), pl.chamfer_rect(0.5, 0.5, 0.18, 14.45)], color="Gunmetal")
    pl.loft(dk, [pl.chamfer_rect(1.3, 1.3, 0.4, 8.25), pl.chamfer_rect(1.1, 1.1, 0.35, 8.95)], color="GunmetalDark")
    pl.torus(tr, 1.15, 0.07, (0, 0, 9.0), "Brass", segs=10, csegs=4)
    # steam drum (rust, brass bands) round the column
    pl.steam_boiler(pt, 0.95, 2.4, (0, 0, 6.6), rot=(0, 0, 0), color="Rust", bands=3, segs=10)
    # pump housing at the front with a gear cluster, pipe up to the drum
    pl.box(pt, (2.4, 1.6, 1.6), (0, -2.5, 1.35), "CogRed")
    pl.gear(tr, 0.5, 0.4, 8, 0.1, (-0.3, -3.32, 1.4), "Brass", FR, hub=0.16)
    pl.pipe(tr, [(0.7, -2.5, 2.2), (0.7, -2.5, 3.5), (0.7, -0.9, 3.5), (0.7, -0.9, 5.3)], 0.1)
    pl.box(dk, (0.5, 0.4, 0.3), (-0.9, -2.5, 2.3), "Oil")
    # CogRed armour sleeve: four riveted plates, gear cluster on the front one
    pl.riveted_plate(pt, 1.2, 2.4, 0.15, (0, -0.78, 10.6), FR, "CogRed", "Brass", spacing=0.8, chamfer=0.15,
                     rivet_segs=4, bevel=0)
    pl.riveted_plate(pt, 1.2, 2.4, 0.15, (0, 0.78, 10.6), (-pi / 2, 0, 0), "CogRed", "Brass", spacing=0.8,
                     chamfer=0.15, rivet_segs=4, bevel=0)
    for s, rot in ((1, RX), (-1, LX)):
        pl.riveted_plate(pt, 2.4, 1.2, 0.15, (s * 0.78, 0, 10.6), rot, "CogRed", "Brass", spacing=0.8, chamfer=0.15,
                         rivet_segs=4, bevel=0)
    pl.gear_cluster(tr, (-0.15, -0.88, 10.3), FR, R=0.34, t=0.08, third=False)
    cog_lens_mark(tr, (0, -0.62, 12.05), (0, -1, 0), 0.3)
    # crossarm with insulators and cable drums
    pl.box(b, (5.2, 0.55, 0.42), (0, 0, 13.25), "Gunmetal")
    for s in (1, -1):
        pl.box(tr, (0.2, 0.65, 0.52), (s * 2.65, 0, 13.25), "Brass")
        pl.rod(b, (s * 0.45, 0, 12.3), (s * 2.1, 0, 13.05), 0.09, "Steel", segs=6)
        for x in (s * 2.0,):
            for i, (r, z) in enumerate(((0.38, 13.62), (0.3, 13.84), (0.38, 14.06))):
                pl.cyl(tr, r, 0.14, (x, 0, z), "Ivory", segs=6, bevel=0)
            pl.cyl(dk, 0.1, 0.4, (x, 0, 13.55), "Soot", segs=6, bevel=0)
            pl.cyl(dk, 0.2, 0.22, (x, 0, 14.3), "Oil", segs=6, bevel=0)
    for z in (12.6, 13.5):                                               # cable drums at ~0.8 / 0.86 height
        pl.cyl(tr, 0.72, 0.24, (0, 0, z), "Brass", segs=8, bevel=0)
    # caged beacon lantern on top
    pl.cyl(dk, 0.72, 0.16, (0, 0, 14.52), "GunmetalDark", segs=8)
    for i in range(6):
        a = 2 * pi * i / 6
        pl.rod(b, (0.52 * pl.cos(a), 0.52 * pl.sin(a), 14.58), (0.52 * pl.cos(a), 0.52 * pl.sin(a), 15.32), 0.07,
               "Steel", segs=4)
    pl.cyl(b, 0.75, 0.46, (0, 0, 15.49), "Gunmetal", segs=8, r2=0.12)
    pl.ico(bc, 0.42, (0, 0, 14.95), subdiv=2, scale=(1, 1, 1.15))
    k.center()
    k.ground()
    return k


# ================================================================== SAMPLE POD (Squad)
def sample_pod():
    """Squad sample canister: charcoal hex body on a foot, tan armour bands, hazard strip, steel cage bars round a
    recessed glow core (the game tints the Glow), orange carry handle."""
    k = pl.Kit("sample_pod", palette="human", category="prop", reset=True)
    c = k.part("Casing", "body", "SmoothPlastic", pivot=(0, 0, 0), color="Charcoal")
    g = k.glow("Glow", role="glow", pivot=(0, 0, 0.82), parent="Casing")
    K = 1 / 0.9239                               # flat-to-flat half width -> circumradius for a flats-on-axes octagon
    R8 = (0, 0, radians(22.5))

    def oct_(r, depth, z, color, r2=None):
        pl.cyl(c, r * K, depth, (0, 0, z), color, R8, segs=8, r2=None if r2 is None else r2 * K, bevel=0)
    # foot, lower collar, tan band
    oct_(0.55, 0.14, 0.07, "CharcoalDark")
    oct_(0.5, 0.34, 0.31, "Charcoal")
    oct_(0.53, 0.1, 0.3, "Tan")
    oct_(0.4, 0.06, 0.51, "CharcoalDark")
    # cage: bottom and top rings, four tan ribs, eight steel bars round the core
    oct_(0.48, 0.07, 0.55, "Steel")
    oct_(0.48, 0.07, 1.13, "Steel")
    for i in range(8):
        a = 2 * pi * i / 8 + radians(22.5)
        x, y = 0.42 * pl.cos(a), 0.42 * pl.sin(a)
        pl.cyl(c, 0.035, 0.6, (x, y, 0.84), "Steel", segs=4, bevel=0)
    for i in range(4):
        a = 2 * pi * i / 4 + radians(45)
        x, y = 0.43 * pl.cos(a), 0.43 * pl.sin(a)
        pl.box(c, (0.07, 0.07, 0.6), (x, y, 0.84), "Tan", rot=(0, 0, a), bevel=0)
    # upper collar, band, cap, orange carry handle
    oct_(0.5, 0.26, 1.29, "Charcoal")
    oct_(0.53, 0.09, 1.46, "Tan")
    oct_(0.42, 0.1, 1.55, "CharcoalDark", r2=0.3)
    oct_(0.34, 0.06, 1.63, "Orange")
    pl.torus(c, 0.27, 0.05, (0, 0, 1.64), "Orange", (pi / 2, 0, 0), segs=8, csegs=4, arc=pi)
    for s in (1, -1):
        pl.box(c, (0.1, 0.1, 0.1), (s * 0.27, 0, 1.64), "Steel", bevel=0)
    # markings: hazard strip, stencil glyph, a few bolts
    pl.hazard_stripes(c, 0.5, 0.13, (0, -0.512, 1.29), FR, stripes=4)
    pl.stencil_panel(c, 0.3, 0.17, (0, -0.512, 0.32), FR, "CharcoalDark", "Stencil", t=0.03)
    for i in range(8):
        a = 2 * pi * i / 8
        pl.bolt(c, (0.46 * pl.cos(a), 0.46 * pl.sin(a), 0.36), (pl.cos(a), pl.sin(a), 0), 0.03, "Steel", segs=4)
    # core: glow ball inside the bars
    pl.energy_core(g, (0, 0, 0.82), 0.27, subdiv=2, scale=(1, 1, 1.05))
    return k


# ================================================================== COURIER WRECK (Squad)
def courier_wreck():
    """Crashed Squad courier: charcoal faceted fuselage nose-down and rolled, broken in two behind the cabin, tail
    section skewed with one engine still on and one torn off, one wing intact and one snapped, hatch open with the door
    lowered as a ramp, severed wing on the ground, data case beside the hatch (DataCase), scorch + dirt (Ground),
    scattered panels (Debris)."""
    k = pl.Kit("courier_wreck", palette="human", category="set_piece", reset=True)
    h = k.part("Hull", "body", "SmoothPlastic", pivot=(0, 0, 0), color="Charcoal")
    c = k.part("DataCase", "interact", "SmoothPlastic", pivot=(-6.9, -5.6, 0), parent="Hull", color="CharcoalDark")
    gr = k.part("Ground", "decor", "SmoothPlastic", pivot=(0, 0, 0), parent="Hull", color="Black")
    d = k.part("Debris", "decor", "SmoothPlastic", pivot=(0, 0, 0), parent="Hull", color="Tan")

    F = G((0, 1.0, 0.5), (radians(10), radians(6.5), radians(-3)))
    T = F.sub((0.35, 3.8, 3.15), (radians(-9), radians(-5), radians(11)))     # broken-off tail section frame

    # ---- forward fuselage (octagon sections), burnt nose
    CZ = 2.65
    st = [(-8.2, 0.5, 0.45, 0.15, 2.0), (-7.4, 1.3, 0.95, 0.4, 2.2), (-6.0, 2.0, 1.5, 0.6, 2.45),
          (-3.5, 2.35, 1.85, 0.7, CZ), (0.0, 2.4, 1.9, 0.75, CZ), (3.0, 2.38, 1.88, 0.75, CZ)]
    F.loft(h, [ring(*s[:4], cz=s[4]) for s in st], "Charcoal")
    F.loft(h, [ring(y, hx * 1.012, hz * 1.012, cc, cz=z) for y, hx, hz, cc, z in st[:3]], "Black")      # burnt nose
    # underside band
    F.loft(h, [ring(y, hx * 0.85, hz * 0.3, 0.1, cz=z - hz * 0.9) for y, hx, hz, cc, z in st[1:]], "CharcoalDark")
    # tan armour: roof plates + side plates, rivet rows
    F.riveted(h, 2.6, 4.3, 0.12, (0, -1.4, CZ + 1.92), (0, 0, 0), "Tan", "Steel", spacing=1.1, chamfer=0.15,
              rivet_segs=4, bevel=0)
    F.riveted(h, 1.9, 4.6, 0.12, (2.46, -1.1, CZ), RX, "Tan", "Steel", spacing=1.1, chamfer=0.12, rivet_segs=4, bevel=0)
    F.riveted(h, 1.9, 2.6, 0.12, (-2.46, 1.6, CZ), LX, "Tan", "Steel", spacing=1.1, chamfer=0.12, rivet_segs=4, bevel=0)
    F.haz(h, 2.2, 0.5, (0, 0.8, CZ + 1.96), (0, 0, 0), stripes=5)
    # stencil glyph panel on the +X flank
    F.extrude(h, [(-0.5, -0.2), (0.5, -0.2), (0.5, 0.2), (-0.5, 0.2)], 0.06, (2.43, 1.6, CZ + 0.5), "CharcoalDark",
              rot=(0, 0, 0), plane='YZ', bevel=0)
    # canopy: dark glass wedge in a charcoal frame, cracked bar
    F.taper_box(h, (2.9, 2.5), (1.9, 1.3), 4.3, 5.05, "Visor", top_offset=(0, -0.4), loc=(0, -5.0, 0), bevel=0.05)
    for s in (1, -1):
        F.rod(h, (s * 1.45, -6.25, 4.3), (s * 0.95, -5.45, 5.05), 0.09, "Steel", segs=6)
        F.rod(h, (s * 1.45, -3.75, 4.3), (s * 0.95, -4.55, 5.05), 0.09, "Steel", segs=6)
    F.box(h, (3.3, 0.35, 0.3), (0, -3.6, 4.35), "CharcoalDark")
    F.box(h, (0.12, 1.7, 0.1), (0, -4.9, 5.1), "Steel", bevel=0)
    # roof hatch torn open (smoke source), ripped panel
    F.box(h, (1.6, 1.4, 0.18), (-1.2, 0.2, CZ + 1.98), "CharcoalDark", rot=(radians(-18), radians(14), 0))
    F.box(h, (1.5, 1.3, 0.1), (-1.4, 0.0, CZ + 2.15), "Orange", rot=(radians(-35), radians(20), radians(10)))
    # nose band, antenna
    F.box(h, (2.0, 0.22, 0.14), (0, -7.62, 2.8), "Orange", rot=(radians(-12), 0, 0), bevel=0)
    pl.antenna(h, F.P((-0.8, -2.6, CZ + 1.95)), 1.1, color="Steel")

    # ---- hatch on the -X flank: dark opening, bench, door lowered to the ground as a ramp
    F.box(h, (0.12, 2.4, 2.4), (-2.43, -4.5, 2.3), "Black", bevel=0)
    F.box(h, (0.5, 1.9, 0.45), (-2.3, -4.5, 1.5), "Steel")
    F.box(h, (0.4, 0.9, 0.8), (-2.3, -4.1, 2.0), "Orange")
    for z in (1.1, 3.5):
        F.box(h, (0.16, 2.6, 0.16), (-2.45, -4.5, z), "CharcoalDark")
    hg = F.sub((-2.5, -4.5, 1.02), (0, radians(-125), 0))
    hg.box(h, (0.16, 2.35, 2.75), (0, 0, 1.4), "Charcoal", bevel=0.04)
    hg.box(h, (0.2, 1.7, 1.2), (0, 0, 1.6), "Tan", bevel=0.04)
    hg.box(h, (0.22, 2.35, 0.3), (0, 0, 2.7), "Orange", bevel=0.04)
    hg.haz(h, 0.45, 2.1, (0.1, 0, 0.45), (0, pi / 2, 0), stripes=4)

    # ---- wings: left (-X) intact with an engine pod, right (+X) snapped stump
    F.extrude(h, [(-2.3, -1.8), (-2.3, 2.7), (-6.6, 2.6), (-6.6, 0.4)], 0.5, (0, 0, 2.5), "Charcoal", plane='XY', bevel=0.05)
    F.extrude(h, [(-2.8, -1.0), (-2.8, 2.2), (-5.6, 2.1), (-5.6, 0.7)], 0.1, (0, 0, 2.78), "Tan", plane='XY', bevel=0)
    F.extrude(h, [(-2.3, -1.8), (-2.3, 2.7), (-6.6, 2.6), (-6.6, 0.4)], 0.2, (0, 0, 2.22), "CharcoalDark", plane='XY', bevel=0)
    F.box(h, (0.8, 2.2, 0.16), (-6.2, 1.5, 2.8), "Orange", bevel=0.03)
    F.cyl(h, 0.62, 2.6, (-3.5, 0.9, 1.95), "Charcoal", pl.AX_Y, segs=10, r2=0.5)
    F.cyl(h, 0.7, 0.4, (-3.5, -0.2, 1.95), "CharcoalDark", pl.AX_Y, segs=10)
    F.cyl(h, 0.42, 0.2, (-3.5, 2.25, 1.95), "Black", pl.AX_Y, segs=10, bevel=0)
    F.extrude(h, [(2.3, -1.8), (2.3, 2.7), (3.5, 2.3), (3.7, 1.0), (3.2, 0.1), (2.9, -0.9)], 0.5, (0, 0, 2.5), "Charcoal",
              plane='XY', bevel=0.04)
    for yy, dz in ((-0.4, 0.1), (1.0, -0.2), (2.2, 0.0)):
        F.rod(h, (3.2, yy, 2.45), (4.4, yy + 0.1, 2.5 + dz), 0.07, "Steel", segs=5)
    F.rod(h, (3.0, 0.6, 2.4), (3.7, 1.0, 1.5), 0.06, "Rebar", segs=5)
    # landing strut
    F.rod(h, (1.9, -1.0, 1.7), (2.6, -1.4, 0.3), 0.15, "Steel", segs=8)
    F.cyl(h, 0.4, 0.3, (2.6, -1.4, 0.25), "CharcoalDark", segs=8)

    # ---- break: dark bulkheads inside a charcoal rim, exposed ribs (rebar), cables across the gap
    F.loft(h, [ring(3.0, 1.95, 1.55, 0.6, cz=CZ), ring(3.07, 1.95, 1.55, 0.6, cz=CZ)], "Black")
    T.loft(h, [ring(0.0, 1.95, 1.55, 0.6), ring(-0.07, 1.95, 1.55, 0.6)], "Black")
    for k_ in range(6):
        t1 = 2 * pi * k_ / 6 + 0.2
        x, z = 1.8 * pl.cos(t1), 1.45 * pl.sin(t1)
        F.rod(h, (x, 3.0, CZ + z), (x * 0.95, 3.0 + 0.3 + (k_ % 3) * 0.15, CZ + z * 0.95), 0.07, "Rebar", segs=5)
        T.rod(h, (x, 0.0, z), (x * 0.95, -0.25 - (k_ % 2) * 0.2, z * 0.95), 0.07, "Steel", segs=5)
    for p, q, col in (((0.4, 3.0, 3.5), (0.2, 3.8, 3.3), "Orange"), ((-0.6, 3.0, 2.2), (-0.7, 3.8, 2.1), "Steel"),
                      ((0.9, 3.0, 1.8), (1.0, 3.8, 1.9), "Steel")):
        pl.rod(h, F.P(p), T.P((q[0], q[1] - 3.8, q[2] - 3.15)), 0.08, col, segs=5)

    # ---- tail section
    tr_st = [(0.0, 2.3, 1.85, 0.7), (1.4, 2.25, 1.8, 0.7), (3.4, 1.95, 1.55, 0.65), (5.4, 1.45, 1.2, 0.5),
             (6.6, 0.8, 0.75, 0.3)]
    T.loft(h, [ring(*s) for s in tr_st], "Charcoal")
    T.loft(h, [ring(y, hx * 0.85, hz * 0.3, 0.1, cz=-hz * 0.9) for y, hx, hz, cc in tr_st], "CharcoalDark")
    T.riveted(h, 2.4, 3.2, 0.12, (0, 2.2, 1.9), (0, 0, 0), "Tan", "Steel", spacing=1.1, chamfer=0.15, rivet_segs=4, bevel=0)
    T.haz(h, 1.9, 0.5, (0, 4.6, 1.52), (0, 0, 0), stripes=4)
    # fins: intact one on +X, snapped stub on -X
    T.fin(h, 2.0, 1.0, 1.9, (1.15, 2.6, 1.3), (0, 0, pi / 2), t=0.2, color="Charcoal")
    T.box(h, (0.26, 0.9, 0.35), (1.15, 4.0, 3.1), "Orange", bevel=0.03)
    T.fin(h, 2.0, 1.4, 0.8, (-1.35, 2.6, 1.25), (0, 0, pi / 2), t=0.2, color="Charcoal")
    # engines: one mounted, one torn off lying behind
    T.cyl(h, 0.78, 1.5, (1.0, 6.7, 0.1), "Charcoal", pl.AX_Y, segs=10, r2=0.64)
    T.cyl(h, 0.9, 0.3, (1.0, 5.95, 0.1), "CharcoalDark", pl.AX_Y, segs=10)
    T.cyl(h, 0.6, 0.2, (1.0, 7.5, 0.1), "Black", pl.AX_Y, segs=10, bevel=0)
    pl.cyl(h, 0.78, 1.5, T.P((-1.3, 7.8, -2.4)), "Charcoal", pl.orient((0.3, 1, 0.12)), segs=10, r2=0.64)
    pl.cyl(h, 0.6, 0.2, T.P((-1.35, 8.65, -2.25)), "Black", pl.orient((0.3, 1, 0.12)), segs=10, bevel=0)
    pl.rod(h, T.P((-1.0, 5.4, -0.5)), T.P((-1.15, 6.5, -2.0)), 0.09, "Steel", segs=5)

    # ---- severed wing on the ground
    S = G((-9.2, -2.4, 0.55), (radians(3), radians(8), radians(-140)))
    S.extrude(h, [(0, -2.0), (0, 2.7), (-2.2, 2.5), (-2.2, 0.2)], 0.55, (0, 0, 0), "Tan", plane='XY', bevel=0.06)
    S.extrude(h, [(0, -2.0), (0, 2.7), (-2.2, 2.5), (-2.2, 0.2)], 0.2, (0, 0, -0.3), "CharcoalDark", plane='XY', bevel=0)
    S.box(h, (0.6, 2.3, 0.16), (-1.9, 1.35, 0.33), "Orange", bevel=0.03)
    for yy in (-0.6, 0.8, 2.0):
        S.rod(h, (0.1, yy, 0.0), (1.0 + (yy % 0.4), yy + 0.1, 0.1), 0.08, "Steel", segs=5)

    # ---- DataCase: squad case, tan side plates, orange latches and handle, stencil
    cf = G((-6.9, -5.6, 0), (0, 0, radians(28)))
    cf.box(c, (1.5, 0.9, 0.95), (0, 0, 0.475), "CharcoalDark")
    for s in (1, -1):
        cf.box(c, (0.34, 0.98, 0.95), (s * 0.66, 0, 0.475), "Charcoal")
        cf.box(c, (0.2, 0.12, 0.3), (s * 0.4, -0.5, 0.62), "Orange", bevel=0.03)
    cf.box(c, (0.9, 0.12, 0.14), (0, 0, 1.0), "Orange", bevel=0.03)
    cf.plate(c, 0.5, 0.38, 0.06, (0, -0.47, 0.5), (pi / 2, 0, 0), "Tan", 0.2, bevel=0)
    cf.haz(c, 0.5, 0.16, (0, -0.47, 0.16), (pi / 2, 0, 0), stripes=3)

    # ---- Ground: scorch patches and dirt mounds
    for x, y, rx, ry in ((0.0, 0.5, 4.8, 7.8), (1.0, 8.5, 3.2, 3.4), (-3.5, -3.5, 2.6, 2.6)):
        pl.cyl(gr, 1.0, 0.06, (x, y, 0.03), "ConcreteDark", segs=14, bevel=0).scale = (rx, ry, 1)
    for x, y, sx, sy, sz in ((0, -9.8, 2.8, 1.6, 1.0), (-2.9, -8.9, 1.4, 1.2, 0.7), (2.8, -9.0, 1.4, 1.1, 0.65)):
        pl.ico(gr, 1.0, (x, y, -0.2), "TanDark", subdiv=1, scale=(sx, sy, sz * 0.8))
    for x, y, r in ((5.5, -2.5, 0.35), (-6.5, 4.0, 0.3), (6.5, 6.5, 0.4)):
        pl.ico(gr, r, (x, y, 0.0), "TanDark", subdiv=1, scale=(1, 1, 0.6))

    # ---- Debris: loose panels, a spar, an engine fragment
    for x, y, z, sz, rot, col in ((-5.2, 3.0, 0.1, (1.4, 0.9, 0.12), (0, 4, 30), "Tan"),
                                   (5.2, -4.2, 0.08, (1.1, 0.7, 0.1), (3, -3, -50), "Orange"),
                                   (3.3, 11.0, 0.08, (1.3, 0.8, 0.1), (3, 5, 70), "Charcoal"),
                                   (-7.4, 3.8, 0.08, (0.9, 0.6, 0.1), (0, 0, -20), "Orange")):
        pl.box(d, sz, (x, y, z), col, rot=tuple(radians(a) for a in rot), bevel=0.03)
    pl.rod(d, (4.0, 8.6, 0.1), (4.0 + 1.4 * pl.cos(radians(30)), 8.6 + 1.4 * pl.sin(radians(30)), 0.2), 0.09, "Steel", segs=6)
    pl.cyl(d, 0.42, 1.0, (-6.9, 6.8, 0.42), "CharcoalDark", (0, radians(90), radians(20)), segs=8, bevel=0)
    return k


BUILDERS = {"fabricator": fabricator, "env_cog_pylon": env_cog_pylon, "sample_pod": sample_pod,
            "courier_wreck": courier_wreck}

# fields the old manifest entry carried that parts_lib's manifest_entry does not
EXTRA = {
    "fabricator": {"rigVersion": 2, "kind": "enemy_building"},
    "env_cog_pylon": {},
    "sample_pod": {"rigVersion": 2, "kind": "setpiece"},
    "courier_wreck": {"rigVersion": 2, "kind": "setpiece",
                      "notes": "Origin at ground centre, nose toward -Y. Interactable: DataCase. Decor parts "
                               "(Ground, Debris) can be dropped."},
}
KIT_ORIGIN = ("fabricator", "sample_pod", "courier_wreck")   # kit entries keep the Blender frame (Meshes `origin`)


def entry_for(k):
    e = k.manifest_entry()
    e.update(EXTRA[k.key])
    e["fbx"] = f"art/fbx/new/{k.key}.fbx"
    e["texture"] = f"art/fbx/new/palette_{k.palette_name}.png"
    e["triangles_total"] = sum(p.tris for p in k.parts)
    e["source"] = "art/blender/structures_v2.py"
    lo, hi = k.bbox()
    ctr = (hi + lo) / 2
    if k.key in KIT_ORIGIN:
        # Roblox-frame offset of the Blender origin inside the recentred model (Meshes `origin`)
        e["origin"] = [round(ctr.x, 3) + 0.0, round(-lo.z, 3) + 0.0, round(-ctr.y, 3) + 0.0]
    for p in e["parts"]:
        if p["rgb"] is None:
            p.pop("rgb")
    return e


def spin_about_centre(k):
    """Turn the built model 180 degrees about its own X/Y centre (so the back view gets the same lighting)."""
    lo, hi = k.bbox()
    c = (lo + hi) / 2
    c.z = 0
    rot = Matrix.Rotation(pi, 4, 'Z')
    for p in k.parts:
        ob = p.obj
        ob.location = c + rot.to_3x3() @ (ob.location - c)
        ob.rotation_euler.z += pi
    bpy.context.view_layer.update()


CAMS = {  # per key: (front cam_dir, zoom, back view uses the same after a 180 spin)
    "fabricator": ((0.42, -1.0, 0.5), 1.0),
    "env_cog_pylon": ((0.45, -1.0, 0.28), 1.5),
    "sample_pod": ((0.4, -1.0, 0.38), 2.0),
    "courier_wreck": ((0.55, -1.0, 0.62), 1.0),
}


def run(root, keys):
    os.environ["ORBITFALL_ROOT"] = root
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'          # 1 BU = 1 stud in Roblox
    out_fbx = os.path.join(REPO, "art", "fbx", "new")
    out_img = os.path.join(REPO, "art", "images")
    os.makedirs(out_fbx, exist_ok=True)
    for key in keys:
        k = BUILDERS[key]()
        k.build()
        k.report()
        k.export_fbx()                                                   # export BEFORE rendering
        e = entry_for(k)
        shutil.copy(os.path.join(root, "art", "fbx", f"{key}.fbx"), os.path.join(out_fbx, f"{key}.fbx"))
        shutil.copy(os.path.join(root, "art", "fbx", f"palette_{k.palette_name}.png"),
                    os.path.join(out_fbx, f"palette_{k.palette_name}.png"))
        with open(os.path.join(out_fbx, f"{key}.entry.json"), "w") as f:
            json.dump(e, f, indent=2)
        cam, zoom = CAMS[key]
        env_set1.stage(os.path.join(out_img, f"{key}_new_front.png"), [k], size=(900, 900), cam_dir=cam, zoom=zoom)
        spin_about_centre(k)
        env_set1.stage(os.path.join(out_img, f"{key}_new_back.png"), [k], size=(900, 900), cam_dir=cam, zoom=zoom)
        if os.environ.get("SV2_EXTRA"):        # scratch-only extra angles for checking
            spin_about_centre(k)
            for tag, cd in (("top", (0.1, -0.35, 1.0)), ("left", (-1.0, -0.3, 0.4)), ("right", (1.0, -0.3, 0.4))):
                env_set1.stage(os.path.join(root, f"{key}_{tag}.png"), [k], size=(900, 900), cam_dir=cd, zoom=zoom)
        lo, hi = k.bbox()
        print(f"[structures_v2] {key}: tris {sum(p.tris for p in k.parts)}  size(Roblox) "
              f"{[round(v, 2) for v in (hi.x - lo.x, hi.z - lo.z, hi.y - lo.y)]}  origin {e.get('origin')}")


if __name__ == "__main__":
    a = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    root = a[0] if a else "/private/tmp/orbitfall-cogstruct"
    run(root, a[1:] or list(BUILDERS))
