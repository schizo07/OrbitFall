import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import math, random
import kit
from kit import Part
import envkit as E
from envkit import ROCK_GREY, rock_hull, prism, crystal


def new_rock(name="Rock"):
    return Part(name, ROCK_GREY, "Slate", "body", rough=0.85)


def rock_a(ox=0.0, oy=0.0):
    """Chunky boulder: three offset strata slabs + buried satellite stones."""
    r = new_rock()
    prism(r, 0, 2.4, 5.0, 4.6, sides=7, seed=1, phase=0.2, jitter=0.16)
    prism(r, 2.3, 4.9, 4.7, 3.7, sides=7, c0=(-0.3, 0.2), c1=(-0.2, 0.3), seed=2, phase=0.5, jitter=0.16, rot1=0.15)
    prism(r, 4.8, 6.5, 3.6, 2.2, sides=6, c0=(0.1, 0.2), c1=(0.6, 0.0), seed=3, phase=0.1, jitter=0.18, tilt=(-0.18, 0.1))
    prism(r, 0, 2.1, 2.6, 2.0, sides=6, c0=(4.4, -2.3), c1=(4.4, -2.3), seed=4, tilt=(-0.2, 0.15), jitter=0.2)
    prism(r, 0, 1.7, 2.2, 1.6, sides=6, c0=(-3.9, 2.6), c1=(-3.9, 2.6), seed=5, tilt=(0.2, -0.1), jitter=0.2)
    return E.finish([r], ox=ox, oy=oy)


def rock_b(ox=0.0, oy=0.0):
    """Tall leaning outcrop: tapering slabs stepping up and over."""
    r = new_rock()
    prism(r, 0, 3.0, 5.0, 4.4, sides=7, seed=11, phase=0.3, jitter=0.2)
    prism(r, 2.9, 6.8, 4.4, 3.6, sides=6, c0=(0.0, 0.0), c1=(0.5, 0.2), seed=12, phase=0.6, jitter=0.18, rot1=0.2)
    prism(r, 6.7, 10.4, 3.6, 2.8, sides=6, c0=(0.5, 0.2), c1=(1.3, 0.3), seed=13, phase=0.2, jitter=0.18, rot1=-0.2)
    prism(r, 10.3, 14.0, 2.8, 1.0, sides=5, c0=(1.3, 0.3), c1=(2.6, 0.2), seed=14, phase=0.4, jitter=0.2, tilt=(-0.25, 0))
    prism(r, 0, 2.4, 2.8, 2.0, sides=6, c0=(-4.6, -2.3), c1=(-4.6, -2.3), seed=15, tilt=(0.25, 0.1), jitter=0.2)
    prism(r, 0, 4.2, 2.6, 1.8, sides=5, c0=(3.8, -3.0), c1=(4.2, -3.2), seed=16, jitter=0.2)
    return E.finish([r], ox=ox, oy=oy)


def rock_c(ox=0.0, oy=0.0):
    """Low wide ledge: stepped flat-topped terraces."""
    r = new_rock()
    prism(r, 0, 3.0, 5.0, 4.6, sides=7, c0=(0, 0), seed=21, squash=(1.45, 0.95), phase=0.1, jitter=0.14)
    prism(r, 2.9, 5.2, 3.6, 3.2, sides=6, c0=(-3.2, 0.2), c1=(-3.2, 0.2), seed=22, squash=(1.1, 1.0), tilt=(0.0, 0.0), jitter=0.16)
    prism(r, 2.9, 4.4, 3.2, 2.7, sides=6, c0=(3.6, -0.6), c1=(3.6, -0.6), seed=23, tilt=(-0.12, 0.05), jitter=0.16)
    prism(r, 5.1, 7.0, 2.6, 1.4, sides=6, c0=(-3.0, 0.4), c1=(-2.7, 0.2), seed=24, tilt=(0.15, 0.1), jitter=0.18)
    prism(r, 0, 2.0, 3.0, 2.2, sides=6, c0=(0.5, -4.2), c1=(0.5, -4.2), seed=25, tilt=(0.1, -0.2), jitter=0.2)
    prism(r, 0, 1.4, 2.0, 1.4, sides=5, c0=(6.8, 2.4), c1=(6.8, 2.4), seed=26, jitter=0.2)
    return E.finish([r], ox=ox, oy=oy)


