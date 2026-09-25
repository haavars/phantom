"""Stage 4: CLIP zero-shot screen for glasses, headwear, occlusion, expression and photo type, for faces that
pass stage 3 (docs/face-pool.md §5). Each group is a softmax over its own labels.

Writes screen.parquet.
"""
import os
import time

import pandas as pd

from . import filters, paths

MODEL, PRETRAINED = "ViT-B-16", "laion2b_s34b_b88k"

GROUPS = {
    "eyewear": {"none": "a close-up photo of a face with no glasses",
                "glasses": "a close-up photo of a face wearing eyeglasses",
                "sunglasses": "a close-up photo of a face wearing sunglasses"},
    "head": {"bare": "a close-up photo of a face with a bare head and visible hair",
             "hat": "a close-up photo of a face wearing a hat or cap",
             "scarf": "a close-up photo of a face wearing a headscarf or hijab",
             "other": "a close-up photo of a face wearing a helmet, hood or headband"},
    "occlusion": {"clear": "a close-up photo of a face with nothing in front of it",
                  "covered": "a close-up photo of a face partly covered by a hand, a drink, a microphone or an object"},
    "expression": {"neutral": "a close-up photo of a face with a neutral expression and a closed mouth",
                   "smile": "a close-up photo of a face smiling broadly and showing teeth",
                   "open": "a close-up photo of a face with an open mouth, talking or shouting"},
    "photo": {"real": "a colour photograph of a real person's face",
              "bw": "a black and white photograph of a face",
              "art": "a painting, drawing, cartoon or statue of a face",
              "filtered": "a heavily filtered or edited selfie"},
}


def run(dataset, batch=64):
    import open_clip
    import torch
    from PIL import Image

    df = filters.load(dataset.name, stages=("quality",))
    ids = df[filters.stage2(df) & filters.stage3(df)].id.tolist()
    print(f"{len(ids)} faces pass stage 3", flush=True)
    torch.set_num_threads(os.cpu_count())
    model, _, preprocess = open_clip.create_model_and_transforms(MODEL, pretrained=PRETRAINED)
    tokenizer = open_clip.get_tokenizer(MODEL)
    model.eval()
    rows, start = [], time.time()
    with torch.no_grad():
        text = {}
        for group, labels in GROUPS.items():
            t = model.encode_text(tokenizer(list(labels.values())))
            text[group] = t / t.norm(dim=-1, keepdim=True)
        for b in range(0, len(ids), batch):
            chunk = ids[b:b + batch]
            images = [Image.open(os.path.join(paths.out_dir(dataset.name), "images", f"{i}.jpg")).convert("RGB")
                      for i in chunk]
            emb = model.encode_image(torch.stack([preprocess(im) for im in images]))
            emb = emb / emb.norm(dim=-1, keepdim=True)
            probs = {g: (100 * emb @ t.T).softmax(dim=-1).numpy() for g, t in text.items()}
            for n, id_ in enumerate(chunk):
                rec = {"id": id_}
                for group, labels in GROUPS.items():
                    for k, label in enumerate(labels):
                        rec[f"{group}_{label}"] = float(probs[group][n, k])
                rows.append(rec)
            if b % (batch * 32) == 0:
                print(f"{len(rows)}/{len(ids)} {len(rows) / (time.time() - start):.1f}/s", flush=True)
    pd.DataFrame(rows).to_parquet(paths.path(dataset.name, "screen.parquet"))
