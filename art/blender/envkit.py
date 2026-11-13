"""Environment-kit helpers: faceted hull rocks, strata spires, crystals."""
import math
import random
from mathutils import Vector, Matrix
import kit
from kit import Part

ROCK_GREY = (200, 200, 200)


def rock_hull(part, c, radii, seed, n=14, jit=0.26, base=None, top=None, rot=0.0, shear=(0, 0), mirror=False, bevel=0.0, cuts=6, cut_k=(0.45, 0.78), taper=0.0):
    """Chunky faceted rock: convex hull of a jittered point cloud on an ellipsoid.
    base/top clamp z so the rock gets a flat bottom / flat top."""
    rg = random.Random(seed)
    pts = []
    planes = []
    for _ in range(cuts):
        a = rg.uniform(0, 6.283)
        nz = rg.uniform(-0.2, 0.85)
        nn = Vector((math.cos(a), math.sin(a), nz)).normalized()
        planes.append((nn, rg.uniform(*cut_k)))
    ga = math.pi * (3 - math.sqrt(5))
    off = rg.random() * 6.28
    for i in range(n):
        z = 1 - 2 * (i + 0.5) / n
        rr = math.sqrt(max(0.0, 1 - z * z))
        a = ga * i + off
        d = Vector((math.cos(a) * rr, math.sin(a) * rr, z))
        k = 1 + rg.uniform(-jit, jit)
        p = Vector((d.x * radii[0] * k, d.y * radii[1] * k, d.z * radii[2] * (1 + rg.uniform(-jit, jit) * 0.5)))
        for nn, k in planes:                      # planar chops give big flat facets
            dd = (p.x / radii[0]) * nn.x + (p.y / radii[1]) * nn.y + (p.z / radii[2]) * nn.z
            if dd > k:
                p = Vector((p.x - nn.x * (dd - k) * radii[0], p.y - nn.y * (dd - k) * radii[1], p.z - nn.z * (dd - k) * radii[2]))
        if taper:
            f_ = 1 - taper * (p.z / radii[2] + 1) / 2
            p.x *= f_
            p.y *= f_
        p.x += shear[0] * p.z
        p.y += shear[1] * p.z
        if rot:
            p = Matrix.Rotation(math.radians(rot), 3, "Z") @ p
        p = p + Vector(c)
        if base is not None:
            p.z = max(p.z, base)
        if top is not None:
            p.z = min(p.z, top)
        pts.append(tuple(p))
    part.hull(pts, bevel=bevel, seg=1, mirror=mirror)


def prism(part, z0, z1, r0, r1, sides=8, c0=(0, 0), c1=None, jit=None, phase=0.0, squash=(1, 1), bevel=0.14, tilt=(0, 0), seed=None,
          jitter=0.18, rot1=0.0):
    """Faceted stratum slab between two polygon rings (jit = per-vertex radius multipliers).
    tilt slopes the top ring (dz per stud in x/y); seed generates jitter when jit is None."""
    c1 = c1 or c0
    if jit is None and seed is not None:
        rg = random.Random(seed)
        jit = [1 + rg.uniform(-jitter, jitter) for _ in range(sides)]
    pts = []
    for k in range(sides):
        a = phase + 2 * math.pi * k / sides
        a1 = a + rot1
        j = jit[k % len(jit)] if jit else 1.0
        pts.append((c0[0] + math.cos(a) * r0 * j * squash[0], c0[1] + math.sin(a) * r0 * j * squash[1], z0))
        x1 = c1[0] + math.cos(a1) * r1 * j * squash[0]
        y1 = c1[1] + math.sin(a1) * r1 * j * squash[1]
        pts.append((x1, y1, z1 + tilt[0] * (x1 - c1[0]) + tilt[1] * (y1 - c1[1])))
    part.hull(pts, bevel=bevel, seg=1)


