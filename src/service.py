"""
BentoML service: wraps TinyLlama with:
  - /generate  endpoint (POST)
  - /healthz   liveness probe
  - Prometheus metrics via starlette-exporter
"""
from __future__ import annotations

import time
from typing import Annotated

import bentoml
import torch
from bentoml.io import JSON
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.requests import Request
from starlette.responses import Response

# ── Prometheus metrics ───────────────────────────────────────────────────────
REQUEST_COUNT = Counter(
    "llm_requests_total",
    "Total inference requests",
    ["endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "llm_request_latency_seconds",
    "Inference latency in seconds",
    ["endpoint"],
    buckets=[0.1, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0],
)
TOKEN_COUNT = Counter(
    "llm_tokens_generated_total",
    "Total tokens generated",
)


# ── Request / Response schemas ────────────────────────────────────────────────
class GenerateRequest(BaseModel):
    prompt: str = Field(..., description="Input prompt")
    max_new_tokens: int = Field(256, ge=1, le=2048)
    temperature: float = Field(0.7, ge=0.0, le=2.0)
    top_p: float = Field(0.9, ge=0.0, le=1.0)
    do_sample: bool = True


class GenerateResponse(BaseModel):
    text: str
    tokens_generated: int
    latency_ms: float


# ── BentoML runner ────────────────────────────────────────────────────────────
llm_runner = bentoml.transformers.get("tinyllama-chat:latest").to_runner()

svc = bentoml.Service("tinyllama-service", runners=[llm_runner])


@svc.api(
    input=JSON(pydantic_model=GenerateRequest),
    output=JSON(pydantic_model=GenerateResponse),
    route="/generate",
)
async def generate(req: GenerateRequest) -> GenerateResponse:
    start = time.perf_counter()
    label = "generate"

    try:
        tokenizer = llm_runner.custom_objects["tokenizer"]

        # Tokenise
        inputs = tokenizer(req.prompt, return_tensors="pt").to(llm_runner.device)
        input_len = inputs["input_ids"].shape[-1]

        # Run inference via runner (non-blocking)
        output_ids = await llm_runner.generate.async_run(
            **inputs,
            max_new_tokens=req.max_new_tokens,
            temperature=req.temperature,
            top_p=req.top_p,
            do_sample=req.do_sample,
        )

        # Decode only the new tokens
        new_ids = output_ids[0][input_len:]
        text = tokenizer.decode(new_ids, skip_special_tokens=True)
        tokens = len(new_ids)

        latency = (time.perf_counter() - start) * 1000

        REQUEST_COUNT.labels(endpoint=label, status="success").inc()
        REQUEST_LATENCY.labels(endpoint=label).observe(latency / 1000)
        TOKEN_COUNT.inc(tokens)

        return GenerateResponse(text=text, tokens_generated=tokens, latency_ms=round(latency, 2))

    except Exception as exc:
        REQUEST_COUNT.labels(endpoint=label, status="error").inc()
        raise exc


@svc.api(input=JSON(), output=JSON(), route="/healthz")
async def health(_: dict) -> dict:
    return {"status": "ok"}


# Expose /metrics for Prometheus scraping
@svc.on_startup
def startup(app):
    from starlette.routing import Route

    async def metrics_endpoint(request: Request) -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    app.routes.append(Route("/metrics", metrics_endpoint))