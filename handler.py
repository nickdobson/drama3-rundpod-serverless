"""Runpod Serverless handler for fishaudio/drama-3 served by SGLang-Omni.

On worker start this launches `sgl-omni serve` on localhost and waits for /health.
Each job's `input` is forwarded as the body of POST /v1/audio/speech, and the
audio comes back base64-encoded in the job output.
"""

import base64
import glob
import os
import shlex
import subprocess
import sys
import time

import requests
import runpod

MODEL_ID = os.environ.get("MODEL_ID", "fishaudio/drama-3")
PORT = int(os.environ.get("SGL_OMNI_PORT", "8000"))
BASE_URL = f"http://127.0.0.1:{PORT}"
STARTUP_TIMEOUT_S = int(os.environ.get("STARTUP_TIMEOUT_S", "1800"))
REQUEST_TIMEOUT_S = int(os.environ.get("REQUEST_TIMEOUT_S", "900"))
# Extra `sgl-omni serve` flags, e.g. "--tts_engine.factory.max_running_requests 32".
EXTRA_ARGS = shlex.split(os.environ.get("SGL_OMNI_EXTRA_ARGS", ""))
# Where Runpod's model cache puts a model attached to the endpoint.
RUNPOD_HF_CACHE = "/runpod-volume/huggingface-cache/hub"


def resolve_model_path() -> str:
    """A local checkpoint directory: Runpod's cached copy if the endpoint has one,
    otherwise a download onto the container disk."""
    repo_dir = os.path.join(RUNPOD_HF_CACHE, "models--" + MODEL_ID.replace("/", "--"))
    for snapshot in sorted(glob.glob(os.path.join(repo_dir, "snapshots", "*"))):
        if os.path.isfile(os.path.join(snapshot, "config.json")) and os.path.isfile(
            os.path.join(snapshot, "codec.pth")
        ):
            print(f"[drama3] using Runpod cached model at {snapshot}", flush=True)
            return snapshot

    from huggingface_hub import snapshot_download

    print(f"[drama3] no cached model found, downloading {MODEL_ID}", flush=True)
    started = time.time()
    path = snapshot_download(MODEL_ID, token=os.environ.get("HF_TOKEN") or None)
    print(f"[drama3] downloaded to {path} in {time.time() - started:.0f}s", flush=True)
    return path


def start_server(model_path: str) -> subprocess.Popen:
    cmd = [
        "sgl-omni",
        "serve",
        "--model-path",
        model_path,
        "--host",
        "127.0.0.1",
        "--port",
        str(PORT),
        # The checkpoint ships the same codec.pth as the default fishaudio/s2-pro
        # codec, so load it from here instead of downloading it again.
        "--vocoder.factory.codec_path",
        model_path,
        *EXTRA_ARGS,
    ]
    print(f"[drama3] starting: {shlex.join(cmd)}", flush=True)
    return subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr)


def wait_until_healthy(server: subprocess.Popen) -> None:
    deadline = time.time() + STARTUP_TIMEOUT_S
    while time.time() < deadline:
        if server.poll() is not None:
            raise RuntimeError(f"sgl-omni serve exited with code {server.returncode}")
        try:
            if requests.get(f"{BASE_URL}/health", timeout=5).status_code == 200:
                return
        except requests.RequestException:
            pass
        time.sleep(5)
    raise RuntimeError(f"sgl-omni serve not healthy after {STARTUP_TIMEOUT_S}s")


def handler(job):
    body = dict(job.get("input") or {})
    if "input" not in body and "text" in body:
        body["input"] = body.pop("text")
    if not body.get("input"):
        return {"error": "input.input (the text to speak) is required"}
    # Job output is one payload, so always ask the server for the whole clip.
    body["stream"] = False
    body.setdefault("response_format", "wav")

    try:
        resp = requests.post(
            f"{BASE_URL}/v1/audio/speech", json=body, timeout=REQUEST_TIMEOUT_S
        )
    except requests.RequestException as exc:
        return {"error": f"request to sgl-omni failed: {exc}"}
    if resp.status_code != 200:
        try:
            detail = resp.json()
        except ValueError:
            detail = resp.text
        return {"error": detail, "status_code": resp.status_code}

    usage = {
        key: int(resp.headers[header])
        for key, header in (
            ("prompt_tokens", "X-Prompt-Tokens"),
            ("completion_tokens", "X-Completion-Tokens"),
        )
        if header in resp.headers
    }
    return {
        "audio_base64": base64.b64encode(resp.content).decode("ascii"),
        "format": body["response_format"],
        "content_type": resp.headers.get("Content-Type"),
        "finish_reason": resp.headers.get("X-Finish-Reason"),
        "usage": usage,
    }


if __name__ == "__main__":
    model_path = resolve_model_path()
    server = start_server(model_path)
    wait_until_healthy(server)
    print("[drama3] sgl-omni is healthy, accepting jobs", flush=True)
    runpod.serverless.start({"handler": handler})
