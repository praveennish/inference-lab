"""Load the classification dataset copied from pipeline-triage-agent and check it is unchanged."""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

DATASET = Path(__file__).resolve().parents[2] / "data" / "classification.jsonl"
EXPECTED_SHA256 = "4b4277b7b45acffe9417059abaa7fa5b53d5722868d30c4881a5586745805360"
SOURCE_COMMIT = "ac5bb27b912fb840be03b5e56f860b507ee21808"
LABELS = ("cloud_outage", "user_input_error", "unsupported_transformation", "unknown")


@dataclass(frozen=True, slots=True)
class Example:
    id: str
    input: str
    label: str


@dataclass(frozen=True, slots=True)
class Signal:
    """The fields the rule classifier reads, parsed back out of an example's input text."""

    error_code: str
    attempt: int
    message: str


def sha256(path: Path = DATASET) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path: Path = DATASET, verify: bool = True) -> list[Example]:
    if verify and sha256(path) != EXPECTED_SHA256:
        raise ValueError(f"{path} differs from the recorded copy; see data/SOURCE.md")
    rows = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    examples = [Example(r["id"], r["input"], r["label"]) for r in rows]
    unknown = {e.label for e in examples} - set(LABELS)
    if unknown:
        raise ValueError(f"unexpected labels: {sorted(unknown)}")
    return examples


def parse_signal(text: str) -> Signal:
    """Inputs look like 'error_code: X\\nattempt: N\\nmessage: ...'; the message may span lines."""
    fields: dict[str, str] = {}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key = key.strip()
        if key == "message":
            fields["message"] = "\n".join([value.strip(), *lines[i + 1 :]]).strip()
            break
        fields[key] = value.strip()
    return Signal(
        error_code=fields.get("error_code", "UNKNOWN"),
        attempt=int(fields.get("attempt", "1")),
        message=fields.get("message", ""),
    )
