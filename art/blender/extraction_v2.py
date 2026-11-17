"""Extraction set in the Squad ("human") art style (art/STYLE.md): the Skiff dropship and its landing pad.

Drop-in replacements for the old halcyon-style models of the same keys (setpieces.py):
  skiff           Body / Ramp (hinge pivot) / Engine_L, Engine_R (Neon) + NEW Gun (chin / belly turret)
  extraction_pad  Body / Light_1..4 (Neon lamp heads on the four corner posts)
Same names, parents, roles, pivots, facing (Blender -Y front, Z up) and origin convention as the old scripts.

Run headless:
  Blender -b --factory-startup --python art/blender/extraction_v2.py -- [skiff] [pad] [--noexport] [--norender]
Needs ORBITFALL_ROOT-style scratch (default /private/tmp/orbitfall-skiff); copies the results into art/fbx/new
and art/images.
"""
import json
import os
import shutil
import sys
from math import pi, radians, cos, sin, atan2, degrees

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, os.path.join(REPO, "helper"))
sys.path.insert(0, HERE)
import bpy
import parts_lib as pl
from mathutils import Matrix, Vector

SCRATCH = "/private/tmp/orbitfall-skiff"
NEW = os.path.join(REPO, "art", "fbx", "new")
IMAGES = os.path.join(REPO, "art", "images")

AMBER = "ffb347"                                   # squad lamp glow (art/STYLE.md rule 5)
NAC = Matrix.Rotation(pi / 2, 3, 'X') @ Matrix.Rotation(pi / 8, 3, 'Z')   # octagon cylinder along Y, flats up/down/sideways


def sect(y, hx, z0, z1, c, ox=0.0):
    """Chamfered-rectangle ring in the XZ plane at height-along-Y y (loft ring for the fuselage)."""
    pts = [(-hx + c, z0), (hx - c, z0), (hx, z0 + c), (hx, z1 - c),
           (hx - c, z1), (-hx + c, z1), (-hx, z1 - c), (-hx, z0 + c)]
    return [(x + ox, y, z) for x, z in pts]


def side_basis(s):
    """Rotation for a plate lying on a vertical side face (local X along +Y, local Z -> +-X)."""
    return pl.basis((0, 1, 0), (s, 0, 0))


# =============================================================================== SKIFF
HX = 2.8                                           # fuselage half width
HP = (0.0, 10.8, 1.55)                             # ramp hinge (old pivot)


