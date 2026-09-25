"""Stage 3: head pose, mouth and eye openness, greyscale, for faces that pass stage 2 (docs/face-pool.md §4).

Writes quality.parquet.
"""
import os
from functools import partial
from multiprocessing import Pool

import cv2
import numpy as np
import pandas as pd

from . import filters, insight, paths


def _ratio(p, a, b, c, d):
    return float(np.linalg.norm(p[a] - p[b]) / max(np.linalg.norm(p[c] - p[d]), 1e-3))


def measure(id_, dataset_name, det_size):
    img = cv2.imread(os.path.join(paths.out_dir(dataset_name), "images", f"{id_}.jpg"))
    b, g, r = [img[..., i].astype(np.int16) for i in range(3)]
    rec = {"id": id_, "grey": float((np.abs(b - g) + np.abs(g - r)).mean())}
    f = insight.largest(insight.app(["detection", "landmark_3d_68"], det_size).get(img))
    if f is None:
        return rec
    p = f.landmark_3d_68[:, :2]
    pitch, yaw, roll = [float(v) for v in f.pose]
    # iBUG 68 points: inner lips 62/66 over mouth corners 48/54; eye height over width, both eyes.
    eye = (_ratio(p, 37, 41, 36, 39) + _ratio(p, 38, 40, 36, 39) + _ratio(p, 43, 47, 42, 45) + _ratio(p, 44, 46, 42, 45)) / 4
    rec.update(pitch=pitch, yaw3d=yaw, roll3d=roll, mouth_open=_ratio(p, 62, 66, 48, 54), eye_open=eye)
    return rec


def run(dataset, workers=8):
    df = filters.load(dataset.name, stages=())
    ids = df[filters.stage2(df)].id.tolist()
    print(f"{len(ids)} faces pass stage 2", flush=True)
    recs = []
    insight.ensure_models()
    with Pool(workers) as pool:
        fn = partial(measure, dataset_name=dataset.name, det_size=dataset.det_size)
        for n, rec in enumerate(pool.imap(fn, ids, chunksize=64)):
            recs.append(rec)
            if n % 2000 == 0:
                print(f"{n}/{len(ids)}", flush=True)
    pd.DataFrame(recs).to_parquet(paths.path(dataset.name, "quality.parquet"))
