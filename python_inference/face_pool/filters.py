"""Stage 5: which faces are usable, from the measurements of stages 2-4 (docs/face-pool.md §3-5).

The thresholds were set on FairFace by looking at contact sheets of the faces in each score range.
"""
import numpy as np
import pandas as pd

from . import paths


def load(dataset_name, stages=("quality", "screen")):
    """index.parquet with the given stage outputs joined on id, and nothing else."""
    df = pd.read_parquet(paths.path(dataset_name, "index.parquet"))
    for stage in stages:
        df = df.merge(pd.read_parquet(paths.path(dataset_name, f"{stage}.parquet")), on="id", how="left")
    return df


def embeddings(dataset_name):
    return np.load(paths.path(dataset_name, "embeddings.npy")).astype(np.float32)


def stage2(df):
    """A clear, roughly frontal, sharp face whose labelled sex the estimator agrees with."""
    return ((df.det >= 0.75) & (df.eye_dist >= 60) & (df.yaw.abs() <= 0.2) & (df.roll.abs() <= 10)
            & (df.sharp >= df.sharp.quantile(0.2)) & (df.est_sex == df.sex))


def stage3(df):
    """Colour; frontal in pitch, yaw and roll; eyes open; mouth closed or nearly."""
    return ((df.grey >= 10) & df.pitch.between(-14, 6) & (df.yaw3d.abs() <= 12) & (df.roll3d.abs() <= 8)
            & (df.eye_open >= 0.22) & (df.mouth_open <= 0.12)).fillna(False).astype(bool)


def stage4(df):
    """No glasses, hat, headscarf or object in front; no broad smile or open mouth; a photograph."""
    return (((df.eyewear_glasses + df.eyewear_sunglasses) < 0.25) & (df.head_hat < 0.8)
            & ((df.head_scarf + df.head_other) < 0.5) & (df.occlusion_covered < 0.6)
            & ((df.expression_smile + df.expression_open) < 0.5)
            & ((df.photo_bw + df.photo_art) < 0.3)).fillna(False).astype(bool)


def usable(df):
    return stage2(df) & stage3(df) & stage4(df)