def build_skiff():
    k = pl.Kit("skiff", palette="human", category="set_piece", reset=True)
    B = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Charcoal")
    R = k.part("Ramp", "ramp", "Metal", pivot=HP, parent="Body", color="Charcoal")
    G = k.part("Gun", "gun", "Metal", pivot=(0, -7.2, 1.3), parent="Body", color="CharcoalDark")
    EL = k.glow("Engine_L", rgb=AMBER, role="glow", pivot=(4.4, 5.8, 2.2), parent="Body")
    ER = k.glow("Engine_R", rgb=AMBER, role="glow", pivot=(-4.4, 5.8, 2.2), parent="Body")

    # ---- fuselage: octagon-section loft, low pointed nose, wide flat belly and shoulders
    SEC = [(-11.0, 0.55, 1.95, 2.55, 0.15), (-10.3, 1.3, 1.65, 3.0, 0.35), (-8.6, 2.1, 1.4, 3.7, 0.6),
           (-5.0, 2.7, 1.4, 4.3, 0.75), (-3.0, HX, 1.4, 4.45, 0.8), (5.0, HX, 1.4, 4.45, 0.8),
           (8.6, 2.7, 1.4, 4.2, 0.7)]
    pl.loft(B, [sect(*s) for s in SEC], color="Charcoal", bevel=0.03)
    # belly armour pan + roof seam
    pl.box(B, (3.6, 9.5, 0.14), (0, -0.2, 1.36), "CharcoalDark", bevel=0.03)

    # ---- rear troop bay: side walls, roof and floor frame an open tunnel, ramp hangs from the floor lip
    for s in (1, -1):
        pl.box(B, (1.05, 2.3, 2.8), (s * 2.28, 9.7, 2.8), "Charcoal", bevel=0.06)       # side wall x 1.75..2.8
        pl.box(B, (0.14, 2.3, 2.3), (s * 1.74, 9.7, 2.7), "CharcoalDark", bevel=0)       # inner liner
        pl.hazard_stripes(B, 0.8, 2.4, (s * 2.28, 10.84, 2.8), (-pi / 2, 0, 0), stripes=4, c1="Hazard", c2="Black")
        pl.box(B, (0.5, 1.5, 0.5), (s * 1.42, 9.6, 1.85), "Olive", bevel=0)            # troop bench
        pl.box(B, (0.1, 1.4, 0.1), (s * 1.62, 9.6, 3.1), "Orange", bevel=0)               # grab rail
    pl.box(B, (5.6, 2.3, 0.4), (0, 9.7, 4.0), "Charcoal", bevel=0.06)                    # roof
    pl.box(B, (3.5, 2.3, 0.3), (0, 9.7, 1.4), "CharcoalDark", bevel=0.05)               # floor slab, top at 1.55
    pl.box(B, (3.5, 0.1, 2.2), (0, 8.75, 2.7), "Black", bevel=0)                          # bay back wall
    pl.box(B, (3.5, 0.2, 0.22), (0, 10.82, 1.46), "Steel", bevel=0)                  # floor lip / hinge bar
    pl.hazard_stripes(B, 3.0, 0.5, (0, 10.0, 1.57), (0, 0, 0), stripes=5, c1="Hazard", c2="Black")  # threshold

    # ---- cockpit: dark glass wedge, framed, armoured brow
    CAN = [sect(-9.7, 0.7, 3.2, 3.6, 0.15), sect(-8.5, 1.6, 3.3, 4.6, 0.5),
           sect(-6.9, 2.1, 3.9, 5.35, 0.6), sect(-5.5, 2.3, 4.2, 5.4, 0.55)]
    pl.loft(B, CAN, color="Visor", bevel=0)
    for s in (1, -1):
        pl.rod(B, (s * 1.6, -8.5, 4.6), (s * 2.1, -6.9, 5.35), 0.12, "Steel", segs=6)
        pl.rod(B, (s * 2.1, -6.9, 5.35), (s * 2.3, -5.5, 5.4), 0.12, "Steel", segs=6)
        pl.rod(B, (s * 0.7, -9.7, 3.6), (s * 1.6, -8.5, 4.6), 0.12, "Steel", segs=6)
    pl.rod(B, (0, -9.7, 3.5), (0, -5.5, 5.45), 0.1, "Steel", segs=6)
    pl.box(B, (4.8, 0.4, 0.4), (0, -5.6, 5.3), "Tan", bevel=0.06)                          # rear frame beam
    pl.taper_box(B, (2.0, 1.4), (1.5, 0.9), 3.35, 3.7, "Tan", loc=(0, -9.85, 0), bevel=0.04)  # nose brow plate
    pl.box(B, (1.3, 0.28, 0.6), (0, -10.9, 2.25), "Orange", bevel=0)                   # orange nose cap
    for s in (1, -1):
        pl.rod(B, (s * 0.5, -10.75, 2.0), (s * 0.5, -11.15, 2.0), 0.04, "Steel", segs=4)    # pitot whiskers

    # ---- armour: tan riveted side plates (forward cheek follows the taper), roof plates, hazard marks
    pl.riveted_plate(B, 3.4, 1.0, 0.14, (HX + 0.03, -1.3, 2.75), side_basis(1), "Tan", "Steel", spacing=1.8,
                     rivet_segs=4)
    pl.riveted_plate(B, 3.4, 1.0, 0.14, (-HX - 0.03, -1.3, 2.75), side_basis(-1), "Tan", "Steel", spacing=1.8,
                     rivet_segs=4)
    for s in (1, -1):
        tan = Vector((0.6 * s, 3.6, 0)).normalized()
        nrm = Vector((s * 3.6, -0.6, 0)).normalized()
        c = Vector((s * 2.4, -6.8, 2.75)) + nrm * 0.02
        pl.riveted_plate(B, 3.1, 1.0, 0.14, c, pl.basis(tan, nrm), "Tan", "Steel", spacing=1.8, rivet_segs=4)
        pl.hazard_stripes(B, 2.4, 0.4, (s * (HX + 0.02), -3.2, 2.45), side_basis(s), stripes=4, c1="Hazard", c2="Black")
        pl.stencil_panel(B, 1.5, 0.7, (s * (2.74 + 0.02), 6.9, 3.2), side_basis(s), "CharcoalDark", "Stencil")
        pl.box(B, (0.1, 3.4, 0.1), (s * (HX + 0.09), -1.3, 3.33), "Orange", bevel=0)       # orange edge line
    pl.riveted_plate(B, 3.2, 3.8, 0.12, (0, -1.0, 4.46), (0, 0, 0), "Tan", "Steel", spacing=1.8, rivet_segs=4, chamfer=0.15)
    pl.riveted_plate(B, 3.0, 2.8, 0.12, (0, 4.2, 4.46), (0, 0, 0), "Tan", "Steel", spacing=1.8, rivet_segs=4, chamfer=0.15)
    pl.hatch(B, 1.2, 1.0, (0, 1.75, 4.47), (0, 0, 0), "CharcoalDark", "Steel", "Orange")        # roof hatch
    pl.vent_grille(B, 1.6, 0.9, 4, (0, 6.9, 4.4), (0, 0, 0), "CharcoalDark", "Black")            # engine deck vent
    pl.box(B, (2.6, 0.22, 0.12), (0, 2.85, 4.44), "Orange", bevel=0)                            # roof cross stripe
    pl.antenna(B, (1.5, 2.2, 4.45), 1.4, color="Steel")

    # ---- engine pods (octagon), stub wings, tail fins
    for s, EG in ((1, EL), (-1, ER)):
        x = s * 4.4
        pl.cyl(B, 1.0, 5.2, (x, 3.1, 2.2), "CharcoalDark", NAC, segs=8)
        pl.cyl(B, 1.0, 0.7, (x, 0.2, 2.2), "Charcoal", NAC, segs=8, r2=0.62)                  # intake cowl
        pl.cyl(B, 0.46, 0.14, (x, -0.2, 2.2), "Black", NAC, segs=8, bevel=0)                  # intake mouth
        pl.cyl(B, 1.03, 0.22, (x, 1.1, 2.2), "Orange", NAC, segs=8, bevel=0)                  # orange band
        pl.cyl(B, 1.03, 0.14, (x, 5.1, 2.2), "Hazard", NAC, segs=8, bevel=0)
        pl.riveted_plate(B, 3.2, 0.9, 0.12, (s * 5.34, 3.0, 2.2), side_basis(s), "Tan", "Steel", spacing=1.8, rivet_segs=4)
        pl.nozzle(B, EG, (x, 5.65, 2.2), (0, 1, 0), 0.9, 0.8, color="CharcoalDark", inner="Black", segs=8)
        # stub wing: root fused to the fuselage, tip beyond the pod, tan plate on top, orange tip cap
        pl.loft(B, [[(s * 2.5, -1.0, 2.35), (s * 2.5, 5.4, 2.35), (s * 2.5, 5.4, 3.2), (s * 2.5, -1.0, 3.2)],
                    [(s * 4.4, 0.6, 2.95), (s * 4.4, 5.0, 2.95), (s * 4.4, 5.0, 3.28), (s * 4.4, 0.6, 3.28)],
                    [(s * 5.7, 1.6, 3.0), (s * 5.7, 4.7, 3.0), (s * 5.7, 4.7, 3.26), (s * 5.7, 1.6, 3.26)]],
                color="CharcoalDark", bevel=0.03)
        pl.plate(B, 1.6, 2.8, 0.1, (s * 3.7, 2.7, 3.26), (0, 0, 0), "Tan", chamfer=0.15)
        pl.box(B, (0.26, 3.2, 0.3), (s * 5.7, 3.15, 3.13), "Orange", bevel=0)
        # tail fin: tan armour slab leaning out, orange tip, hazard foot
        pl.taper_box(B, (0.5, 4.4), (0.3, 2.2), 4.0, 7.4, "Tan", top_offset=(s * 0.55, 1.0), loc=(s * 2.15, 8.4, 0))
        pl.box(B, (0.38, 2.3, 0.28), (s * 2.7, 9.5, 7.3), "Orange", bevel=0)
        pl.hazard_stripes(B, 3.2, 0.55, (s * 2.15, 8.4, 4.5), (0, 0, 0), stripes=5, c1="Hazard", c2="Black")
        # landing skids: rail, forward ski lip, two struts with orange caps
        pl.box(B, (0.6, 9.0, 0.3), (s * 2.75, -0.9, 0.15), "Charcoal", bevel=0.08)
        pl.box(B, (0.6, 1.4, 0.3), (s * 2.75, -5.9, 0.4), "Charcoal", (radians(-25), 0, 0), bevel=0.0)
        for yy in (-4.8, 3.0):
            pl.rod(B, (s * 2.3, yy, 1.75), (s * 2.75, yy + 0.4, 0.3), 0.26, "CharcoalDark", segs=8)
            pl.box(B, (0.55, 0.7, 0.2), (s * 2.55, yy + 0.25, 1.0), "Orange", bevel=0)
            pl.box(B, (0.62, 0.9, 0.14), (s * 2.75, yy + 0.4, 0.38), "Steel", bevel=0)

    # ---- chin gun mount (static ring in the Body) + the rotating Gun part
    gx, gy, gz = 0.0, -7.2, 1.3
    pl.cyl(B, 1.05, 0.2, (gx, gy, 1.34), "CharcoalDark", segs=8)
    pl.cyl(B, 1.15, 0.08, (gx, gy, 1.22), "Orange", segs=8, bevel=0)
    pl.bolt_ring(B, (gx, gy, 1.12), (0, 0, -1), 0.95, 8, 0.05, "Steel")
    pl.cyl(G, 0.85, 0.5, (gx, gy, 1.0), "Charcoal", segs=8)                                    # swivel drum
    pl.taper_box(G, (1.6, 2.4), (1.9, 2.6), 0.62, 0.95, "Tan", loc=(0, -7.55, 0), bevel=0.04)  # armoured chin housing
    pl.box(G, (1.0, 0.5, 0.1), (0, -8.45, 0.98), "Orange", bevel=0)
    for s in (1, -1):
        pl.cyl(G, 0.22, 1.9, (s * 0.4, -9.2, 0.82), "CharcoalDark", pl.AX_Y, segs=8, bevel=0.02)   # shrouds
        pl.cyl(G, 0.11, 1.0, (s * 0.4, -10.35, 0.82), "Steel", pl.AX_Y, segs=6, bevel=0)           # barrels
        pl.cyl(G, 0.2, 0.3, (s * 0.4, -10.7, 0.82), "Black", pl.AX_Y, segs=6, bevel=0)             # muzzle brakes
        pl.box(G, (0.6, 1.0, 0.55), (s * 1.12, -7.1, 0.9), "Olive", bevel=0)                    # ammo boxes
        pl.box(G, (0.5, 0.4, 0.08), (s * 1.12, -7.1, 1.2), "Orange", bevel=0)
        pl.rod(G, (s * 0.85, -7.6, 0.9), (s * 0.5, -8.2, 0.85), 0.07, "Steel", segs=4)             # feed chute
    pl.hazard_stripes(G, 1.5, 0.35, (0, -7.0, 0.575), (pi, 0, 0), stripes=5, c1="Hazard", c2="Black")
    k.attachment("Muzzle", (0, -10.9, 0.82), part="Gun")

    # ---- ramp (rest pose = lowered ~21 deg, hinge at HP); built in a frame rotated about the hinge
    rot = (radians(-21), 0, 0)
    f = pl.frame(HP, rot)
    pl.box(R, (3.3, 4.2, 0.22), f((0, 2.1, -0.11)), "Charcoal", rot, bevel=0.04)
    pl.cyl(R, 0.17, 3.4, f((0, 0, -0.11)), "Steel", pl.AX_X, segs=8, bevel=0)               # hinge barrel
    for i in range(6):
        pl.box(R, (3.0, 0.1, 0.07), f((0, 0.6 + i * 0.62, 0.03)), "Steel", rot, bevel=0)     # cleats
    for s in (1, -1):
        for i in range(0, 7, 2):
            pl.box(R, (0.26, 0.6, 0.1), f((s * 1.62, 0.3 + i * 0.6, 0.05)), "Hazard", rot, bevel=0)
        pl.box(R, (0.26, 4.2, 0.08), f((s * 1.62, 2.1, 0.03)), "Black", rot, bevel=0)
    pl.box(R, (3.4, 0.3, 0.3), f((0, 4.15, -0.15)), "Orange", rot, bevel=0.04)               # lip
    return k


