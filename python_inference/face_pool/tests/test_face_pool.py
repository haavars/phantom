import pandas as pd
import pytest

from face_pool import datasets, filters


class TwoFiles:
    """A dataset whose files each number their rows from 0, like FairFace's parquet files."""

    prefix = "tt"

    def items(self):
        for _file in range(2):
            for _row in range(3):
                yield b"", {"sex": "male", "age_band": "30-39"}


def test_ids_are_numbered_across_files():
    ids = [id_ for id_, _, _ in datasets.items(TwoFiles())]
    assert ids == [f"tt_{n:06d}" for n in range(6)]


def face(**overrides):
    row = dict(det=0.8, eye_dist=80, yaw=0.0, roll=0.0, sharp=50.0, est_sex="female", sex="female",
               grey=40.0, pitch=-4.0, yaw3d=0.0, roll3d=0.0, eye_open=0.3, mouth_open=0.05,
               eyewear_glasses=0.05, eyewear_sunglasses=0.05, head_hat=0.3, head_scarf=0.0, head_other=0.0,
               occlusion_covered=0.1, expression_smile=0.1, expression_open=0.0, photo_bw=0.0, photo_art=0.0)
    row.update(overrides)
    return row


@pytest.mark.parametrize("change", [
    dict(det=0.5), dict(eye_dist=40), dict(yaw=0.5), dict(est_sex="male"),               # stage 2
    dict(grey=2), dict(pitch=-25), dict(yaw3d=20), dict(eye_open=0.1), dict(mouth_open=0.3),  # stage 3
    dict(eyewear_sunglasses=0.4), dict(head_hat=0.9), dict(head_scarf=0.6),                # stage 4
    dict(occlusion_covered=0.7), dict(expression_smile=0.6), dict(photo_bw=0.5),
])
def test_each_rule_rejects_its_case(change):
    df = pd.DataFrame([face(), face(**change)] + [face()] * 8)  # stage 2's sharpness is a percentile
    assert list(filters.usable(df))[:2] == [True, False]


def test_faces_missing_a_later_stage_are_not_usable():
    df = pd.DataFrame([face()] * 5)
    df.loc[0, ["pitch", "head_hat"]] = None
    assert not filters.usable(df)[0]
