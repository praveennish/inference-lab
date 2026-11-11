"""Run one backend over the classification dataset and write traceable results.

  uv run python -m bench.classify.run rules --triage-repo ../pipeline-triage-agent
  uv run python -m bench.classify.run anthropic --model claude-opus-5-5
  uv run python -m bench.classify.run openai --base-url http://host:8000 --model Qwen/... --name x

Writes build/results/<run>/classify/<name>/{predictions.jsonl,summary.json} and appends a row to
build/results/<run>/summary.md. Every number in the summary comes from predictions.jsonl.
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import time
from dataclasses import asdict
from datetime import UTC, datetime
from pathlib import Path

from bench.classify import dataset
from bench.classify.backends import (
    AnthropicBackend,
    Backend,
    OpenAICompatBackend,
    Prediction,
    RulesBackend,
    _git_commit,
)
from bench.classify.metrics import score
from bench.classify.prompt import PROMPT_VERSION

ROOT = Path(__file__).resolve().parents[2]


def build_backend(args: argparse.Namespace) -> Backend:
    if args.backend == "rules":
        return RulesBackend(Path(args.triage_repo).resolve())
    if args.backend == "anthropic":
        return AnthropicBackend(args.model, effort=args.effort)
    return OpenAICompatBackend(args.base_url, args.model, args.name, constrained=args.constrained)


def percentile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, round(q * (len(ordered) - 1))))
    return ordered[k]


def summarize(preds: list[Prediction], meta: dict[str, object]) -> dict[str, object]:
    scores = score([p.gold for p in preds], [p.label for p in preds])
    latencies = [p.latency_s for p in preds if not p.error]
    return {
        **meta,
        "scores": asdict(scores),
        "errors": sum(1 for p in preds if p.error),
        "refusals": sum(1 for p in preds if p.stop_reason == "refusal"),
        "latency_s": {
            "p50": round(statistics.median(latencies), 4) if latencies else 0.0,
            "p95": round(percentile(latencies, 0.95), 4),
            "max": round(max(latencies), 4) if latencies else 0.0,
        },
        "tokens": {
            "input": sum(p.input_tokens for p in preds),
            "output": sum(p.output_tokens for p in preds),
        },
        "cost_usd": round(sum(p.cost_usd for p in preds), 4),
        "misclassified": [
            {"id": p.id, "gold": p.gold, "pred": p.label, "raw": p.raw[:120]}
            for p in preds
            if p.label != p.gold
        ],
    }


def append_markdown(summary_md: Path, name: str, s: dict) -> None:
    sc = s["scores"]
    if not summary_md.exists():
        summary_md.write_text(
            "# Classification results\n\n"
            f"Dataset `data/classification.jsonl` sha256 `{dataset.EXPECTED_SHA256[:12]}`, "
            f"source commit `{dataset.SOURCE_COMMIT[:7]}`, prompt `{PROMPT_VERSION}`.\n\n"
            "| Backend | Correct | Accuracy | Macro-F1 | Invalid | Errors | Refusals "
            "| p50 latency s | p95 latency s | Cost USD |\n"
            "|---|---|---|---|---|---|---|---|---|---|\n"
        )
    with summary_md.open("a") as f:
        f.write(
            f"| {name} | {sc['correct']}/{sc['n']} | {sc['accuracy']:.2f} | {sc['macro_f1']:.2f} "
            f"| {sc['invalid']} | {s['errors']} | {s['refusals']} | {s['latency_s']['p50']} "
            f"| {s['latency_s']['p95']} | {s['cost_usd']} |\n"
        )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("backend", choices=["rules", "anthropic", "openai"])
    ap.add_argument("--triage-repo", default=str(ROOT.parent / "pipeline-triage-agent"))
    ap.add_argument("--model", default="")
    ap.add_argument("--effort", default="low")
    ap.add_argument("--base-url", default="http://localhost:8000")
    ap.add_argument("--name", default="")
    ap.add_argument("--constrained", action="store_true")
    ap.add_argument("--run-dir", default="", help="build/results/<run>; default: new timestamp")
    ap.add_argument("--limit", type=int, default=0, help="first N examples only (smoke test)")
    args = ap.parse_args(argv)

    examples = dataset.load()
    if args.limit:
        examples = examples[: args.limit]
    backend = build_backend(args)
    name = args.name or backend.name
    run_dir = (
        Path(args.run_dir)
        if args.run_dir
        else (ROOT / "build" / "results" / datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ"))
    )
    out = run_dir / "classify" / name
    out.mkdir(parents=True, exist_ok=True)

    started = datetime.now(UTC).isoformat()
    t0 = time.perf_counter()
    preds: list[Prediction] = []
    with (out / "predictions.jsonl").open("w") as f:
        for example in examples:
            p = backend.classify(example)
            preds.append(p)
            f.write(p.to_json() + "\n")
            f.flush()
    meta = {
        "name": name,
        "started_utc": started,
        "wall_s": round(time.perf_counter() - t0, 2),
        "dataset_sha256": dataset.sha256(),
        "dataset_source_commit": dataset.SOURCE_COMMIT,
        "prompt_version": PROMPT_VERSION,
        "inference_lab_commit": _git_commit(ROOT),
        "client_host": platform.node(),
        "client_python": platform.python_version(),
        "backend_config": backend.describe(),
        "examples": len(examples),
    }
    s = summarize(preds, meta)
    (out / "summary.json").write_text(json.dumps(s, indent=2, default=str) + "\n")
    append_markdown(run_dir / "summary.md", name, s)
    sc = s["scores"]
    print(
        f"{name}: {sc['correct']}/{sc['n']} accuracy={sc['accuracy']} "
        f"macro_f1={sc['macro_f1']} invalid={sc['invalid']} errors={s['errors']} "
        f"cost_usd={s['cost_usd']} -> {out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