# =============================================================================== EXTRACTION PAD
def hexr(r, z, rot=0.0):
    return [(r * cos(radians(60 * i) + rot), r * sin(radians(60 * i) + rot), z) for i in range(6)]


def build_pad():
    k = pl.Kit("extraction_pad", palette="human", category="set_piece", reset=True)
    B = k.part("Body", "body", "Metal", pivot=(0, 0, 0), color="Concrete")
    lights = {}
    for n, ang in ((1, 60), (2, 120), (3, 240), (4, 300)):
        px, py = cos(radians(ang)) * 6.9, sin(radians(ang)) * 6.9
        lights[n] = (k.glow("Light_%d" % n, rgb=AMBER, role="glow", pivot=(px, py, 3.45), parent="Body"), px, py, ang)

    # ---- slab: dark footing, lighter deck, hazard border on every side, steel apron inside
    pl.loft(B, [hexr(7.85, 0.0), hexr(8.0, 0.12), hexr(8.0, 0.38)], color="ConcreteDark", bevel=0.03)
    pl.loft(B, [hexr(7.75, 0.3), hexr(7.75, 0.56)], color="Concrete", bevel=0.03)
    pl.loft(B, [hexr(5.9, 0.56), hexr(5.9, 0.62)], color="Charcoal", bevel=0.0)
    apo = 8.0 * cos(radians(30))
    for i in range(6):
        th = radians(60 * i + 30)
        d = apo - 0.62
        pl.hazard_stripes(B, 6.0, 0.7, (cos(th) * d, sin(th) * d, 0.575), (0, 0, th + pi / 2), stripes=9,
                          c1="Hazard", c2="Black")
    # landing circle + H (orange)
    pl.torus(B, 4.6, 0.1, (0, 0, 0.64), "Hazard", segs=36, csegs=4)
    pl.torus(B, 4.1, 0.06, (0, 0, 0.64), "Stencil", segs=36, csegs=4)
    for x, y, w, h in ((-1.3, 0, 0.7, 4.4), (1.3, 0, 0.7, 4.4), (0, 0, 2.0, 0.7)):
        pl.box(B, (w, h, 0.07), (x, y, 0.655), "Orange", bevel=0)
    # tie-down rings, grilles, stencil panels
    for ang in (30, 150, 210, 330):
        t = radians(ang)
        c = (cos(t) * 5.2, sin(t) * 5.2)
        pl.cyl(B, 0.4, 0.1, (c[0], c[1], 0.67), "Steel", segs=8, bevel=0)
        pl.torus(B, 0.24, 0.06, (c[0], c[1], 0.76), "Steel", segs=10, csegs=4)
    for sx in (1, -1):
        pl.vent_grille(B, 2.0, 0.9, 4, (sx * 5.3, 0, 0.64), (0, 0, pi / 2), "CharcoalDark", "Black")
    for sy in (1, -1):
        pl.stencil_panel(B, 1.7, 0.75, (0, sy * 5.3, 0.66), (0, 0, 0), "CharcoalDark", "Stencil")
    # conduits from each lamp post toward the apron
    for n in lights:
        _, px, py, ang = lights[n]
        d = Vector((-px, -py, 0)).normalized()
        a = Vector((px, py, 0.6)) + d * 0.5
        bb = Vector((px, py, 0.6)) + d * 1.4
        pl.strip(B, a, bb, (0, 0, 1), 0.2, 0.06, "Black")

    # ---- vertex bollards (0 / 180 deg): charcoal post, orange cap, hazard band
    for sx in (1, -1):
        c = (sx * 7.1, 0.0)
        pl.cyl(B, 0.42, 1.0, (c[0], c[1], 1.06), "Charcoal", segs=6)
        pl.cyl(B, 0.45, 0.18, (c[0], c[1], 1.25), "Hazard", segs=6, bevel=0)
        pl.cyl(B, 0.46, 0.2, (c[0], c[1], 1.66), "Orange", segs=6, bevel=0.02)
        pl.cyl(B, 0.56, 0.12, (c[0], c[1], 0.62), "Steel", segs=6, bevel=0)

    # ---- lamp posts at the four 60-degree corners; lamp head = cage around a recessed glow
    for n in lights:
        g, px, py, ang = lights[n]
        pl.cyl(B, 0.62, 0.36, (px, py, 0.74), "Charcoal", segs=6)
        pl.cyl(B, 0.3, 0.12, (px, py, 1.0), "Orange", segs=6, bevel=0)
        pl.cyl(B, 0.22, 2.2, (px, py, 1.95), "Steel", segs=6, bevel=0)
        pl.cyl(B, 0.27, 0.16, (px, py, 1.4), "Hazard", segs=6, bevel=0)
        pl.cyl(B, 0.27, 0.16, (px, py, 1.72), "Black", segs=6, bevel=0)
        pl.cyl(B, 0.55, 0.2, (px, py, 3.15), "CharcoalDark", segs=6)
        for i in range(6):
            a = radians(60 * i)
            pl.box(B, (0.1, 0.1, 0.4), (px + cos(a) * 0.46, py + sin(a) * 0.46, 3.42), "Charcoal", bevel=0)
        pl.cyl(B, 0.56, 0.14, (px, py, 3.66), "Orange", segs=6)
        pl.cyl(g, 0.32, 0.34, (px, py, 3.45), segs=10, bevel=0.03)
    return k


