"""Step 3c: give each subject the identity whose cleaned face looks closest to the subject's age.

    python match_ages.py RUN SUBJECTS_JSON [--faces cleaned]

Anchors made far older or younger than their reference keep less of it. InsightFace estimates each cleaned
face's age, and the identities are reassigned to the subjects to minimise the total age gap (Hungarian). The
estimates run old (+9 on mugshots), but alike for all faces, so the ranking holds.

Writes RUN/<faces>/ages.json and RUN/<faces>/assign_age.json ({subject: identity}), for qwen_anchors.py and
measure.py --assign.
"""
import argparse
import json

import cv2
import numpy as np
from PIL import Image
from scipy.optimize import linear_sum_assignment

from common import run_dir


def estimator():
    from insightface.app import FaceAnalysis

    app = FaceAnalysis(name="buffalo_l", allowed_modules=["detection", "genderage"],
                       providers=["CPUExecutionProvider"])
    app.prepare(ctx_id=-1, det_size=(640, 640))

    def age(path):
        bgr = np.asarray(Image.open(path).convert("RGB"))[:, :, ::-1].copy()
        pad = bgr.shape[0] // 2
        bgr = cv2.copyMakeBorder(bgr, pad, pad, pad, pad, cv2.BORDER_CONSTANT, value=(128,) * 3)
        return int(max(app.get(bgr), key=lambda f: f.bbox[2] - f.bbox[0]).age)

    return age


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("run")
    p.add_argument("subjects")
    p.add_argument("--faces", default="cleaned")
    args = p.parse_args()
    wanted = [s["age"] for s in json.load(open(args.subjects))]
    age = estimator()
    looks = [age(run_dir(args.run, args.faces, f"clean_{i:02d}.png")) for i in range(1, len(wanted) + 1)]
    gap = np.abs(np.subtract.outer(wanted, looks))
    rows, cols = linear_sum_assignment(gap)
    assign = {str(r + 1): int(c + 1) for r, c in zip(rows, cols)}
    json.dump(looks, open(run_dir(args.run, args.faces, "ages.json"), "w"))
    json.dump(assign, open(run_dir(args.run, args.faces, "assign_age.json"), "w"), indent=1)
    before = np.abs(np.array(wanted) - np.array(looks))
    after = gap[rows, cols]
    print("age gap, median / max: own identity", int(np.median(before)), int(before.max()),
          "- matched", int(np.median(after)), int(after.max()))