def spire_a(ox=0.0, oy=0.0):
    """Hoodoo: broad faceted stem, one big erosion ledge, heavy overhanging caprock."""
    r = new_rock()
    kw = dict(sides=7, step_jit=0.25, phase_jit=0.04, bevel=0.0, rot_jit=0.3, ledge=0.0)
    top = E.column(r, (0, 0), 14.0, 11.5, 6.8, 2, seed=3, p=0.8, wobble=0.06, **kw)
    top = E.column(r, (top[0], top[1]), 9.0, 7.2, 5.6, 2, seed=5, z0=top[2], lean=(0.05, -0.02), wobble=0.05, **kw)
    # erosion ledge: a fat wedge sticking out of the stem
    z = top[2]
    prism(r, z, z + 3.0, 5.6, 7.4, sides=7, c0=(top[0], top[1]), c1=(top[0], top[1]), seed=31, jitter=0.14, bevel=0.0, phase=0.4)
    prism(r, z + 3.0, z + 6.0, 7.4, 4.4, sides=7, c0=(top[0], top[1]), c1=(top[0] - 0.2, top[1]), seed=32, jitter=0.14, bevel=0.0, phase=0.45)
    z += 6.0
    top = E.column(r, (top[0] - 0.2, top[1]), 6.0, 4.4, 4.0, 2, seed=9, z0=z, wobble=0.04, **kw)       # eroded neck
    z = top[2]
    prism(r, z, z + 3.2, 4.4, 8.6, sides=7, c0=(top[0], top[1]), c1=(top[0] - 0.6, top[1] + 0.3), seed=41, jitter=0.1, phase=0.2, bevel=0.1)
    prism(r, z + 3.2, z + 5.6, 8.6, 7.8, sides=7, c0=(top[0] - 0.6, top[1] + 0.3), c1=(top[0] - 0.5, top[1] + 0.3), seed=42, jitter=0.1, phase=0.3, tilt=(0.0, 0.04), bevel=0.1)
    prism(r, z + 5.6, z + 7.2, 6.8, 3.4, sides=7, c0=(top[0] - 0.4, top[1] + 0.3), c1=(top[0] - 1.6, top[1] + 0.4), seed=43, jitter=0.15, phase=0.1, tilt=(-0.1, 0), bevel=0.1)
    for (x, y, s, sd) in ((11.5, 3.5, 3.8, 2), (-10.5, -6.5, 4.2, 5), (1.5, -11.5, 3.4, 6), (-10.0, 6.0, 3.2, 8), (8.5, -9.0, 2.8, 9), (-2.5, 11.5, 2.6, 10)):
        prism(r, 0, s * 0.9, s * 1.1, s * 0.8, sides=6, c0=(x, y), seed=sd, jitter=0.2, tilt=(0.12, -0.1))
    return E.finish([r], ox=ox, oy=oy)


