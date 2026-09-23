"""Master fingerprints: the full ridge pattern of one synthetic finger.

A master is generated once per (subject seed, finger) and every impression of
that finger (rolled, plain, slap, later captures) is derived from it, so all of
them share the same ridge pattern and minutiae.

Finger numbers follow ANSI/NIST-ITL FGP codes: 1 right thumb ... 5 right little,
6 left thumb ... 10 left little. Images are "as printed": a right hand's ulnar
(little-finger) side is on the right, so an ulnar loop on a right hand is a
right loop and on a left hand a left loop.
"""

from dataclasses import dataclass, field
from functools import lru_cache

import numpy as np

from .synthesis import grow_ridges, rng_for, smooth_noise, smooth_orientation, zero_pole_orientation

# Master canvas covering the whole unrolled fingertip surface, at 500 ppi.
MASTER_W, MASTER_H = 820, 900

# Pattern class priors per finger (thumb, index, middle, ring, little), roughly
# following published population frequencies: loops dominate, whorls are common
# on thumbs and ring fingers, arches and radial loops mostly on index fingers.
CLASS_PRIORS = {
    "thumb": {"whorl": 0.45, "ulnar_loop": 0.47, "radial_loop": 0.02, "arch": 0.03, "tented_arch": 0.03},
    "index": {"whorl": 0.30, "ulnar_loop": 0.37, "radial_loop": 0.17, "arch": 0.07, "tented_arch": 0.09},
    "middle": {"whorl": 0.22, "ulnar_loop": 0.66, "radial_loop": 0.03, "arch": 0.05, "tented_arch": 0.04},
    "ring": {"whorl": 0.42, "ulnar_loop": 0.52, "radial_loop": 0.01, "arch": 0.03, "tented_arch": 0.02},
    "little": {"whorl": 0.14, "ulnar_loop": 0.82, "radial_loop": 0.01, "arch": 0.02, "tented_arch": 0.01},
}

FINGER_NAMES = ["thumb", "index", "middle", "ring", "little"]

# Relative fingertip size: ridge spacing and contact area scale with it.
FINGER_SCALE = {"thumb": 1.12, "index": 1.0, "middle": 1.02, "ring": 0.97, "little": 0.88}

MASTER_SALT = 1


@dataclass
class Master:
    finger: int
    hand: str
    name: str
    pattern: str  # arch, tented_arch, left_loop, right_loop, whorl
    cores: list
    deltas: list
    period: float
    scale: float
    ridges: np.ndarray = field(repr=False)  # float32 in [-1, 1], ridges positive
    orientation: np.ndarray = field(repr=False)


def hand_of(finger):
    return "right" if finger <= 5 else "left"


def name_of(finger):
    return FINGER_NAMES[(finger - 1) % 5]


def choose_pattern(finger, rng):
    priors = CLASS_PRIORS[name_of(finger)]
    kinds = list(priors)
    kind = rng.choice(kinds, p=np.array([priors[k] for k in kinds]) / sum(priors.values()))
    if kind in ("ulnar_loop", "radial_loop"):
        ulnar_side = "right" if hand_of(finger) == "right" else "left"
        radial_side = "left" if ulnar_side == "right" else "right"
        return f"{ulnar_side if kind == 'ulnar_loop' else radial_side}_loop"
    return str(kind)


def singular_points(pattern, rng):
    """Cores and deltas (master coordinates) for a pattern class."""
    cx = MASTER_W * (0.5 + rng.normal(0, 0.03))
    cy = MASTER_H * (0.40 + rng.normal(0, 0.03))

    if pattern in ("left_loop", "right_loop"):
        # The delta sits below the core, on the side opposite the loop's opening.
        side = -1 if pattern == "right_loop" else 1
        dx = side * rng.uniform(170, 250)
        dy = rng.uniform(200, 280)
        return [(cx - 0.15 * dx, cy)], [(cx + dx, cy + dy)]

    if pattern == "whorl":
        gap = rng.uniform(40, 90)
        tilt = rng.normal(0, 25)
        cores = [(cx - tilt / 2, cy - gap / 2), (cx + tilt / 2, cy + gap / 2)]
        spread = rng.uniform(230, 290)
        drop = rng.uniform(210, 280)
        deltas = [
            (cx - spread, cy + drop + rng.normal(0, 25)),
            (cx + spread, cy + drop + rng.normal(0, 25)),
        ]
        return cores, deltas

    if pattern == "tented_arch":
        return [(cx, cy + 20)], [(cx + rng.normal(0, 8), cy + rng.uniform(90, 130))]

    return [], []  # plain arch


