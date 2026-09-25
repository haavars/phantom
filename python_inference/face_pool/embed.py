"""Stages 1 and 2: ingest, detect, measure and embed (docs/face-pool.md §2-3).

Writes images/<id>.jpg (the dataset's bytes, not re-encoded), index_all.parquet (every image),
index.parquet (embedded faces, `row` = position in embeddings.npy) and embeddings.npy (float16, N x 512).
"""
import itertools
import math
import os
from functools import partial
from multiprocessing import Pool

import cv2
import numpy as np
import pandas as pd

from . import datasets, insight, paths


def measure(item, det_size):
    id_, data, labels = item
    rec = {"id": id_, **labels, "faces": 0}
    if labels["age_band"] not in datasets.ADULT_BANDS:
        return rec, None, None  # Phantom's subjects are adults
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    faces = insight.app(["detection", "recognition", "genderage"], det_size).get(img)
    rec["faces"] = len(faces)
    f = insight.largest(faces)
    if f is None:
        return rec, None, None
    left_eye, right_eye, nose, _, _ = f.kps
    eye_dist = float(np.linalg.norm(right_eye - left_eye))
    mid = (left_eye + right_eye) / 2
    x0, y0, x1, y1 = [int(v) for v in f.bbox]
    grey = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)[max(y0, 0):max(y1, 1), max(x0, 0):max(x1, 1)]
    rec.update(
        det=float(f.det_score),
        eye_dist=eye_dist,
        # Nose offset from the eye midpoint over eye distance: 0 is frontal. Stage 3 measures pose properly.
        yaw=float((nose[0] - mid[0]) / max(eye_dist, 1e-3)),
        roll=float(math.degrees(math.atan2(right_eye[1] - left_eye[1], right_eye[0] - left_eye[0]))),
        sharp=float(cv2.Laplacian(grey, cv2.CV_64F).var()) if grey.size else 0.0,
        est_age=int(f.age),
        est_sex="female" if f.gender == 0 else "male",
        w=img.shape[1],
        h=img.shape[0],
    )
    return rec, f.normed_embedding.astype(np.float16), data


def run(dataset, workers=8, limit=None):
    out = paths.out_dir(dataset.name)
    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    items = datasets.items(dataset)
    if limit:
        items = itertools.islice(items, limit)
    recs, embs = [], []
    insight.ensure_models()
    with Pool(workers) as pool:
        for n, (rec, emb, data) in enumerate(pool.imap(partial(measure, det_size=dataset.det_size), items, chunksize=32)):
            if emb is not None:
                with open(os.path.join(out, "images", f"{rec['id']}.jpg"), "wb") as f:
                    f.write(data)
                rec["row"] = len(embs)
                embs.append(emb)
            recs.append(rec)
            if n % 5000 == 0:
                print(f"{n} images, {len(embs)} embedded", flush=True)
    all_ = pd.DataFrame(recs)
    all_.to_parquet(paths.path(dataset.name, "index_all.parquet"))
    kept = all_[all_["row"].notna()].copy()
    kept["row"] = kept["row"].astype(int)
    kept.sort_values("row").to_parquet(paths.path(dataset.name, "index.parquet"))
    np.save(paths.path(dataset.name, "embeddings.npy"), np.stack(embs))
    print(f"{len(all_)} images, {len(kept)} embedded", flush=True)
