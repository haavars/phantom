"""Step 1: FairFace's frontal adult White men, embedded with Arc2Face's own ArcFace (WebFace42M), for sampling
identities. Writes pool_a2f.npy and pool_ids.txt. About 3 minutes on the CPU."""
import os
import sys

import cv2
import numpy as np

from common import ARC2FACE, FAIRFACE, REPO, WORK

sys.path.insert(0, os.path.join(REPO, "python_inference"))
from face_pool import filters  # noqa: E402
from insightface.app import FaceAnalysis  # noqa: E402
from insightface.model_zoo import get_model  # noqa: E402
from insightface.utils import face_align  # noqa: E402

df = filters.load("fairface", stages=())
df = df[filters.stage2(df) & (df.race == "White") & (df.sex == "male")]
det = FaceAnalysis(name="buffalo_l", allowed_modules=["detection"], providers=["CPUExecutionProvider"])
det.prepare(ctx_id=-1, det_size=(256, 256))
rec = get_model(os.path.join(ARC2FACE, "models", "antelopev2", "arcface.onnx"), providers=["CPUExecutionProvider"])
rec.prepare(ctx_id=-1)
embs, ids = [], []
for face_id in df.id:
    img = cv2.imread(os.path.join(FAIRFACE, "images", f"{face_id}.jpg"))
    faces = det.get(img)
    if not faces:
        continue
    f = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
    e = rec.get_feat(face_align.norm_crop(img, f.kps)).ravel()
    embs.append(e / np.linalg.norm(e))
    ids.append(face_id)
np.save(os.path.join(WORK, "pool_a2f.npy"), np.stack(embs).astype(np.float32))
open(os.path.join(WORK, "pool_ids.txt"), "w").write("\n".join(ids))
print(len(ids), "faces")
