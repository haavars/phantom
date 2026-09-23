"""Ground-truth minutiae from a clean (noise-free) ridge image.

Extracted per impression from the warped, binarised ridge pattern before
rendering noise is added, so positions are in that impression's pixel
coordinates. Angles follow the ISO/IEC 19794-2 convention loosely: degrees,
counter-clockwise from the x axis, pointing along the ridge away from an ending
or into the fork of a bifurcation.
"""

import cv2
import numpy as np
from skimage.morphology import skeletonize

NEIGHBOURS = [(-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1), (0, -1)]


def extract(ridge_binary, valid, border=18, min_distance=8, trace=10):
    """Return minutiae as dicts {x, y, angle, type} ('ending' / 'bifurcation')."""
    skeleton = skeletonize(ridge_binary.astype(bool)).astype(np.uint8)
    # Stay away from the contact edge, where the skeleton ends artificially.
    inner = cv2.erode(valid.astype(np.uint8), np.ones((3, 3), np.uint8), iterations=border)

    padded = np.pad(skeleton, 1)
    # Crossing number: half the number of 0/1 transitions around the pixel.
    ring = [padded[1 + dy : padded.shape[0] - 1 + dy, 1 + dx : padded.shape[1] - 1 + dx] for dy, dx in NEIGHBOURS]
    transitions = sum(np.abs(ring[i].astype(int) - ring[(i + 1) % 8].astype(int)) for i in range(8)) // 2

    candidates = []
    for kind, cn in (("ending", 1), ("bifurcation", 3)):
        ys, xs = np.nonzero((skeleton == 1) & (transitions == cn) & (inner > 0))
        candidates += [(int(x), int(y), kind) for x, y in zip(xs, ys)]

    # Drop clusters (short spurs, tiny gaps) that are artefacts, not minutiae.
    kept = []
    for x, y, kind in candidates:
        close = [k for k in kept if (k[0] - x) ** 2 + (k[1] - y) ** 2 < min_distance**2]
        if close:
            for k in close:
                kept.remove(k)
            continue
        kept.append((x, y, kind))

    minutiae = []
    for x, y, kind in kept:
        angle = direction(skeleton, x, y, kind, trace)
        if angle is not None:
            minutiae.append({"x": x, "y": y, "angle": angle, "type": kind})
    return minutiae


def direction(skeleton, x, y, kind, steps):
    branches = [walk(skeleton, x, y, nx, ny, steps) for nx, ny in neighbours_on(skeleton, x, y)]
    branches = [b for b in branches if b is not None]
    if kind == "ending" and len(branches) == 1:
        bx, by = branches[0]
        # Points away from the ridge it terminates.
        return round(float(np.degrees(np.arctan2(-(y - by), x - bx))) % 360, 1)
    if kind == "bifurcation" and len(branches) == 3:
        angles = [np.arctan2(-(by - y), bx - x) for bx, by in branches]
        # The stem is the branch pointing most away from the other two.
        def spread(i):
            return sum(abs(np.angle(np.exp(1j * (angles[i] - angles[j])))) for j in range(3) if j != i)
        stem = max(range(3), key=spread)
        return round(float(np.degrees(angles[stem] + np.pi)) % 360, 1)
    return None


def neighbours_on(skeleton, x, y):
    h, w = skeleton.shape
    return [(x + dx, y + dy) for dy, dx in NEIGHBOURS
            if 0 <= y + dy < h and 0 <= x + dx < w and skeleton[y + dy, x + dx]]


def walk(skeleton, x, y, nx, ny, steps):
    """Follow the skeleton from (x, y) through (nx, ny) for up to `steps` pixels."""
    visited = {(x, y), (nx, ny)}
    cx, cy = nx, ny
    for _ in range(steps):
        nxt = [p for p in neighbours_on(skeleton, cx, cy) if p not in visited]
        if len(nxt) != 1:
            break
        cx, cy = nxt[0]
        visited.add((cx, cy))
    return (cx, cy) if len(visited) > 3 else None
