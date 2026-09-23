import numpy as np
import pytest

from ridgegen import card, fingerprints, palm


def test_rolled_is_deterministic_and_sized():
    a, meta_a = fingerprints.rolled(7, 3, 0)
    b, meta_b = fingerprints.rolled(7, 3, 0)
    assert a.shape == (750, 800) and a.dtype == np.uint8
    assert np.array_equal(a, b)
    assert meta_a == meta_b


def test_captures_share_the_pattern_but_differ():
    first, meta_first = fingerprints.rolled(7, 3, 0)
    second, meta_second = fingerprints.rolled(7, 3, 1)
    assert not np.array_equal(first, second)
    assert meta_first["pattern"] == meta_second["pattern"]
    assert (meta_first["capture"], meta_second["capture"]) == (0, 1)


def test_rolled_has_ground_truth_minutiae_inside_the_image():
    image, meta = fingerprints.rolled(11, 2, 0)
    assert 30 < meta["minutiae_count"] == len(meta["minutiae"])
    for m in meta["minutiae"]:
        assert 0 <= m["x"] < 800 and 0 <= m["y"] < 750
        assert m["type"] in ("ending", "bifurcation")
        assert 0 <= m["angle"] < 360
        # Minutiae sit on the printed area, not on blank paper.
        y, x = m["y"], m["x"]
        assert image[max(0, y - 7) : y + 8, max(0, x - 7) : x + 8].mean() < 235


@pytest.mark.parametrize("code, fingers", [(13, [2, 3, 4, 5]), (14, [10, 9, 8, 7]), (15, [6, 1])])
def test_slaps_contain_the_right_fingers(code, fingers):
    image, meta = fingerprints.slap(7, code, 0)
    assert image.shape == (1500, 1600)
    assert [f["fgp"] for f in meta["fingers"]] == fingers


def test_slap_fingers_match_rolled_pattern_classes():
    _, meta = fingerprints.slap(7, 13, 0)
    for finger in meta["fingers"]:
        assert finger["pattern"] == fingerprints.rolled(7, finger["fgp"], 0)[1]["pattern"]


def test_palms():
    full, meta = palm.full(5, "left", 0)
    writers, _ = palm.writers(5, "left", 0)
    assert full.shape == (4000, 2750)
    assert writers.shape == (2500, 875)
    assert meta["hand"] == "left"
    assert set(meta["triradii"]) <= {"a", "b", "c", "d", "t"}
    again, _ = palm.full(5, "left", 0)
    assert np.array_equal(full, again)


def test_card():
    image, meta = card.card(7, 0, "subject_001")
    assert image.shape == (4000, 4000)
    assert sorted(meta["patterns"]) == list(range(1, 11))
