# Runpod Serverless worker for fishaudio/drama-3 (Fish Audio Drama 3 TTS) on SGLang-Omni.
#
# Base: the SGLang-Omni CUDA image (SGLang 0.5.21, torch, CUDA 13, UCX, FlashInfer JIT cache
# for SM89/SM90), pinned by digest. Drama 3 support landed after the last PyPI release
# (0.1.8), so SGLang-Omni itself is installed from a pinned commit on main.
ARG BASE_IMAGE=hongccc/sglang-omni@sha256:06ed306707bcf3d9e9beb5ba7ce66f09a666cac11c23455ece50c34199c0e985
FROM ${BASE_IMAGE}

ARG SGLANG_OMNI_COMMIT=4809648d486bdff88dee5199b3e448af3c250f00

RUN git clone --filter=blob:none https://github.com/sgl-project/sglang-omni.git /opt/sglang-omni \
    && git -C /opt/sglang-omni checkout "${SGLANG_OMNI_COMMIT}" \
    && python3 -m pip install --no-cache-dir --no-deps --no-build-isolation -e /opt/sglang-omni

# The handler gets its own venv: the runpod SDK pulls fastapi[all] and friends, which
# must not move the versions pinned in the SGLang environment. `sgl-omni` still
# resolves to /opt/sglang/bin through PATH.
COPY requirements.txt /worker/requirements.txt
RUN uv venv /opt/worker-venv --python 3.12 \
    && uv pip install --no-cache --python /opt/worker-venv/bin/python -r /worker/requirements.txt

COPY handler.py /worker/handler.py

# Weights are not baked in. The handler prefers Runpod's cached model
# (/runpod-volume/huggingface-cache) and otherwise downloads to container disk.
ENV MODEL_ID=fishaudio/drama-3 \
    PYTHONUNBUFFERED=1

WORKDIR /worker
# The base image's entrypoint clones sglang-omni main at start; skip it.
ENTRYPOINT []
CMD ["/opt/worker-venv/bin/python", "-u", "/worker/handler.py"]
