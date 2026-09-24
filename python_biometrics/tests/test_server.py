import base64
import io

import pytest
from fastapi.testclient import TestClient
from PIL import Image

import diffusion
import verify
from server import app

client = TestClient(app)


def test_health():
    assert client.get("/health").json()["status"] == "ready"


def test_render_returns_a_tagged_500_ppi_png():
    response = client.post("/render", json={"kind": "finger", "code": 4, "seed": 3, "capture": 0})
    assert response.status_code == 200
    body = response.json()
    assert (body["width"], body["height"], body["ppi"]) == (800, 750, 500)
    assert body["meta"]["fgp"] == 4

    image = Image.open(io.BytesIO(base64.b64decode(body["image"])))
    assert image.mode == "L" and image.size == (800, 750)
    assert round(image.info["dpi"][0]) == 500
    assert image.info["Synthetic"] == "true"
    assert image.info["Seed"] == "3"


def test_rejects_unknown_codes():
    assert client.post("/render", json={"kind": "finger", "code": 11, "seed": 1}).status_code == 400
    assert client.post("/render", json={"kind": "slap", "code": 12, "seed": 1}).status_code == 400
    assert client.post("/render", json={"kind": "iris", "code": 1, "seed": 1}).status_code == 422


@pytest.mark.skipif(not verify.available(), reason="NBIS / NFIQ 2 not installed (run setup.sh)")
def test_fingers_come_back_verified_and_matchable():
    first = client.post("/render", json={"kind": "finger", "code": 2, "seed": 3, "capture": 0}).json()
    second = client.post("/render", json={"kind": "finger", "code": 2, "seed": 3, "capture": 1}).json()
    check = first["meta"]["verification"]
    assert check["renderer"] == "procedural"
    assert check["accepted"] and check["attempts"] == 1 and check["attempt"] == 0
    assert {"nfiq2", "minutiae_recall", "minutiae_spurious", "mean_displacement_px"} <= set(check)

    templates = [first["meta"]["verification"]["detected"], second["meta"]["verification"]["detected"]]
    scores = client.post("/match", json={"templates": templates, "pairs": [[0, 1]]}).json()["scores"]
    assert len(scores) == 1 and scores[0] > 40


def test_verification_can_be_skipped():
    body = client.post("/render", json={"kind": "finger", "code": 2, "seed": 3, "verify": False}).json()
    assert "verification" not in body["meta"]


@pytest.mark.skipif(not diffusion.available(), reason="diffusion renderer not installed (setup.sh --diffusion)")
def test_diffusion_renderer_is_recorded():
    body = client.post("/render", json={"kind": "finger", "code": 2, "seed": 3, "renderer": "diffusion"}).json()
    assert body["meta"]["renderer"].startswith("diffusion/")
    image = Image.open(io.BytesIO(base64.b64decode(body["image"])))
    assert image.info["Renderer"] == body["meta"]["renderer"]
    if verify.available():
        assert body["meta"]["verification"]["renderer"] == body["meta"]["renderer"]
