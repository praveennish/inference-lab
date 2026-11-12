"""Classification backends. Each returns a Prediction per example with the raw output kept.

- RulesBackend: pipeline-triage-agent's deterministic classifier, imported from a checkout.
- AnthropicBackend: Claude through the Anthropic API (key from Secrets Manager).
- OpenAICompatBackend: any self-hosted server with /v1/chat/completions (vLLM, llama.cpp).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Protocol

import httpx

from bench.classify.dataset import LABELS, Example, parse_signal
from bench.classify.prompt import SYSTEM_PROMPT, parse_label, user_message

# USD per million tokens, Anthropic first-party API, as published on 2026-11-03.
ANTHROPIC_PRICES = {
    "claude-opus-5-5": {"input": 4.00, "output": 20.00},
    "claude-sonnet-5-5": {"input": 2.00, "output": 10.00},
    "claude-haiku-5-5": {"input": 0.10, "output": 0.50},
}
ANTHROPIC_SECRET_ID = "triage/anthropic-api-key"  # noqa: S105 - a secret name, not a value
REGION = "ap-southeast-2"


@dataclass(frozen=True)
class Prediction:
    id: str
    gold: str
    label: str | None  # None: output could not be parsed into a class
    raw: str
    latency_s: float
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    stop_reason: str = ""
    error: str = ""

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False)


class Backend(Protocol):
    name: str

    def describe(self) -> dict[str, object]: ...

    def classify(self, example: Example) -> Prediction: ...


class RulesBackend:
    name = "rules"

    def __init__(self, triage_repo: Path) -> None:
        src = triage_repo / "src"
        if not (src / "triage_agent" / "rules" / "classifier.py").exists():
            raise FileNotFoundError(f"no triage_agent rules under {src}")
        sys.path.insert(0, str(src))
        from triage_agent.domain.models import FailureSignal  # type: ignore[import-not-found]
        from triage_agent.rules.classifier import classify  # type: ignore[import-not-found]

        self._signal_type = FailureSignal
        self._classify = classify
        self._repo = triage_repo

    def describe(self) -> dict[str, object]:
        return {"backend": self.name, "triage_repo_commit": _git_commit(self._repo)}

    def classify(self, example: Example) -> Prediction:
        s = parse_signal(example.input)
        start = time.perf_counter()
        signal = self._signal_type(
            job_id=example.id,
            error_code=s.error_code,
            message=s.message,
            stage="classify",
            attempt=s.attempt,
        )
        result = self._classify(signal)
        elapsed = time.perf_counter() - start
        label = str(result.failure_class)
        return Prediction(
            id=example.id,
            gold=example.label,
            label=label,
            raw=f"{result.rule_id} matched_on={result.matched_on}",
            latency_s=elapsed,
        )


class AnthropicBackend:
    """One-shot call per example. Thinking stays adaptive (Opus 5.5 cannot disable it); effort
    is set explicitly. Structured output restricts the answer to the four classes. No
    server-side fallback: a refusal must be recorded, not silently answered by another model."""

    def __init__(
        self, model: str, effort: str = "low", max_tokens: int = 2048, client: Any = None
    ) -> None:
        import anthropic

        if model not in ANTHROPIC_PRICES:
            raise ValueError(f"no price recorded for {model}")
        self.name = model
        self.model = model
        self.effort = effort
        self.max_tokens = max_tokens
        # A client can be injected (tests use a mock transport); otherwise the key comes from
        # Secrets Manager.
        self._client = client or anthropic.Anthropic(api_key=_anthropic_key(), max_retries=4)
        self._sdk_version = anthropic.__version__

    def describe(self) -> dict[str, object]:
        return {
            "backend": "anthropic",
            "model": self.model,
            "effort": self.effort,
            "max_tokens": self.max_tokens,
            "structured_output": "json_schema enum",
            "fallbacks": "none",
            "sdk": self._sdk_version,
            "prices_usd_per_mtok": ANTHROPIC_PRICES[self.model],
        }

    def classify(self, example: Example) -> Prediction:
        schema = {
            "type": "object",
            "properties": {"label": {"type": "string", "enum": list(LABELS)}},
            "required": ["label"],
            "additionalProperties": False,
        }
        start = time.perf_counter()
        try:
            response = self._client.messages.create(
                model=self.model,
                max_tokens=self.max_tokens,
                system=SYSTEM_PROMPT,
                messages=[{"role": "user", "content": user_message(example.input)}],
                output_config={
                    "effort": self.effort,
                    "format": {"type": "json_schema", "schema": schema},
                },
            )
        except Exception as exc:  # recorded per example; the run continues
            return Prediction(
                id=example.id,
                gold=example.label,
                label=None,
                raw="",
                latency_s=time.perf_counter() - start,
                error=f"{type(exc).__name__}: {exc}",
            )
        elapsed = time.perf_counter() - start
        text = next((b.text for b in response.content if b.type == "text"), "")
        label = None
        if response.stop_reason != "refusal" and text:
            try:
                label = parse_label(json.loads(text).get("label", ""))
            except (json.JSONDecodeError, AttributeError):
                label = parse_label(text)
        usage = response.usage
        prices = ANTHROPIC_PRICES[self.model]
        cost = (usage.input_tokens * prices["input"] + usage.output_tokens * prices["output"]) / 1e6
        return Prediction(
            id=example.id,
            gold=example.label,
            label=label,
            raw=text,
            latency_s=elapsed,
            input_tokens=usage.input_tokens,
            output_tokens=usage.output_tokens,
            cost_usd=round(cost, 6),
            stop_reason=str(response.stop_reason),
        )


class OpenAICompatBackend:
    """Self-hosted model behind /v1/chat/completions. Greedy decoding, fixed seed.

    constrained=True asks the server to restrict output to the four classes (vLLM structured
    outputs `choice`; llama.cpp would need a grammar). Reported separately from free text."""

    def __init__(
        self,
        base_url: str,
        model: str,
        name: str,
        constrained: bool = False,
        seed: int = 1234,
        timeout_s: float = 120.0,
        http_client: httpx.Client | None = None,
    ) -> None:
        self.name = name
        self.base_url = base_url.rstrip("/")
        self.model = model
        self.constrained = constrained
        self.seed = seed
        self._http = http_client or httpx.Client(timeout=timeout_s)

    def describe(self) -> dict[str, object]:
        info: dict[str, object] = {
            "backend": "openai-compatible",
            "base_url": self.base_url,
            "model": self.model,
            "temperature": 0,
            "seed": self.seed,
            "constrained": self.constrained,
        }
        try:
            info["models_endpoint"] = self._http.get(f"{self.base_url}/v1/models").json()
        except (httpx.HTTPError, ValueError) as exc:
            info["models_endpoint_error"] = str(exc)
        return info

    def classify(self, example: Example) -> Prediction:
        body: dict[str, object] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_message(example.input)},
            ],
            "temperature": 0,
            "seed": self.seed,
            "max_tokens": 16,
        }
        if self.constrained:
            body["structured_outputs"] = {"choice": list(LABELS)}
        start = time.perf_counter()
        try:
            r = self._http.post(f"{self.base_url}/v1/chat/completions", json=body)
            r.raise_for_status()
            data = r.json()
        except (httpx.HTTPError, ValueError) as exc:
            return Prediction(
                id=example.id,
                gold=example.label,
                label=None,
                raw="",
                latency_s=time.perf_counter() - start,
                error=f"{type(exc).__name__}: {exc}",
            )
        elapsed = time.perf_counter() - start
        choice = data["choices"][0]
        text = choice["message"].get("content") or ""
        usage = data.get("usage") or {}
        return Prediction(
            id=example.id,
            gold=example.label,
            label=parse_label(text),
            raw=text,
            latency_s=elapsed,
            input_tokens=usage.get("prompt_tokens", 0),
            output_tokens=usage.get("completion_tokens", 0),
            stop_reason=str(choice.get("finish_reason", "")),
        )


def _anthropic_key() -> str:
    """Secrets Manager first (the project's rule); ANTHROPIC_API_KEY only as a local override."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        return os.environ["ANTHROPIC_API_KEY"]
    import boto3

    client = boto3.client("secretsmanager", region_name=REGION)
    return client.get_secret_value(SecretId=ANTHROPIC_SECRET_ID)["SecretString"].strip()


def _git_commit(repo: Path) -> str:
    try:
        cmd = ["git", "-C", str(repo), "rev-parse", "HEAD"]
        out = subprocess.run(  # noqa: S603, S607 - fixed git command from PATH, no shell
            cmd,
            capture_output=True,
            text=True,
            check=True,
        )
        return out.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        # The spike hosts get a zip, not a clone; `make spike-plan` stamps the commit into it.
        stamp = repo / ".bundle-commit"
        return stamp.read_text().strip() if stamp.exists() else "unknown"
