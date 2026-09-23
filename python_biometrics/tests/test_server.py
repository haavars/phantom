import base64
import io

from fastapi.testclient import TestClient
from PIL import Image

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