def arch_orientation(rng):
    """Arch: ridges run across the finger and rise into a smooth hump."""
    y, x = np.mgrid[0:MASTER_H, 0:MASTER_W].astype(np.float32)
    height = rng.uniform(1.6, 2.6)
    centre = MASTER_W * (0.5 + rng.normal(0, 0.04))
    width = MASTER_W * rng.uniform(0.22, 0.32)
    # Ridge curves y = y0 - A(y0) * exp(-(x - c)^2 / 2w^2); the hump flattens out
    # towards the tip and the crease.
    amplitude = height * np.clip(1 - np.abs(y / MASTER_H - 0.55) / 0.55, 0, 1)
    slope = amplitude * (x - centre) / width * np.exp(-((x - centre) ** 2) / (2 * width**2))
    return np.mod(np.arctan(slope), np.pi).astype(np.float32)


def flatten_far_field(theta, cores, deltas):
    """Pull orientation towards horizontal near the tip and the crease.

    The zero-pole model alone leaves ridges near the edges of the fingertip at
    odd angles; real fingers have ridges wrapping over the tip and running
    across the finger near the flexion crease.
    """
    if not deltas:
        return theta
    y = np.arange(MASTER_H, dtype=np.float32)[:, None]
    lowest_delta = max(d[1] for d in deltas)
    top_core = min(c[1] for c in cores) if cores else lowest_delta
    below = np.clip((y - lowest_delta - 60) / 180, 0, 1)
    above = np.clip((top_core - 140 - y) / 200, 0, 1)
    weight = np.maximum(below, above) * np.ones((1, MASTER_W), np.float32)
    c = (1 - weight) * np.cos(2 * theta) + weight * 1.0
    s = (1 - weight) * np.sin(2 * theta)
    return np.mod(0.5 * np.arctan2(s, c), np.pi).astype(np.float32)


@lru_cache(maxsize=48)
def master(seed, finger):
    rng = rng_for(seed, finger, MASTER_SALT)
    name = name_of(finger)
    pattern = choose_pattern(finger, rng)
    cores, deltas = singular_points(pattern, rng)

    if pattern == "arch":
        theta = arch_orientation(rng)
    else:
        theta = zero_pole_orientation((MASTER_H, MASTER_W), cores, deltas)
        theta = flatten_far_field(theta, cores, deltas)

    # Natural wobble in the flow, then smooth away sharp kinks (but keep the
    # singular points, which need a small smoothing radius).
    wobble = smooth_noise(theta.shape, rng, scale=180, amplitude=0.12)
    theta = smooth_orientation(np.mod(theta + wobble, np.pi), sigma=6)

    scale = FINGER_SCALE[name] * rng.uniform(0.95, 1.05)
    period = rng.uniform(8.8, 10.2) * (0.94 + 0.06 * scale)
    period_map = period * (1 + smooth_noise(theta.shape, rng, scale=300, amplitude=0.05))

    ridges = grow_ridges(theta, period_map, rng, iterations=14)

    return Master(
        finger=finger,
        hand=hand_of(finger),
        name=name,
        pattern=pattern,
        cores=[(float(x), float(y)) for x, y in cores],
        deltas=[(float(x), float(y)) for x, y in deltas],
        period=float(period),
        scale=float(scale),
        ridges=ridges,
        orientation=theta,
    )