def spire_b(ox=0.0, oy=0.0):
    """Three-fang crag: broad faceted blades leaning apart on a broken plinth."""
    r = new_rock()
    prism(r, 0, 3.0, 13.0, 11.0, sides=9, c0=(0, 1.0), seed=60, jitter=0.15, phase=0.2, squash=(1.0, 0.8))
    prism(r, 2.9, 5.5, 9.5, 7.0, sides=8, c0=(0, 1.0), c1=(0.3, 1.2), seed=61, jitter=0.18, phase=0.5)
    kw = dict(wobble=0.07, step_jit=0.3, ledge=0.12, phase_jit=0.05, bevel=0.0)
    def tip(t, rad, sq, h):
        prism(r, t[2], t[2] + h, rad, 0.12, sides=7, c0=(t[0], t[1]), c1=(t[0] + 0.4, t[1]), seed=77, squash=sq, bevel=0.0, jitter=0.1)
    tip(E.column(r, (0, 0), 42.0, 6.4, 0.9, 5, seed=11, z0=3.5, lean=(0.06, 0.012), squash=(1.55, 0.8), p=0.9, sides=7, **kw), 0.9, (1.55, 0.8), 3.0)
    tip(E.column(r, (-8.0, 4.5), 27.0, 5.4, 0.8, 4, seed=12, z0=3.0, lean=(-0.08, 0.03), squash=(1.2, 0.95), p=0.9, sides=7, **kw), 0.8, (1.2, 0.95), 2.4)
    tip(E.column(r, (7.0, 6.5), 21.0, 4.8, 0.7, 4, seed=13, z0=3.0, lean=(0.03, 0.09), squash=(1.0, 1.2), p=0.9, sides=6, **kw), 0.7, (1.0, 1.2), 2.0)
    for (x, y, s, sd) in ((11.5, -4.5, 3.4, 2), (-11.0, -3.5, 3.2, 5), (1.0, -8.5, 2.8, 6), (-3.5, 11.0, 2.8, 8), (10.0, 10.0, 2.4, 9)):
        prism(r, 0, s * 0.9, s * 1.1, s * 0.8, sides=6, c0=(x, y), seed=sd, jitter=0.2, tilt=(0.12, -0.1))
    return E.finish([r], ox=ox, oy=oy)


def crystal_cluster(ox=0.0, oy=0.0):
    base = new_rock("Base")
    cry = Part("Crystal", (140, 225, 255), "Neon", "weak")
    prism(base, 0, 1.6, 3.6, 2.9, sides=7, c0=(0, 0), seed=4, jitter=0.15, tilt=(0.0, 0.05))
    prism(base, 0, 1.0, 1.9, 1.4, sides=6, c0=(2.9, -1.9), seed=8, jitter=0.2, tilt=(0.12, 0.0))
    prism(base, 0, 0.9, 1.6, 1.2, sides=6, c0=(-2.7, 2.0), seed=9, jitter=0.2, tilt=(-0.1, 0.0))
    prism(base, 0, 0.8, 1.4, 1.0, sides=5, c0=(-1.2, -3.0), seed=10, jitter=0.2)
    rg = random.Random(12)
    spec = [((0.0, 0.0), 6.0, 0.95, (0.4, 0.2)), ((1.3, 0.8), 4.4, 0.7, (1.0, 0.5)), ((-1.2, 0.9), 4.8, 0.72, (-1.0, 0.6)),
            ((0.4, -1.3), 3.8, 0.62, (0.3, -1.1)), ((-1.6, -0.6), 3.2, 0.55, (-1.2, -0.3)), ((2.2, -0.6), 2.8, 0.5, (1.1, -0.3)),
            ((-0.2, 1.9), 2.6, 0.46, (-0.1, 0.9)), ((1.8, 1.7), 2.0, 0.4, (0.6, 0.6))]
    for (x, y), h, r_, lean in spec:
        crystal(cry, (x, y, 0.7), h, r_, lean=lean, phase=rg.uniform(0, 1))
    return E.finish([base, cry], ox=ox, oy=oy)


MODELS = {
    "rock_a": (rock_a, dict(target=(0, 0, 3.0), dist=24, height=7)),
    "rock_b": (rock_b, dict(target=(0, 0, 6.0), dist=32, height=9)),
    "rock_c": (rock_c, dict(target=(0, 0, 2.6), dist=28, height=8)),
    "spire_a": (spire_a, dict(target=(0, 0, 18.0), dist=100, height=22)),
    "spire_b": (spire_b, dict(target=(0, 0, 20.0), dist=105, height=22)),
    "crystal_cluster": (crystal_cluster, dict(target=(0, 0, 2.6), dist=17, height=5)),
}

if __name__ == "__main__":
    only = (sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []) or list(MODELS)
    for name in only:
        fn, cam = MODELS[name]
        kit.reset()
        parts = fn()
        kit.stage(yaw=-35, floor=cam["dist"] * 0.8, boost=0.95, **cam)
        kit.render("env_" + name)
        kit.write_manifest("env_" + name, parts)
        kit.export_fbx("env_" + name)
