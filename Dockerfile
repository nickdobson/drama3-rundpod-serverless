# Runpod Serverless worker for fishaudio/drama-3 (Fish Audio Drama 3 TTS) on SGLang-Omni.
#
# Drama 3 support landed after the last PyPI release of SGLang-Omni (0.1.8), so it is
# installed from a pinned commit. The base is the SGLang 0.5.21 image that commit's own
# docker/Dockerfile pins (SGLang-Omni pins sglang==0.5.21; 0.5.22 removed ChunkCache,
# which it imports). The dependency step mirrors that Dockerfile, minus the UCX source
# build and the llama.cpp/CosyVoice extras, which Drama 3 does not use.
ARG SGLANG_IMAGE=lmsysorg/sglang@sha256:b1259f3ea3275f66237c498ea388919729018bc9f01c3d638391e06e2cf3f469
FROM ${SGLANG_IMAGE}

ARG SGLANG_OMNI_COMMIT=4809648d486bdff88dee5199b3e448af3c250f00

RUN apt-get update \
    && apt-get install -y --no-install-recommends sox \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --filter=blob:none https://github.com/sgl-project/sglang-omni.git /opt/sglang-omni \
    && git -C /opt/sglang-omni checkout "${SGLANG_OMNI_COMMIT}"

# The base image's stack lives in the /opt/sglang virtualenv that PATH resolves.
RUN cd /opt/sglang-omni \
    && python3 -c 'import tomllib; print("\n".join(tomllib.load(open("pyproject.toml", "rb"))["tool"]["uv"]["override-dependencies"]))' > /tmp/omni-overrides.txt \
    && uv pip install --no-cache --python /opt/sglang/bin/python3 --no-build-isolation \
        --overrides /tmp/omni-overrides.txt -r pyproject.toml \
        descript-audiotools==0.7.2 descript-audio-codec==1.0.0 \
    && uv pip install --no-cache --python /opt/sglang/bin/python3 --no-deps --reinstall flashinfer-python==0.6.18 \
    && (python3 -m pip uninstall -y flashinfer-cubin flashinfer-jit-cache || true) \
    && python3 -m pip install --no-cache-dir --no-deps --no-build-isolation -e /opt/sglang-omni \
    && rm /tmp/omni-overrides.txt

# Torch's NCCL, not the older system copy.
ENV LD_LIBRARY_PATH=/opt/sglang/lib/python3.12/site-packages/nvidia/nccl/lib:${LD_LIBRARY_PATH}

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
ENTRYPOINT []
CMD ["/opt/worker-venv/bin/python", "-u", "/worker/handler.py"]
