"""Palmprints: full palms (PLP 21 right, 23 left) and writer's palms (22, 24).

A palm master holds the ridge pattern plus the flexion creases of one hand, so
the full palm and the writer's palm of that hand, and every later capture, show
the same ridges and creases.

Anatomy is laid out for a right hand "as printed" (thumb side on the left,
little-finger side on the right) and mirrored for the left hand. The ridge flow
comes from a zero-pole model with one delta (triradius) below each finger (a-d)
and the axial triradius t near the wrist, balanced by a core at the base of
each finger and of the thumb, which is where the finger ridges wrap around.

Ridges are grown at 250 ppi and upsampled to 500 ppi: a full palm at 500 ppi is
2750 x 4000 px, and ridge growth at that size is slow and memory hungry, while
the smooth ridge field upsamples cleanly.
"""

from dataclasses import dataclass, field
from functools import lru_cache

import cv2
import numpy as np

from . import impression as imp
from .synthesis import grow_ridges, rng_for, smooth_noise, smooth_orientation, zero_pole_orientation

MASTER_W, MASTER_H = 2900, 4200  # 500 ppi
FULL_SIZE = (2750, 4000)  # 5.5 x 8.0 in
WRITERS_SIZE = (875, 2500)  # 1.75 x 5.0 in

PALM_SALT, FULL, WRITERS = 3, 21, 22

# Palm outline for a right hand, normalised (u right, v down), clockwise from
# the thumb web.
OUTLINE = [
    (0.07, 0.16), (0.13, 0.06), (0.22, 0.02), (0.31, 0.07), (0.35, 0.085),
    (0.45, 0.01), (0.54, 0.075), (0.57, 0.085), (0.66, 0.03), (0.74, 0.10),
    (0.77, 0.115), (0.86, 0.09), (0.95, 0.17), (0.985, 0.35), (0.98, 0.62),
    (0.955, 0.84), (0.88, 0.95), (0.70, 0.99), (0.48, 0.995), (0.28, 0.975),
    (0.12, 0.88), (0.035, 0.72), (0.01, 0.55), (0.03, 0.36),
]


@dataclass
class PalmMaster:
    hand: str
    ridges: np.ndarray = field(repr=False)  # float32 [-1, 1], 500 ppi
    creases: np.ndarray = field(repr=False)  # float32 0..1, 1 = deep crease
    outline: np.ndarray = field(repr=False)  # float32 0..1 palm area
    triradii: dict = field(default_factory=dict)
    patterns: list = field(default_factory=list)


@lru_cache(maxsize=4)
def master(seed, hand):
    """Palm master for `hand` ('right' or 'left')."""
    rng = rng_for(seed, 1 if hand == "right" else 2, PALM_SALT)
    h, w = MASTER_H // 2, MASTER_W // 2  # grown at 250 ppi

    def at(u, v, su=0.015, sv=0.015):
        return (w * (u + rng.normal(0, su)), h * (v + rng.normal(0, sv)))

    fingers = {"index": at(0.22, -0.02), "middle": at(0.45, -0.035), "ring": at(0.66, -0.02),
               "little": at(0.86, 0.04), "thumb": at(-0.06, 0.62, 0.02, 0.04)}
    triradii = {"a": at(0.25, 0.17), "b": at(0.46, 0.16), "c": at(0.65, 0.17), "d": at(0.83, 0.21),
                "t": at(0.55, 0.88, 0.04, 0.03)}
    cores = list(fingers.values())
    deltas = list(triradii.values())
    patterns = []

    # Optional true patterns: each adds a core with its own delta nearby, so the
    # far-field flow stays balanced.
    if rng.random() < 0.45:
        core = at(0.57, 0.11, 0.02, 0.01)
        cores.append(core)
        deltas.append((core[0] + w * 0.03, core[1] + h * 0.05))
        patterns.append("interdigital_loop")
    if rng.random() < 0.3:
        core = at(0.84, 0.62, 0.02, 0.05)
        cores.append(core)
        deltas.append((core[0] - w * 0.10, core[1] + h * 0.04))
        patterns.append("hypothenar_loop")

    theta = zero_pole_orientation((h, w), cores, deltas, base=np.float32(rng.normal(0, 0.05)))
    theta = np.mod(theta + smooth_noise((h, w), rng, 220, 0.10), np.pi)
    theta = smooth_orientation(theta, sigma=4)
    period = rng.uniform(4.5, 5.0) * (1 + smooth_noise((h, w), rng, 400, 0.05))
    small = grow_ridges(theta, period, rng, iterations=14)
    ridges = cv2.resize(small, (MASTER_W, MASTER_H), interpolation=cv2.INTER_CUBIC)
    ridges = np.tanh(2.2 * ridges).astype(np.float32)

    creases = crease_map(rng)
    outline = outline_mask(rng)
    scale = 2.0
    tri = {k: [round(x * scale, 1), round(y * scale, 1)] for k, (x, y) in triradii.items()}

    if hand == "left":
        ridges, creases, outline = (np.ascontiguousarray(a[:, ::-1]) for a in (ridges, creases, outline))
        tri = {k: [round(MASTER_W - x, 1), y] for k, (x, y) in tri.items()}

    return PalmMaster(hand=hand, ridges=ridges, creases=creases, outline=outline, triradii=tri, patterns=patterns)


