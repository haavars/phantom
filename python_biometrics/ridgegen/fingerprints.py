"""Rolled and plain finger impressions, and four-finger/thumb slaps.

Output sizes follow the ANSI/NIST-ITL / FBI EBTS maximum capture areas at 500 ppi:
rolled finger 1.6 x 1.5 in (800 x 750), four-finger and two-thumb slaps
3.2 x 3.0 in (1600 x 1500).
"""

from functools import lru_cache

import cv2
import numpy as np

from . import finger as fingers
from . import impression as imp
from . import minutiae
from .synthesis import grow_ridges, rng_for, smooth_noise

ROLLED_SIZE = (800, 750)  # width, height
SLAP_SIZE = (1600, 1500)

ROLLED, PLAIN = 1, 2  # capture-kind salts

# Slap layout, as printed: a right hand's index finger is leftmost. (finger,
# centre x as a fraction of the width, fingertip top y, splay angle, scale)
RIGHT_FOUR = [(2, 0.15, 150, -8), (3, 0.38, 70, -2), (4, 0.61, 120, 3), (5, 0.84, 330, 9)]
LEFT_FOUR = [(10, 0.16, 330, -9), (9, 0.39, 120, -3), (8, 0.62, 70, 2), (7, 0.85, 150, 8)]
THUMBS = [(6, 0.28, 120, 10), (1, 0.72, 120, -10)]


def rolled(seed, finger, capture=0):
    """Rolled impression of `finger` (FGP 1-10). Returns (image, meta)."""
    master = fingers.master(seed, finger)
    rng = rng_for(seed, finger, ROLLED, capture, 7)
    w, h = ROLLED_SIZE

    scale = rng.uniform(0.86, 0.94) * min(1.0, 1.02 / master.scale)
    centre_dst = (w / 2 + rng.normal(0, 18), h * 0.54 + rng.normal(0, 14))
    map_x, map_y = imp.warp_maps(
        (h, w), (fingers.MASTER_W / 2, fingers.MASTER_H * 0.47), centre_dst,
        angle_deg=rng.normal(0, 4), scale=scale, distortion=rng.uniform(3, 7), rng=rng,
    )
    ridges = imp.remap(master.ridges, map_x, map_y)
    inside = soft_inside(master, map_x, map_y)

    # Nail-to-nail contact: a tall rounded shape, lighter towards the sides
    # where the finger was rolled on and off.
    rx = w * rng.uniform(0.40, 0.46) * min(master.scale, 1.05)
    ry = h * rng.uniform(0.50, 0.55)
    contact = imp.ellipse_mask((h, w), (centre_dst[0], centre_dst[1] + ry * 0.2), (rx, ry),
                               angle_deg=rng.normal(0, 3), bottom=h - rng.uniform(4, 30))
    xs = (np.arange(w, dtype=np.float32) - centre_dst[0]) / rx
    contact *= np.clip(1.15 - 0.45 * xs**2, 0.35, 1)[None, :]
    contact = imp.irregular_edge(contact, rng) * inside

    image = imp.render(ridges, contact, rng, creases=int(rng.integers(0, 3)))
    return image, meta(master, ridges, contact, map_x, map_y, "rolled", capture)


def plain_finger(seed, finger, capture, rng, canvas=(560, 1300)):
    """A single flat (plain) impression on its own canvas, for slap composition.

    Returns (ink, ridges, contact, map_x, map_y): the ink is 0..1 so fingers can
    be composited without their paper backgrounds covering each other.
    """
    master = fingers.master(seed, finger)
    w, h = canvas
    scale = rng.uniform(0.97, 1.03)
    centre_dst = (w / 2, 330)
    map_x, map_y = imp.warp_maps(
        (h, w), (fingers.MASTER_W / 2, fingers.MASTER_H * 0.44), centre_dst,
        angle_deg=rng.normal(0, 3), scale=scale, distortion=rng.uniform(4, 9), rng=rng,
    )
    ridges = imp.remap(master.ridges, map_x, map_y)
    inside = soft_inside(master, map_x, map_y)
    rx = w * rng.uniform(0.27, 0.31) * master.scale
    ry = rng.uniform(265, 295) * master.scale
    crease = centre_dst[1] + ry * 0.85
    contact = imp.ellipse_mask((h, w), centre_dst, (rx, ry), bottom=crease)
    contact = imp.irregular_edge(contact, rng) * inside

    # The middle phalanx below the distal crease: ridges running across the
    # finger, with a light gap for the crease itself.
    seg_h = int(min(h - crease - 10, ry * rng.uniform(0.9, 1.1)))
    if seg_h > 60:
        seg = phalanx(seed, finger)
        top = int(crease + rng.uniform(14, 24))
        seg_w = int(rx * 2 * rng.uniform(0.92, 1.0))
        x0 = int(centre_dst[0] - seg_w / 2)
        seg_h, seg_w = min(seg_h, seg.shape[0]), min(seg_w, seg.shape[1])
        # Crop at native scale so the ridge spacing matches the fingertip.
        oy = int(rng.integers(0, seg.shape[0] - seg_h + 1))
        ox = int(rng.integers(0, seg.shape[1] - seg_w + 1))
        ridges[top : top + seg_h, x0 : x0 + seg_w] = seg[oy : oy + seg_h, ox : ox + seg_w]
        seg_contact = imp.ellipse_mask((h, w), (centre_dst[0], top + seg_h / 2), (seg_w / 2, seg_h * 0.62),
                                       bottom=top + seg_h, softness=10)
        seg_contact[: top] = 0
        contact = np.maximum(contact, imp.irregular_edge(seg_contact, rng) * rng.uniform(0.7, 0.95))
    return master, ridges, contact, map_x, map_y


