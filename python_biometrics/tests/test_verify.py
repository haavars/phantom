import numpy as np
import pytest

import verify
from ridgegen import fingerprints
from ridgegen import impression as imp

needs_tools = pytest.mark.skipif(not verify.available(), reason="NBIS / NFIQ 2 not installed (run setup.sh)")


def test_pairing_is_one_to_one_within_tolerances():
    reference = np.array([[100, 100, 90, 50], [200, 200, 0, 50], [300, 300, 45, 50]], float)
    detected = np.array([
        [104, 103, 100, 50],  # 5 px, 10 degrees off: pairs with the first
        [102, 101, 95, 50],  # also near the first, but it's taken
        [200, 200, 180, 50],  # right place, pointing the wrong way
        [330, 300, 45, 50],  # too far
    ], float)
    result = verify.compare(detected, reference)
    assert result["paired_count"] == 1
    assert result["minutiae_recall"] == pytest.approx(1 / 3, abs=0.001)
    assert result["minutiae_spurious"] == 0.75
    assert result["mean_displacement_px"] == pytest.approx(np.hypot(2, 1), abs=0.01)
    assert sorted(result["missed"]) == [[200, 200], [300, 300]]


def test_angles_wrap_around():
    reference = np.array([[50, 50, 355, 50]], float)
    detected = np.array([[50, 50, 10, 50]], float)
    assert verify.compare(detected, reference)["paired_count"] == 1


def test_keep_drops_points_outside_the_area_and_low_quality():
    area = np.zeros((100, 100), bool)
    area[20:80, 20:80] = True
    points = np.array([[50, 50, 0, 60], [10, 50, 0, 60], [50, 50, 0, 5]], float)
    assert verify.keep(points, area).tolist() == [[50, 50, 0, 60]]


@needs_tools
def test_procedural_rolled_print_passes_verification():
    capture = fingerprints.rolled_capture(11, 2, 0)
    metrics = verify.verify(imp.render_capture(capture), capture)
    assert metrics["accepted"]
    assert metrics["minutiae_recall"] >= 0.9
    assert metrics["minutiae_spurious"] <= 0.1
    assert 20 <= metrics["nfiq2"] <= 100
    assert metrics["ground_truth_agreement"] >= 0.8
    assert len(metrics["detected"]) > 30


@needs_tools
def test_a_different_finger_fails_verification():
    capture = fingerprints.rolled_capture(11, 2, 0)
    other = imp.render_capture(fingerprints.rolled_capture(11, 3, 0))
    metrics = verify.verify(other, capture)
    assert not metrics["accepted"]
    assert metrics["minutiae_recall"] < 0.3


@needs_tools
def test_slaps_are_verified_per_finger():
    capture = fingerprints.slap_capture(7, 15, 0)
    metrics = verify.verify(imp.render_capture(capture), capture)
    assert [f["fgp"] for f in metrics["fingers"]] == [6, 1]
    assert all(f["nfiq2"] is not None for f in metrics["fingers"])
    assert metrics["nfiq2"] == min(f["nfiq2"] for f in metrics["fingers"])


@needs_tools
def test_bozorth3_separates_mated_from_non_mated():
    def detected(finger, capture):
        return verify.mindtct(imp.render_capture(fingerprints.rolled_capture(5, finger, capture)))

    templates = [detected(4, 0), detected(4, 1), detected(7, 1)]
    mated, non_mated = verify.bozorth3(templates, [(0, 1), (0, 2)])
    assert mated > 60 > non_mated
