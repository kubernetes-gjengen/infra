FROM python:3.12-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project

COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends libcap2-bin ansible-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=builder /app /app
ENV PATH="/app/.venv/bin:$PATH"

# venv python3 is a symlink to the shared system interpreter — setcap on that
# would grant raw-socket access to every "python3" invocation in the image.
# Cap a dedicated copy instead, kept inside .venv/bin so it still finds
# ../pyvenv.cfg and resolves the venv's site-packages (e.g. scapy).
RUN cp "$(readlink -f /app/.venv/bin/python3)" /app/.venv/bin/python3-cap-net \
    && setcap cap_net_raw,cap_net_admin+eip /app/.venv/bin/python3-cap-net

CMD ["python3-cap-net", "absorb.py"]
