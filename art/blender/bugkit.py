"""Skitter Brood helpers on top of kit.py: palette, splines, horns, insect legs."""
import math
from mathutils import Vector
import kit
from kit import Part

# ---- Skitter Brood palette -------------------------------------------------------------
CARAPACE = (88, 52, 120)
CARAPACE_DK = (62, 36, 92)
CARAPACE_LT = (112, 70, 150)
LILAC = (170, 130, 200)
ACID = (140, 255, 60)
BONE = (235, 220, 190)

GLOSS = 0.22  # carapace is shiny


def spline(pts, n=4):
    """Catmull-Rom through pts, n samples per span."""
    P = [Vector(p) for p in pts]
    ext = [P[0] * 2 - P[1]] + P + [P[-1] * 2 - P[-2]]
    out = []
    for i in range(1, len(ext) - 2):
        p0, p1, p2, p3 = ext[i - 1], ext[i], ext[i + 1], ext[i + 2]
        for k in range(n):
            t = k / n
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    out.append(P[-1])
    return out


def chain(part, pts, r0, r1, n=3, verts=10, mirror=False, joint=True, bevel=0.0, curve=1.0):
    """Tapered curved horn/claw/tendril through pts (radius r0 -> r1)."""
    s = spline(pts, n) if n > 1 else [Vector(p) for p in pts]
    m = len(s) - 1
    rad = lambda i: r0 + (r1 - r0) * ((i / m) ** curve)
    for i in range(m):
        part.tube(tuple(s[i]), tuple(s[i + 1]), rad(i), rad(i + 1), verts=verts, bevel=bevel, mirror=mirror)
        if joint and i > 0:
            part.ball(rad(i), tuple(s[i]), segs=verts, mirror=mirror)
    return part


def cone(part, base, tip, r, verts=10, mirror=False, bevel=0.0):
    part.tube(base, tip, r, max(r * 0.04, 0.01), verts=verts, bevel=bevel, mirror=mirror)


def leg(legs, claws, hip, knee, foot, r=0.24, mirror=True, verts=10, claw=True, seg=10, spike=True, r_end=0.55, boot=0.78, bh=None, pad=None, switch=None):
    """Two-segment insect leg: thick femur, ball knee (+cream knee spike), tapering tibia, cream boot.
    switch: optional callback invoked between the upper pieces (hip..knee) and the lower pieces (tibia..boot)
    so a rig can route them into separate limbs; the geometry is identical either way."""
    f = Vector(foot)
    bh = bh if bh is not None else max(0.5, r * boot * 0.95)
    k = Vector(knee)
    h = Vector(hip)
    shells = ((h, k, 0.62), (k, f + Vector((0, 0, bh)), 0.7))

    def shell(i):
        a_, b_, ln = shells[i]
        d_ = b_ - a_
        mid_ = a_ + d_ * 0.5 + Vector((0, 0, r * 0.55))
        m_ = d_.normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
        pad.ball(1.0, tuple(mid_), scale=(r * 1.05, r * 0.8, d_.length * 0.5 * ln + r * 0.4), segs=10, rot=m_, mirror=mirror)

    # -- upper: hip ball, femur, knee ball, knee cap + femur shell, knee spike
    legs.ball(r * 1.15, hip, segs=seg, mirror=mirror)
    legs.tube(hip, knee, r * 1.1, r * 1.0, verts=verts, bevel=0.0, mirror=mirror)
    legs.ball(r * 1.12, knee, segs=seg, mirror=mirror)
    if pad is not None:
        pad.ball(r * 1.3, knee, scale=(1, 1, 0.85), segs=10, mirror=mirror)   # carapace knee cap
        shell(0)
    if spike:
        up = ((k - h).normalized() + Vector((0, 0, 1.0))).normalized()
        claws.tube(tuple(k + up * r * 0.6), tuple(k + up * (r * 0.6 + 0.62)), r * 0.55, 0.03, verts=8, bevel=0.0, mirror=mirror)
    if switch:
        switch()
    # -- lower: tibia, tibia shell, boot
    legs.tube(knee, tuple(f + Vector((0, 0, bh + 0.05))), r * 1.0, r * r_end, verts=verts, bevel=0.0, mirror=mirror)
    if pad is not None:
        shell(1)
    if claw:
        claws.ball(r * boot, tuple(f + Vector((0, 0, bh))), segs=seg, mirror=mirror)
        claws.tube(tuple(f + Vector((0, 0, bh))), foot, r * boot * 0.92, 0.05, verts=verts, bevel=0.0, mirror=mirror)


def eye_cluster(eye, c, facing, r_big=0.36, r_small=0.17, n=5, ring=0.42, mirror=True, segs=12, tilt=0.0):
    """One big glowing eye ringed by n small ones, in the plane perpendicular to `facing`."""
    f = Vector(facing).normalized()
    up = Vector((0, 0, 1))
    a = f.cross(up).normalized()
    b = f.cross(a).normalized()
    c = Vector(c)
    eye.ball(r_big, tuple(c), segs=segs, mirror=mirror)
    for i in range(n):
        t = 2 * math.pi * (i + 0.5) / n + tilt
        p = c + (a * math.cos(t) + b * math.sin(t)) * ring - f * 0.05
        eye.ball(r_small, tuple(p), segs=8, mirror=mirror)


def ground_plane_check(parts):
    lo, hi = kit.bbox(parts)
    return lo, hi


def ring(part, c, direction, r, thick, segs=16, mirror=False):
    """Flat disc (squashed ball) centred at c with its axis along `direction`."""
    m = Vector(direction).normalized().to_track_quat("Z", "Y").to_matrix().to_4x4()
    part.ball(r, tuple(c), scale=(1, 1, thick / r), segs=segs, rot=m, mirror=mirror)


def segments(body, accent, pts, r0, r1, n=4, squash=1.0, ring_every=1, segs=14, accent_r=1.06):
    """Caterpillar-style stack of carapace balls along a spline, with lilac discs between them."""
    s = spline(pts, n)
    m = len(s) - 1
    for i, p in enumerate(s):
        t = i / m
        r = r0 + (r1 - r0) * t
        body.ball(r, tuple(p), segs=segs, scale=(1, 1, 1))
        if accent is not None and i < m and i % ring_every == 0:
            d = s[i + 1] - p
            mid = (p + s[i + 1]) / 2
            ring(accent, mid, d, r * accent_r, 0.07, segs=segs)


def scale_parts(parts, s):
    """Scale already-built parts about the origin (feet stay at z=0). s = float or (sx, sy, sz)."""
    from mathutils import Matrix
    sx, sy, sz = (s, s, s) if not isinstance(s, (tuple, list)) else s
    M = Matrix.Diagonal((sx, sy, sz, 1.0))
    for p in parts:
        p.obj.data.transform(M)
        p.obj.data.update()
