FROM python:3.13-slim AS runtime
WORKDIR /srv/order-manager
COPY pyproject.toml uv.lock ./
RUN pip install --no-cache-dir uv && uv sync --frozen --no-dev --no-install-project
COPY app app
COPY orderlib orderlib
ENV PATH="/srv/order-manager/.venv/bin:$PATH"
EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app:create_app()"]

FROM runtime AS test
RUN uv sync --frozen --extra dev --no-install-project
COPY workers workers
COPY scripts scripts
COPY tests tests
CMD ["python", "-m", "pytest", "-q"]

FROM runtime AS app
