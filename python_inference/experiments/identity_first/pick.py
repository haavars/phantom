"""Step 3: screen every Arc2Face sample of a run like the face pool screens real faces, and pick one per identity.

    python pick.py RUN

Per sample: head pose, eye and mouth openness and greyscale from InsightFace's 3D landmarks, and the face
pool's CLIP labels (glasses, headwear, occlusion, expression, photo type), with the pool's thresholds
(docs/face-pool.md §4-5). Two more:

  * `eye_open <= 0.39`: eyes not wide open, FairFace's 95th percentile for usable faces.
  * `stare_stare`: CLIP, "a calm face" against "a startled, wide-eyed stare". The pilot's identity 6 stared, and
    Qwen copied it; its eye openness (0.37) looked normal, since what showed was the white around the iris.
    This label put both of its samples first of 24, but real faces score 0.98 at the 90th percentile, so it
    only ranks, it isn't a rule.

A "plastic skin" label ("smooth, plastic-looking, airbrushed or computer-generated") was tried and dropped:
real FairFace photos score 0.99 on it too.

Picks the sample that fails fewest rules, then stares least. Writes RUN/screen.csv (every sample) and
RUN/picks.json.
"""
import json
import os
import sys

import cv2
import numpy as np
import pandas as pd
from PIL import Image

from common import REPO, run_dir

sys.path.insert(0, os.path.join(REPO, "python_inference"))
from face_pool import filters  # noqa: E402
from face_pool.landmarks import _ratio  # noqa: E402
from face_pool.screen import GROUPS, MODEL, PRETRAINED  # noqa: E402

EXTRA = {"stare": {"calm": "a photo of a calm face", "stare": "a photo of a face with a startled, wide-eyed stare"}}
MAX_EYE_OPEN = 0.39


def clip_scorer():
    import open_clip
    import torch

    model, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained=PRETRAINED)
    tokenizer = open_clip.get_tokenizer(MODEL)
    model.eval()
    groups = {**GROUPS, **EXTRA}
    with torch.no_grad():
        text = {}
        for group, labels in groups.items():
            t = model.encode_text(tokenizer(list(labels.values())))
            text[group] = t / t.norm(dim=-1, keepdim=True)

    def score(image):
        with torch.no_grad():
            e = model.encode_image(preprocess(image)[None])
            e = e / e.norm(dim=-1, keepdim=True)
            out = {}
            for group, labels in groups.items():
                probs = (100 * e @ text[group].T).softmax(dim=-1)[0].numpy()
                out.update({f"{group}_{label}": float(pr) for label, pr in zip(labels, probs)})
            return out

    return score


def landmarker():
    from insightface.app import FaceAnalysis

    app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection", "landmark_3d_68"],
                       providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))

    def measure(image):
        rgb = np.asarray(image.convert("RGB"))
        b, g, r = [rgb[..., i].astype(np.int16) for i in (2, 1, 0)]
        rec = {"grey": float((np.abs(b - g) + np.abs(g - r)).mean())}
        bgr = cv2.copyMakeBorder(rgb[:, :, ::-1].copy(), *(rgb.shape[0] // 2,) * 2, *(rgb.shape[1] // 2,) * 2,
                                 cv2.BORDER_CONSTANT, value=(128, 128, 128))
        faces = app.get(bgr)
        if not faces:
            return rec
        f = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
        p = f.landmark_3d_68[:, :2]
        pitch, yaw, roll = [float(v) for v in f.pose]
        eye = (_ratio(p, 37, 41, 36, 39) + _ratio(p, 38, 40, 36, 39) + _ratio(p, 43, 47, 42, 45)
               + _ratio(p, 44, 46, 42, 45)) / 4
        rec.update(pitch=pitch, yaw3d=yaw, roll3d=roll, mouth_open=_ratio(p, 62, 66, 48, 54), eye_open=eye)
        return rec

    return measure


def rules(df):
    """Each rule as a boolean column: the pool's stage 3 and 4, and no staring."""
    return pd.DataFrame({
        "colour": df.grey >= 10,
        "pitch": df.pitch.between(-14, 6),
        "yaw": df.yaw3d.abs() <= 12,
        "roll": df.roll3d.abs() <= 8,
        "eyes_open": df.eye_open >= 0.22,
        "no_stare": df.eye_open <= MAX_EYE_OPEN,
        "mouth_closed": df.mouth_open <= 0.12,
        "no_glasses": (df.eyewear_glasses + df.eyewear_sunglasses) < 0.25,
        "no_hat": df.head_hat < 0.8,
        "no_scarf": (df.head_scarf + df.head_other) < 0.5,
        "clear": df.occlusion_covered < 0.6,
        "neutral": (df.expression_smile + df.expression_open) < 0.5,
        "photo": (df.photo_bw + df.photo_art) < 0.3,
    }).fillna(False)


def screen(paths):
    measure, score = landmarker(), clip_scorer()
    rows = []
    for path in paths:
        im = Image.open(path).convert("RGB")
        rows.append({"path": path, **measure(im), **score(im)})
    df = pd.DataFrame(rows)
    for col in ["pitch", "yaw3d", "roll3d", "mouth_open", "eye_open"]:
        df[col] = df.get(col, np.nan)
    return df


if __name__ == "__main__":
    run = sys.argv[1]
    names = sorted(f for f in os.listdir(run_dir(run)) if f.startswith("a2f_") and f.endswith(".png"))
    df = screen([run_dir(run, f) for f in names])
    df["identity"] = [int(f.split("_")[1]) for f in names]
    df["sample"] = [int(f.split("_")[2].split(".")[0]) for f in names]
    checks = rules(df)
    df["fails"] = (~checks).sum(axis=1)
    df["failed"] = checks.apply(lambda r: ",".join(c for c, ok in r.items() if not ok), axis=1)
    df.to_csv(run_dir(run, "screen.csv"), index=False)
    picks = {}
    for identity, group in df.groupby("identity"):
        best = group.sort_values(["fails", "stare_stare"]).iloc[0]
        picks[int(identity)] = {"sample": int(best["sample"]), "fails": int(best.fails), "failed": best.failed,
                                "stare": round(float(best.stare_stare), 3),
                                "passing": int((group.fails == 0).sum()), "of": len(group)}
        print(identity, picks[int(identity)])
    json.dump(picks, open(run_dir(run, "picks.json"), "w"), indent=1)
