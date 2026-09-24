"""Impressions: what a single capture of a master pattern looks like.

Every capture (rolled or plain, first or later) of the same finger or palm
starts from the same master, then gets its own placement, skin distortion,
contact area, pressure, and sensor noise. That is what makes two captures of one
finger a realistic mated pair rather than identical copies.
"""

from dataclasses import dataclass, field

import cv2
import numpy as np

from .synthesis import rng_for, smooth_noise

PAPER = 250  # background grey level
RIDGE_DARK = (25, 70)  # darkest ridge grey, sampled per capture


@dataclass
class Capture:
    """One impression before rendering: its geometry and ground truth.

    This is the identity half of an image. Any renderer (procedural or
    diffusion) turns it into pixels, and verification checks the pixels against
    it, so the ground truth holds whatever the renderer does.
    """

    ridges: np.ndarray  # warped clean ridge field, > 0 on ridges
    contact: np.ndarray  # 0..1 contact area
    meta: dict  # ground truth: pattern, singular points, minutiae
    rng: np.random.Generator  # appearance randomness for the first attempt
    appearance_key: tuple  # derives appearance randomness for later attempts
    creases: int = 0
    # Slaps: (fgp, placed contact mask) per finger, for per-finger checks.
    fingers: list = field(default_factory=list)

    def appearance_rng(self, attempt):
        """Randomness for rendering attempt `attempt` (0, 1, ...).

        Attempt 0 continues the capture's own generator, so first attempts are
        what the procedural renderer has always produced.
        """
        return self.rng if attempt == 0 else rng_for(*self.appearance_key, 101, attempt)

    def ridge_map(self):
        """The clean binarised ridge map: black ridges on white, only in the contact area."""
        return np.where((self.ridges > 0) & (self.contact > 0.5), 0, 255).astype(np.uint8)


def warp_maps(out_shape, centre_src, centre_dst, angle_deg, scale, distortion, rng, stretch=(1.0, 1.0)):
    """cv2.remap maps sending each output pixel to master coordinates.

    Rigid placement (rotation about the finger centre, translation) plus a
    smooth random displacement field for skin elasticity.
    """
    h, w = out_shape
    v, u = np.mgrid[0:h, 0:w].astype(np.float32)
    a = np.deg2rad(angle_deg)
    du, dv = (u - centre_dst[0]) / (scale * stretch[0]), (v - centre_dst[1]) / (scale * stretch[1])
    x = centre_src[0] + du * np.cos(a) - dv * np.sin(a)
    y = centre_src[1] + du * np.sin(a) + dv * np.cos(a)
    if distortion > 0:
        x += smooth_noise(out_shape, rng, scale=160, amplitude=distortion)
        y += smooth_noise(out_shape, rng, scale=160, amplitude=distortion)
    return x.astype(np.float32), y.astype(np.float32)


def remap(array, map_x, map_y, border=0.0):
    return cv2.remap(
        array, map_x, map_y, interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT, borderValue=border,
    )


def irregular_edge(mask, rng, amount=12):
    """Roughen a soft mask's outline so contact areas don't look machine-cut."""
    wobble = smooth_noise(mask.shape, rng, scale=40, amplitude=amount / 60)
    return np.clip(mask + wobble * (mask > 0.02) * (mask < 0.98), 0, 1)


def ellipse_mask(shape, centre, axes, angle_deg=0.0, softness=9, bottom=None):
    """Soft elliptical contact area, optionally cut flat at y = `bottom`."""
    mask = np.zeros(shape, np.uint8)
    cv2.ellipse(mask, (int(centre[0]), int(centre[1])), (int(axes[0]), int(axes[1])),
                angle_deg, 0, 360, 255, -1)
    if bottom is not None:
        mask[int(bottom):, :] = 0
    return cv2.GaussianBlur(mask.astype(np.float32) / 255, (0, 0), softness)


def render_capture(capture, attempt=0):
    """The procedural renderer: a capture's grey image for rendering `attempt`."""
    rng = capture.appearance_rng(attempt)
    creases = capture.creases if attempt == 0 else int(rng.integers(0, 3))
    return render(capture.ridges, capture.contact, rng, creases=creases)


def render(ridges, contact, rng, pressure=None, noise=None, creases=0, pores=True):
    """Turn a warped ridge field (+ridge / -valley) and contact mask into grey pixels.

    `pressure` in [-1, 1]: negative is dry (thin, broken ridges), positive is
    wet or heavy (thick ridges that merge).
    """
    shape = ridges.shape
    pressure = rng.uniform(-0.6, 0.6) if pressure is None else pressure
    noise = rng.uniform(4, 10) if noise is None else noise

    # Ink/contact varies over the area: lighter towards the edges of the contact
    # and in random patches.
    # Patch size scales with the impression so palms get broad, smooth patches.
    patches = smooth_noise(shape, rng, scale=max(70, min(shape) / 10), amplitude=0.12)
    threshold = -0.35 * pressure - patches * 0.6
    # Dry prints lose bits of ridge.
    if pressure < -0.3:
        breaks = smooth_noise(shape, rng, scale=6, amplitude=1.0)
        threshold = threshold + np.where(breaks > 1.5 + pressure, 0.6, 0)

    ink = 1 / (1 + np.exp(-(ridges - threshold) * 7))
    ink *= np.clip(contact * (0.85 + patches), 0, 1)

    if pores:
        # Sweat pores: tiny light dots sitting on ridges.
        count = int(shape[0] * shape[1] / 900)
        ys = rng.integers(0, shape[0], count)
        xs = rng.integers(0, shape[1], count)
        on_ridge = ridges[ys, xs] > 0.6
        pore = np.zeros(shape, np.float32)
        pore[ys[on_ridge], xs[on_ridge]] = 1
        pore = cv2.GaussianBlur(pore, (0, 0), 0.9) * 5
        ink *= 1 - np.clip(pore, 0, 0.8)

    for _ in range(creases):
        ink *= 1 - crease_line(shape, rng)

    dark = rng.uniform(*RIDGE_DARK)
    grey = PAPER - (PAPER - dark) * ink
    grey = cv2.GaussianBlur(grey.astype(np.float32), (0, 0), rng.uniform(0.5, 0.9))
    grey += rng.normal(0, noise, shape).astype(np.float32)
    return np.clip(grey, 0, 255).astype(np.uint8)


def crease_line(shape, rng, width=None, length=None):
    """A soft light line (skin crease or scar) as a 0..1 mask."""
    h, w = shape
    width = width if width is not None else rng.uniform(2, 5)
    length = length if length is not None else rng.uniform(0.2, 0.6) * min(h, w)
    x0, y0 = rng.uniform(0, w), rng.uniform(0, h)
    angle = rng.uniform(0, np.pi)
    x1, y1 = x0 + np.cos(angle) * length, y0 + np.sin(angle) * length
    line = np.zeros(shape, np.uint8)
    cv2.line(line, (int(x0), int(y0)), (int(x1), int(y1)), 255, max(1, int(width)))
    return cv2.GaussianBlur(line.astype(np.float32) / 255, (0, 0), width / 2) * rng.uniform(0.6, 1.0)


def transform_points(points, map_x, map_y):
    """Output-image positions of master points, via the nearest warp sample.

    Returns only the points that land inside the image.
    """
    found = []
    for px, py in points:
        d = (map_x - px) ** 2 + (map_y - py) ** 2
        idx = int(np.argmin(d))
        if d.flat[idx] < 25:
            y, x = divmod(idx, map_x.shape[1])
            found.append((int(x), int(y)))
    return found
