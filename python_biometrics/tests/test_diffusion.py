import numpy as np
import pytest

import diffusion
import verify
from ridgegen import fingerprints
from ridgegen import impression as imp

pytestmark = pytest.mark.skipif(
    not diffusion.available(), reason="diffusion renderer not installed (setup.sh --diffusion)"
)


def test_retextures_a_print_deterministically_and_keeps_its_ridges():
    capture = fingerprints.rolled_capture(21, 3, 0)
    procedural = imp.render_capture(capture)
    first = diffusion.render(procedural, seed=5)
    assert first.shape == procedural.shape and first.dtype == np.uint8
    assert np.array_equal(first, diffusion.render(procedural, seed=5))
    assert not np.array_equal(first, diffusion.render(procedural, seed=6))
    assert not np.array_equal(first, procedural)

    if verify.available():
        metrics = verify.verify(first, capture)
        assert metrics["minutiae_recall"] >= 0.8
