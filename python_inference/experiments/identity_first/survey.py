"""Step 3b: how usable a run's Arc2Face identities are: screen and pick (pick.py), then the spread and leakage of
the picked faces (buffalo_l) and a contact sheet of every sample.

    python survey.py RUN [RUN ...]
"""
import json
import subprocess
import sys

import httpx
import numpy as np
import pandas as pd

from common import embed, fairface_templates, pair_stats, run_dir, sheet

client = httpx.Client()
pool = fairface_templates()
for run in sys.argv[1:]:
    subprocess.run([sys.executable, "pick.py", run], check=True, capture_output=True)
    df = pd.read_csv(run_dir(run, "screen.csv"))
    picks = json.load(open(run_dir(run, "picks.json")))
    T = [embed(client, run_dir(run, f"a2f_{int(i):02d}_{p['sample']}.png")) for i, p in sorted(picks.items(), key=lambda kv: int(kv[0]))]
    found = [t for t in T if t is not None]
    per_identity = df.groupby("identity").fails.min()
    print(f"{run}: samples passing every rule {(df.fails == 0).mean() * 100:.0f}%, identities with a passing sample "
          f"{(per_identity == 0).sum()}/{len(per_identity)}, faces found {len(found)}/{len(T)}")
    print("   between picked faces:", pair_stats(found),
          "| nearest FairFace median/max:", np.round(np.percentile((pool @ np.stack(found).T).max(0), [50, 100]), 2))
    print("   most failed rules:", df.failed.dropna().str.split(",").explode().value_counts().head(5).to_dict())
    rows = [(f"id {i:02d}", [run_dir(run, f"a2f_{i:02d}_{j}.png") for j in sorted(g["sample"])])
            for i, g in df.groupby("identity")]
    sheet(rows, run_dir(run, "samples.jpg"), cell=(128, 128))