# =============================================================================== export / render
BUILD = {"skiff": build_skiff, "extraction_pad": build_pad}


def origin_of(k):
    """Meshes.luau `origin`: where the Blender origin sits once Assets centres x/z on the bbox and puts the lowest point at y=0."""
    lo, hi = k.bbox()
    c = (lo + hi) / 2
    return [round(c.x, 3) + 0.0, round(-lo.z, 3) + 0.0, round(-c.y, 3) + 0.0]


def do_export(k):
    os.environ["ORBITFALL_ROOT"] = SCRATCH
    pl.FBX_SETTINGS["apply_scale_options"] = 'FBX_SCALE_ALL'
    k.export_fbx()
    os.makedirs(NEW, exist_ok=True)
    src = os.path.join(SCRATCH, "art", "fbx")
    shutil.copy(os.path.join(src, f"{k.key}.fbx"), os.path.join(NEW, f"{k.key}.fbx"))
    shutil.copy(os.path.join(src, f"palette_{k.palette_name}.png"), os.path.join(NEW, f"palette_{k.palette_name}.png"))
    e = k.manifest_entry()
    e["fbx"] = f"art/fbx/new/{k.key}.fbx"
    e["texture"] = f"art/fbx/new/palette_{k.palette_name}.png"
    e["kind"] = "setpiece"
    e["rigVersion"] = 2
    e["origin"] = origin_of(k)
    e["triangles_total"] = sum(p.tris for p in k.parts)
    e["source"] = "art/blender/extraction_v2.py"
    e.pop("assetId", None)
    with open(os.path.join(NEW, f"{k.key}.entry.json"), "w") as fh:
        json.dump(e, fh, indent=2)
    return e