@lru_cache(maxsize=24)
def phalanx(seed, finger):
    """Ridge pattern for a middle phalanx: gently arched ridges across the finger."""
    rng = rng_for(seed, finger, 5)
    h, w = 420, 520
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    slope = rng.uniform(0.08, 0.2) * np.sin(np.pi * (x / w - 0.5)) + rng.normal(0, 0.05)
    theta = np.mod(np.arctan(slope) + smooth_noise((h, w), rng, 120, 0.1), np.pi)
    return grow_ridges(theta.astype(np.float32), rng.uniform(8.8, 10.0), rng, iterations=12)


def slap(seed, code, capture=0):
    """Plain slap: 13 right four fingers, 14 left four fingers, 15 two thumbs."""
    layout = {13: RIGHT_FOUR, 14: LEFT_FOUR, 15: THUMBS}[code]
    rng = rng_for(seed, code, PLAIN, capture, 11)
    w, h = SLAP_SIZE
    ridges_all = np.zeros((h, w), np.float32)
    contact_all = np.zeros((h, w), np.float32)
    tilt = rng.normal(0, 4)
    fingers_meta = []

    for finger, fx, top, splay, *_ in layout:
        finger_rng = rng_for(seed, finger, PLAIN, capture, code)
        master, ridges, contact, map_x, map_y = plain_finger(seed, finger, capture, finger_rng)
        fh, fw = ridges.shape
        angle = splay + tilt + finger_rng.normal(0, 2.5)
        cx = w * fx + finger_rng.normal(0, 20)
        cy = top + 330 + finger_rng.normal(0, 25)
        # Rotate the finger canvas about its fingertip centre and place it.
        m = cv2.getRotationMatrix2D((fw / 2, 330), -angle, 1.0)
        m[:, 2] += (cx - fw / 2, cy - 330)
        placed_ridges = cv2.warpAffine(ridges, m, (w, h), flags=cv2.INTER_LINEAR)
        placed_contact = cv2.warpAffine(contact, m, (w, h), flags=cv2.INTER_LINEAR)
        take = placed_contact > contact_all
        ridges_all = np.where(take, placed_ridges, ridges_all)
        contact_all = np.maximum(contact_all, placed_contact)

        # Singular points: master -> finger canvas -> slap.
        cores = imp.transform_points(master.cores, map_x, map_y)
        deltas = imp.transform_points(master.deltas, map_x, map_y)
        fingers_meta.append({
            "fgp": finger,
            "pattern": master.pattern,
            "cores": [apply_affine(m, p) for p in cores],
            "deltas": [apply_affine(m, p) for p in deltas],
        })

    image = imp.render(ridges_all, contact_all, rng, creases=int(rng.integers(0, 4)))
    points = minutiae.extract(ridges_all > 0, contact_all > 0.5)
    return image, {
        "capture": capture,
        "impression": "plain",
        "fingers": fingers_meta,
        "minutiae_count": len(points),
        "minutiae": points,
    }


def soft_inside(master, map_x, map_y):
    """Where the impression has master pattern, faded out towards the master's edge.

    If the contact area reaches past the master, the print fades (like light
    pressure at the fingertip) instead of ending in a straight cut.
    """
    inside = imp.remap(np.ones_like(master.ridges), map_x, map_y)
    return cv2.GaussianBlur(cv2.erode(inside, np.ones((3, 3), np.uint8), iterations=12), (0, 0), 10)


def apply_affine(m, point):
    x, y = point
    return [round(float(m[0, 0] * x + m[0, 1] * y + m[0, 2]), 1), round(float(m[1, 0] * x + m[1, 1] * y + m[1, 2]), 1)]


def meta(master, ridges, contact, map_x, map_y, kind, capture):
    points = minutiae.extract(ridges > 0, contact > 0.5)
    return {
        "fgp": master.finger,
        "capture": capture,
        "impression": kind,
        "pattern": master.pattern,
        "ridge_period_px": round(master.period, 2),
        "cores": [list(p) for p in imp.transform_points(master.cores, map_x, map_y)],
        "deltas": [list(p) for p in imp.transform_points(master.deltas, map_x, map_y)],
        "minutiae_count": len(points),
        "minutiae": points,
    }