def outline_mask(rng):
    points = np.array([(u * MASTER_W, v * MASTER_H) for u, v in OUTLINE])
    points += rng.normal(0, 18, points.shape)
    points = chaikin(points, 3)
    mask = np.zeros((MASTER_H, MASTER_W), np.uint8)
    cv2.fillPoly(mask, [points.astype(np.int32)], 255)
    return cv2.GaussianBlur(mask.astype(np.float32) / 255, (0, 0), 12)


def chaikin(points, rounds):
    """Chaikin corner cutting: turns a polygon into a smooth closed curve."""
    for _ in range(rounds):
        nxt = np.roll(points, -1, axis=0)
        points = np.vstack([0.75 * points + 0.25 * nxt, 0.25 * points + 0.75 * nxt]).reshape(2, -1, 2)
        points = points.transpose(1, 0, 2).reshape(-1, 2)
    return points


def bezier(p0, p1, p2, p3, n=200):
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t**2 * p2 + t**3 * p3


def crease_map(rng):
    """Flexion creases: the three principal lines plus many secondary ones."""
    canvas = np.zeros((MASTER_H, MASTER_W), np.float32)

    def jitter(u, v, s=0.02):
        return np.array([MASTER_W * (u + rng.normal(0, s)), MASTER_H * (v + rng.normal(0, s))])

    def draw(curve, width, depth):
        layer = np.zeros_like(canvas, dtype=np.uint8)
        cv2.polylines(layer, [curve.astype(np.int32)], False, 255, max(1, int(width)), cv2.LINE_AA)
        np.maximum(canvas, layer.astype(np.float32) / 255 * depth, out=canvas)

    # Distal transverse ("heart line"): ulnar edge to between index and middle.
    draw(bezier(jitter(1.02, 0.30), jitter(0.75, 0.25), jitter(0.50, 0.22), jitter(0.30, 0.16)), rng.uniform(22, 34), 1)
    # Proximal transverse ("head line"): thumb web, sloping across the palm.
    draw(bezier(jitter(-0.02, 0.34), jitter(0.25, 0.36), jitter(0.50, 0.42), jitter(0.78, 0.50)), rng.uniform(20, 32), 1)
    # Thenar crease ("life line"): around the base of the thumb.
    draw(bezier(jitter(0.0, 0.36), jitter(0.38, 0.48), jitter(0.44, 0.78), jitter(0.38, 1.0)), rng.uniform(22, 36), 1)
    # Wrist crease and the creases at the base of each finger.
    draw(bezier(jitter(0.2, 1.01), jitter(0.4, 0.985), jitter(0.6, 0.985), jitter(0.85, 1.0)), rng.uniform(16, 24), 0.9)
    for u in (0.22, 0.45, 0.66, 0.86):
        v = 0.045 if u != 0.86 else 0.11
        draw(bezier(jitter(u - 0.08, v, 0.01), jitter(u - 0.03, v - 0.01, 0.005),
                    jitter(u + 0.03, v - 0.01, 0.005), jitter(u + 0.08, v, 0.01)), rng.uniform(10, 18), 0.9)

    # Secondary creases: short fine lines, denser on the thenar and hypothenar.
    for _ in range(int(rng.integers(50, 90))):
        region = rng.choice(["thenar", "hypothenar", "centre"], p=[0.4, 0.4, 0.2])
        u, v = {"thenar": (0.2, 0.72), "hypothenar": (0.84, 0.66), "centre": (0.55, 0.35)}[region]
        start = jitter(u, v, 0.12)
        angle = rng.normal(0.3 if region == "hypothenar" else -0.2, 0.6)
        length = rng.uniform(80, 360)
        end = start + length * np.array([np.cos(angle), np.sin(angle)])
        bend = rng.normal(0, 40, 2)
        draw(bezier(start, start + (end - start) / 3 + bend, start + 2 * (end - start) / 3 + bend, end),
             rng.uniform(3, 8), rng.uniform(0.45, 0.8))

    return cv2.GaussianBlur(canvas, (0, 0), 3)