def crystal(part, base, height, r, lean=(0, 0), sides=6, tip=0.38, tip_h=0.28, phase=0.0, rot=0.0):
    """Hex crystal with a chiselled point. base = (x,y,z); lean = (dx,dy) offset of the tip."""
    pts = []
    for k in range(sides):
        a = phase + 2 * math.pi * k / sides
        pts.append((base[0] + math.cos(a) * r, base[1] + math.sin(a) * r, base[2]))
        pts.append((base[0] + math.cos(a) * r * 0.92 + lean[0] * (1 - tip_h), base[1] + math.sin(a) * r * 0.92 + lean[1] * (1 - tip_h),
                    base[2] + height * (1 - tip_h)))
    pts.append((base[0] + lean[0], base[1] + lean[1], base[2] + height))
    part.hull(pts, bevel=0.0, seg=1)
    # a small shoulder ring gives the chisel point a second facet band
    return part


def finish(parts, smooth_angle=1.0, ox=0.0, oy=0.0):
    for p in parts:
        ob = p.build(smooth_angle=smooth_angle)
        ob.location.x += ox
        ob.location.y += oy
    return parts


def column(part, c, h, r_base, r_top, layers, seed, lean=(0, 0), squash=(1, 1), p=1.0, wobble=0.16, sides=7, z0=0.0,
           ledge=0.25, step_jit=0.5, rot_jit=0.5, tilt_top=0.0, phase_jit=0.12, bevel=0.06):
    """Eroded strata column: random layer thicknesses, ledges and offsets; returns (x, y, z) of the top centre."""
    rg = random.Random(seed)
    ph0 = rg.uniform(0, 6.28)
    th = [1 + rg.uniform(-step_jit, step_jit) for _ in range(layers)]
    tot = sum(th)
    z = z0
    ox, oy = c
    prev = None
    for i in range(layers):
        t0 = sum(th[:i]) / tot
        t1 = sum(th[:i + 1]) / tot
        rad = lambda t: r_base + (r_top - r_base) * (t ** p)
        w0 = prev if prev is not None else 1 + rg.uniform(-wobble, wobble)
        w1 = 1 + rg.uniform(-wobble, wobble)
        if rg.random() < ledge:
            w1 *= 1.25                      # overhanging ledge
        elif rg.random() < ledge:
            w1 *= 0.8                       # eroded notch
        prev = w1
        dz = h * (t1 - t0)
        c0 = (ox, oy)
        ox += lean[0] * dz + rg.uniform(-0.25, 0.25) * rad(t0) * 0.3
        oy += lean[1] * dz + rg.uniform(-0.25, 0.25) * rad(t0) * 0.3
        tl = (rg.uniform(-0.2, 0.2) * tilt_top, rg.uniform(-0.2, 0.2) * tilt_top)
        prism(part, z, z + dz, rad(t0) * w0, rad(t1) * w1, sides=sides, c0=c0, c1=(ox, oy), seed=seed * 100 + i,
              phase=ph0 + rg.uniform(-phase_jit, phase_jit), jitter=0.16, squash=squash, rot1=rg.uniform(-rot_jit, rot_jit) * 0.2, tilt=tl, bevel=bevel)
        z += dz
    return (ox, oy, z)


def torus(part, c, normal, R, r, segs=16, rsegs=6, squash=(1.0, 1.0), mirror=False):
    """Donut (lip ring) centred at c, axis along `normal`; squash=(sx, sy) makes the ring elliptical."""
    import bmesh
    bm = bmesh.new()
    rows = []
    for i in range(segs):
        a = 2 * math.pi * i / segs
        row = []
        for j in range(rsegs):
            b = 2 * math.pi * j / rsegs
            rad = R + r * math.cos(b)
            row.append(bm.verts.new((math.cos(a) * rad * squash[0], math.sin(a) * rad * squash[1], r * math.sin(b))))
        rows.append(row)
    for i in range(segs):
        for j in range(rsegs):
            i2, j2 = (i + 1) % segs, (j + 1) % rsegs
            bm.faces.new((rows[i][j], rows[i2][j], rows[i2][j2], rows[i][j2]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    m = Vector(normal).normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    part._add(bm, tuple(c), m, mirror)
