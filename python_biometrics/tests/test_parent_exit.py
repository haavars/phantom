import os
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_exits_when_the_parent_app_goes_away():
    """Started like Bilder.PythonService does it, the server exits once its stdin closes."""
    port = free_port()
    env = {**os.environ, "PORT": str(port), "BILDER_EXIT_WITH_PARENT": "1"}
    proc = subprocess.Popen(
        [sys.executable, "server.py"], cwd=Path(__file__).parent.parent, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        deadline = time.monotonic() + 30
        while True:
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1)
                break
            except OSError:
                assert time.monotonic() < deadline, "server didn't start"
                time.sleep(0.2)

        proc.stdin.close()  # what happens when the BEAM exits, however abruptly
        assert proc.wait(timeout=10) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