def do_render(k, tag, views):
    import env_set1
    os.makedirs(IMAGES, exist_ok=True)
    zoom = {"skiff": 0.62}.get(k.key, 1.0)          # the hull is long in Y; stage() frames on X only
    for name, cam in views:
        env_set1.stage(os.path.join(IMAGES, f"{k.key}_new_{name}.png"), [k], size=(900, 900), cam_dir=cam, zoom=zoom)


VIEWS = {
    "skiff": [("front", (0.55, -1.0, 0.5)), ("back", (-0.55, 1.0, 0.45)), ("low", (0.5, -1.0, 0.12))],
    "extraction_pad": [("front", (0.35, -1.0, 0.75)), ("back", (-0.45, 1.0, 0.7))],
}


def main():
    a = [x for x in (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])]
    keys = [x for x in a if not x.startswith("--")]
    keys = [{"pad": "extraction_pad"}.get(x, x) for x in keys] or list(BUILD)
    for key in keys:
        k = BUILD[key]()
        k.report()
        lo, hi = k.bbox()
        s = hi - lo
        print(f"SIZE {key}: roblox x={s.x:.2f} y={s.z:.2f} z={s.y:.2f}  origin={origin_of(k)}  tris={sum(p.tris for p in k.parts)}")
        if "--noexport" not in a:
            do_export(k)
        if "--norender" not in a:
            k = BUILD[key]()            # fresh scene for the preview
            k.build()
            do_render(k, key, VIEWS[key])


if __name__ == "__main__":
    main()
