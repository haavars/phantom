"""Step 3b: clean each picked Arc2Face face with a Qwen edit before it becomes the anchor's reference.

    python clean_references.py RUN N [--out cleaned] [--ages SUBJECTS_JSON]

Only what the face pool's rules reject changes: head turned or tilted, grin or open mouth, glasses or
sunglasses, hat or cap, colour cast. The same man, age, hair and skin, as a frontal, neutral close-up on
mid-grey. Then qwen_anchors.py RUN SUBJECTS --faces cleaned renders the anchors from these.

--ages SUBJECTS_JSON also makes identity i subject i's age in the same edit, so the anchor needn't change it.

Measures what the edit keeps (buffalo_l, cleaned against the Arc2Face face) and screens the cleaned faces with
the pool's rules. Writes RUN/<out>/clean_XX.png, screen.csv and result.json.
"""
import argparse
import json
import os
import time

import httpx
import numpy as np
from PIL import Image

from common import QWEN, embed, png_bytes, run_dir
from pick import rules, screen

PROMPT = ("Passport-style photograph of the man in the reference image, the same individual: keep his face "
          "shape, bone structure, eyes, nose, mouth, jaw, ears, age, skin tone and hair colour exactly the same. "
          "Changes only: he faces the camera squarely with the head level, both eyes open and looking straight "
          "into the lens; a neutral, relaxed expression with the mouth closed; no glasses or sunglasses; no hat, "
          "cap or head covering, his own hair visible. Head and upper shoulders centred. Plain, uniform mid-grey "
          "background. Even, diffuse, colour-neutral front lighting with no harsh shadows. Photorealistic, "
          "unretouched digital photograph with natural skin texture and sharp focus.")


def aged(age):
    return (PROMPT.replace("jaw, ears, age, skin tone", "jaw, ears, skin tone")
            .replace("Changes only: he", f"Changes only: he is now {age} years old and looks it; he"))


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("run")
    p.add_argument("n", type=int)
    p.add_argument("--out", default="cleaned")
    p.add_argument("--ages", default=None)
    args = p.parse_args()
    ages = [s["age"] for s in json.load(open(args.ages))] if args.ages else None
    picks = json.load(open(run_dir(args.run, "picks.json")))
    client = httpx.Client(timeout=600)
    faces, cleaned = [], []
    for i in range(1, args.n + 1):
        face = run_dir(args.run, f"a2f_{i:02d}_{picks[str(i)]['sample']}.png")
        path = run_dir(args.run, args.out, f"clean_{i:02d}.png")
        faces.append(face)
        cleaned.append(path)
        if os.path.exists(path):
            continue
        t = time.time()
        prompt = aged(ages[i - 1]) if ages else PROMPT
        r = client.post(f"{QWEN}/generate", data={"prompt": prompt, "width": 1024, "height": 1024, "steps": 40,
                                                  "seed": 2000 + i},
                        files=[("images", ("reference.png", png_bytes(Image.open(face).convert("RGB")),
                                           "image/png"))])
        r.raise_for_status()
        open(path, "wb").write(r.content)
        print("clean", i, f"{time.time() - t:.0f}s", flush=True)

    kept = np.array([float(embed(client, f) @ embed(client, c)) for f, c in zip(faces, cleaned)])
    s = screen(cleaned)
    s.to_csv(run_dir(args.run, args.out, "screen.csv"))
    failed = rules(s).apply(lambda r: ",".join(c for c, ok in r.items() if not ok), axis=1)
    before = {i: picks[str(i)]["failed"] for i in range(1, args.n + 1) if picks[str(i)]["failed"]}
    result = {
        "identity_kept": {"median": round(float(np.median(kept)), 2), "min": round(float(kept.min()), 2),
                          "max": round(float(kept.max()), 2), "by_identity": [round(float(k), 2) for k in kept]},
        "pass_rules": int((failed == "").sum()),
        "failed": {i + 1: f for i, f in enumerate(failed) if f},
        "failed_before": before,
    }
    json.dump(result, open(run_dir(args.run, args.out, "result.json"), "w"), indent=1)
    print(json.dumps(result, indent=1))
