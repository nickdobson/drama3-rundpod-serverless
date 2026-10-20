# Fish Audio Drama 3 — Runpod Serverless worker

A queue-based Runpod Serverless worker for [`fishaudio/drama-3`](https://huggingface.co/fishaudio/drama-3)
(35B MoE text-to-speech, 3B active, FP8 experts) served by
[SGLang-Omni](https://github.com/sgl-project/sglang-omni).

- `Dockerfile` — the SGLang 0.5.21 CUDA 13 image (pinned digest) plus SGLang-Omni from a
  pinned commit (Drama 3 support is newer than the 0.1.8 PyPI release). SGLang-Omni pins
  `sglang==0.5.21`; 0.5.22 removed a module it imports, so the base must stay on 0.5.21.
- `handler.py` — starts `sgl-omni serve` on localhost at worker boot, then forwards each
  job's `input` to `POST /v1/audio/speech` and returns the audio base64-encoded.

## Endpoint settings

The live endpoint (`derlgrwcavpoya`) runs with:

| Setting | Value |
| --- | --- |
| Type | Queue (GitHub integration, `main` branch; each push rebuilds and rolls out) |
| GPU pools, in priority order | `BLACKWELL_96` (RTX PRO 6000 96 GB), `ADA_80_PRO` (H100 80 GB), `HOPPER_141` (H200 141 GB). Weights are ~39 GB, and the engine takes 70% of the card by default |
| GPUs per worker | 1 |
| Allowed CUDA versions | 13.0–13.4 (the image is CUDA 13) |
| Workers | min 0, max 1 |
| Idle timeout | 120 s |
| FlashBoot | On |
| Execution timeout | 600 s |
| Container disk | 100 GB (room for a weight download if the model cache misses) |
| Cached model | `https://huggingface.co/fishaudio/drama-3` |

The RTX PRO 6000 is first because H100/H200 serverless supply is often low. Drama 3 is only
validated upstream on Hopper (sm_90); on Blackwell it runs, with fallback sampling kernels.

A worker on a new host pulls a ~15 GB (compressed) image, waits while Runpod's model cache
downloads the ~41.5 GB checkpoint to that host (about 4 minutes; the worker shows as
THROTTLED with `image ready, model pending download` in its system log), then loads the
model. So the first job on a new host can take 10–20 minutes. Later jobs on a warm worker
take seconds.

### Environment variables (all optional)

| Variable | Default | Purpose |
| --- | --- | --- |
| `MODEL_ID` | `fishaudio/drama-3` | Hugging Face repo to serve (`fishaudio/drama-3-int4` also works and fits 48 GB cards) |
| `SGL_OMNI_EXTRA_ARGS` | empty | Extra `sgl-omni serve` flags, e.g. `--tts_engine.factory.max_running_requests 32` |
| `STARTUP_TIMEOUT_S` | `1800` | How long to wait for the server to become healthy |
| `REQUEST_TIMEOUT_S` | `900` | Per-job timeout for the speech request |
| `HF_TOKEN` | empty | Only needed for a gated or private `MODEL_ID` |

## Request

`input` is a `/v1/audio/speech` body. `text` is accepted as an alias for `input`.

```json
{
  "input": {
    "input": "[sighs] Fine. If we miss it, it's on you. [laughs] Well, maybe that's fair.",
    "references": [{
      "audio_path": "https://huggingface.co/datasets/zhaochenyang20/seed-tts-eval-mini/resolve/main/en/prompt-wavs/common_voice_en_10119832.wav",
      "text": "We asked over twenty different people, and they all said it was his."
    }],
    "response_format": "mp3"
  }
}
```

Useful fields: `references` (voice cloning: `audio_path` URL, or base64 `data` with
`media_type`, plus the transcript in `text`), `previous_takes` (editing as continuation),
speaker tags `<|speaker:0|>`…`<|speaker:15|>` in the text, `response_format`
(`wav`, `mp3`, `flac`, `opus`, `aac`, `pcm`), `temperature`, `top_p`, `top_k`,
`max_new_tokens`, `seed`.

## Response

```json
{
  "audio_base64": "...",
  "format": "mp3",
  "content_type": "audio/mpeg",
  "finish_reason": "stop",
  "usage": {"prompt_tokens": 123, "completion_tokens": 456}
}
```

Errors from the server come back as `{"error": ..., "status_code": 400}`.

```bash
curl -s -X POST "https://api.runpod.ai/v2/$ENDPOINT_ID/runsync" \
  -H "Authorization: Bearer $RUNPOD_API_KEY" -H "Content-Type: application/json" \
  -d '{"input":{"input":"Hello from Drama 3 on Runpod.","response_format":"mp3"}}' \
  | python -c "import sys,json,base64; o=json.load(sys.stdin)['output']; open('out.mp3','wb').write(base64.b64decode(o['audio_base64']))"
```

Use `/run` plus `/status/{id}` for the first (cold) request; `/runsync` times out while a
worker is still loading.
