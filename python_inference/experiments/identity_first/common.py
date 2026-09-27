"""Shared paths and helpers for the identity-first experiment (README.md).

Everything the scripts write goes under data/experiments/identity_first/ (outside git): the Arc2Face checkout,
its venv and models, and one folder per run.
"""
import base64
import io
import json
import os

import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(REPO, "data", "experiments", "identity_first")
ARC2FACE = os.path.join(WORK, "Arc2Face")
FAIRFACE = os.path.join(REPO, "data", "face_pool", "fairface")
TEXT_ONLY_RUN = os.path.join(REPO, "data", "synthetic", "biometrics", "gate-nordic-men")
QWEN = "http://127.0.0.1:8000"
BIOMETRICS = "http://127.0.0.1:8001"


def run_dir(run, *parts):
    path = os.path.join(WORK, run, *parts)
    os.makedirs(os.path.dirname(path) if parts else path, exist_ok=True)
    return path


def subjects():
    """Subjects 1-12 of the face-gate run (12 Northern European men): age, hair, clothing and so on."""
    return json.load(open(os.path.join(HERE, "subjects.json")))


def text_only_anchor(i):
    """The text-only anchor of subject i (1-based), as the face-gate run first rendered it (before the gate)."""
    name = f"subject_{i:03d}"
    stored = os.path.join(TEXT_ONLY_RUN, name, "mugshot_frontal.png")
    redone = os.path.join(WORK, "text_only", f"{name}.png")
    return redone if os.path.exists(redone) else stored


def png_bytes(image):
    buf = io.BytesIO()
    image.save(buf, format="PNG")
    return buf.getvalue()


def embed(client, path_or_image):
    """buffalo_l template from the biometrics service (POST /face/embed), or None.

    The image is padded onto a canvas twice its size first: Arc2Face's faces fill the frame, and the detector
    misses faces that large. Padding changes nothing for smaller faces.
    """
    im = path_or_image if isinstance(path_or_image, Image.Image) else Image.open(path_or_image)
    im = im.convert("RGB")
    canvas = Image.new("RGB", (im.width * 2, im.height * 2), (128, 128, 128))
    canvas.paste(im, (im.width // 2, im.height // 2))
    body = {"image": base64.b64encode(png_bytes(canvas)).decode()}
    r = client.post(f"{BIOMETRICS}/face/embed", json=body, timeout=120).json()
    return np.frombuffer(base64.b64decode(r["template"]), "<f4") if r["faces"] else None


def pair_stats(templates):
    X = np.stack(templates)
    v = (X @ X.T)[np.triu_indices(len(X), 1)]
    return {"median": round(float(np.median(v)), 3), "p90": round(float(np.percentile(v, 90)), 3),
            "max": round(float(v.max()), 3), ">=0.3": int((v >= 0.3).sum()), "pairs": len(v)}


def fairface_templates():
    return np.load(os.path.join(FAIRFACE, "embeddings.npy")).astype(np.float32)


def sheet(rows, path, cell=(200, 267), labels=None):
    """A contact sheet: `rows` is a list of (row label, [image path, ...]); each image is fitted into a cell."""
    w, h = cell
    cols = max(len(images) for _, images in rows)
    out = Image.new("RGB", (w * cols + 120, (h + 16) * len(rows)), "white")
    d = ImageDraw.Draw(out)
    for r, (label, images) in enumerate(rows):
        y = r * (h + 16)
        d.text((4, y + h // 2), label, fill="black")
        for c, p in enumerate(images):
            im = Image.open(p).convert("RGB")
            im.thumbnail((w, h))
            out.paste(im, (120 + c * w + (w - im.width) // 2, y + 16 + (h - im.height) // 2))
            if labels and r == 0:
                d.text((120 + c * w + 4, y + 2), labels[c], fill="black")
    out.save(path, quality=85)