def full(seed, hand, capture=0):
    """Full palm impression (PLP 21 right / 23 left): 2750 x 4000 at 500 ppi."""
    pm = master(seed, hand)
    rng = rng_for(seed, 1 if hand == "right" else 2, FULL, capture, 13)
    w, h = FULL_SIZE
    centre_dst = (w / 2 + rng.normal(0, 30), h / 2 + rng.normal(0, 30))
    map_x, map_y = imp.warp_maps((h, w), (MASTER_W / 2, MASTER_H / 2), centre_dst,
                                 angle_deg=rng.normal(0, 2.5), scale=rng.uniform(0.93, 0.97),
                                 distortion=rng.uniform(6, 14), rng=rng)
    ridges = imp.remap(pm.ridges, map_x, map_y)
    creases = imp.remap(pm.creases, map_x, map_y)
    # Roughen the outline first: roughening acts on every partly-touching pixel,
    # so doing it after the hollow would blotch the middle of the palm.
    contact = imp.irregular_edge(imp.remap(pm.outline, map_x, map_y), rng, amount=20)

    # The hollow of the palm touches the surface lightly.
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    hollow_u = 0.55 if hand == "right" else 0.45
    hollow = np.exp(-(((xx / w - hollow_u) / 0.17) ** 2 + ((yy / h - 0.52) / 0.15) ** 2))
    contact *= 1 - hollow * rng.uniform(0.25, 0.5)
    contact *= 1 - np.clip(creases * rng.uniform(0.85, 1.0), 0, 1)

    image = imp.render(ridges, contact, rng, creases=0)
    return image, palm_meta(pm, map_x, map_y, "full", capture)


def writers(seed, hand, capture=0):
    """Writer's palm (PLP 22 right / 24 left): the little-finger edge, 875 x 2500."""
    pm = master(seed, hand)
    rng = rng_for(seed, 1 if hand == "right" else 2, WRITERS, capture, 17)
    w, h = WRITERS_SIZE
    edge_u = 0.87 if hand == "right" else 0.13
    centre_src = (MASTER_W * edge_u, MASTER_H * 0.64)
    map_x, map_y = imp.warp_maps((h, w), centre_src, (w / 2 + rng.normal(0, 20), h / 2),
                                 angle_deg=rng.normal(0, 3), scale=rng.uniform(0.97, 1.03),
                                 distortion=rng.uniform(5, 10), rng=rng)
    ridges = imp.remap(pm.ridges, map_x, map_y)
    creases = imp.remap(pm.creases, map_x, map_y)
    # The edge of the hand is rolled onto the surface: a long rounded strip.
    contact = imp.ellipse_mask((h, w), (w / 2, h / 2), (w * rng.uniform(0.40, 0.46), h * rng.uniform(0.46, 0.49)),
                               softness=14)
    contact = imp.irregular_edge(contact, rng, amount=18)
    contact *= 1 - np.clip(creases, 0, 1)
    image = imp.render(ridges, contact, rng, creases=0)
    return image, palm_meta(pm, map_x, map_y, "writers", capture)


def palm_meta(pm, map_x, map_y, kind, capture):
    names = list(pm.triradii)
    found = {}
    for name in names:
        points = imp.transform_points([pm.triradii[name]], map_x, map_y)
        if points:
            found[name] = list(points[0])
    return {"hand": pm.hand, "capture": capture, "impression": kind, "triradii": found, "patterns": pm.patterns}
