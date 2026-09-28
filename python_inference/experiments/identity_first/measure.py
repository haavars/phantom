"""Step 5: measure a run's anchors.

    python measure.py RUN SUBJECTS_JSON [--anchors anchors_mugshot] [--assign FILE]

  * spread: buffalo_l similarity between different people's anchors
  * identity kept: each anchor against its own Arc2Face face (the one --assign gave it), its closest other
    identity, and the reference it was sent
  * leakage: each anchor's nearest face among FairFace's 73k
  * the face pool's rules and the stare score (pick.py), on the anchors
  * age: InsightFace's estimate against the subject's age

Writes RUN/<anchors>/result.json and sheet.jpg (Arc2Face face, reference sent, anchor, per identity).
"""
import argparse
import json

import httpx
import numpy as np
from PIL import Image

from common import embed, fairface_templates, pair_stats, run_dir, sheet
from pick import rules, screen

p = argparse.ArgumentParser()
p.add_argument("run")
p.add_argument("subjects")
p.add_argument("--anchors", default="anchors_mugshot")
p.add_argument("--assign", default=None)
args = p.parse_args()
assign = json.load(open(args.assign)) if args.assign else {}

subjects = json.load(open(args.subjects))
picks = json.load(open(run_dir(args.run, "picks.json")))
n = len(subjects)
client = httpx.Client()
ids = [assign.get(str(i), i) for i in range(1, n + 1)]
faces = [run_dir(args.run, f"a2f_{k:02d}_{picks[str(k)]['sample']}.png") for k in ids]
anchors = [run_dir(args.run, args.anchors, f"anchor_{i:02d}.png") for i in range(1, n + 1)]
A = np.stack([embed(client, a) for a in anchors])
F = np.stack([embed(client, f) for f in faces])
own = (A * F).sum(1)
refs = [run_dir(args.run, args.anchors, f"reference_{i:02d}.png") for i in range(1, n + 1)]
from_ref = (A * np.stack([embed(client, r) for r in refs])).sum(1)
others = np.array([np.delete(F @ a, i).max() for i, a in enumerate(A)])
nearest = (fairface_templates() @ A.T).max(0)

s = screen(anchors)
failed = rules(s).apply(lambda r: ",".join(c for c, ok in r.items() if not ok), axis=1)

from insightface.app import FaceAnalysis  # noqa: E402

ages = FaceAnalysis(name="buffalo_l", allowed_modules=["detection", "genderage"], providers=["CPUExecutionProvider"])
ages.prepare(ctx_id=-1, det_size=(640, 640))
est = [int(max(ages.get(np.asarray(Image.open(a).convert("RGB"))[:, :, ::-1]),
               key=lambda f: f.bbox[2] - f.bbox[0]).age) for a in anchors]
age_err = np.array(est) - np.array([x["age"] for x in subjects])

result = {
    "between_anchors": pair_stats(list(A)),
    "own_identity": {"median": round(float(np.median(own)), 2), "min": round(float(own.min()), 2),
                     "max": round(float(own.max()), 2)},
    "closest_other_identity_max": round(float(others.max()), 2),
    "from_reference": {"median": round(float(np.median(from_ref)), 2), "min": round(float(from_ref.min()), 2)},
    "own_by_subject": [round(float(v), 2) for v in own],
    "nearest_fairface": {"median": round(float(np.median(nearest)), 2), "max": round(float(nearest.max()), 2)},
    "pass_rules": int((failed == "").sum()),
    "failed": {i + 1: f for i, f in enumerate(failed) if f},
    "stare_max": round(float(s.stare_stare.max()), 2),
    "age_error": {"median": int(np.median(age_err)), "mean_abs": round(float(np.abs(age_err).mean()), 1),
                  "by_subject": [[x["age"], e] for x, e in zip(subjects, est)]},
}
json.dump(result, open(run_dir(args.run, args.anchors, "result.json"), "w"), indent=1)
print(json.dumps(result, indent=1))

rows = []
for start in range(0, n, 6):
    chunk = range(start, min(start + 6, n))
    rows.append((f"{start + 1}-{chunk[-1] + 1}", [x for i in chunk for x in (faces[i], anchors[i])]))
sheet(rows, run_dir(args.run, args.anchors, "sheet.jpg"), cell=(180, 240))
