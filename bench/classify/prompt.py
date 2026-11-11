"""The one prompt every model backend receives (Claude and self-hosted alike).

Written from the class definitions in pipeline-triage-agent (FailureClass and the rule reasons),
before any model output was seen, and frozen. Changing it changes PROMPT_VERSION, and results
with different versions are never compared in one table.
"""

from __future__ import annotations

import hashlib

from bench.classify.dataset import LABELS

SYSTEM_PROMPT = """\
You classify failed data-ingestion jobs. Each input has an error code set by the platform, an \
attempt number, and a message that may come from an upstream service and may be noisy or \
misleading. The platform's own error codes are more reliable than free-text messages, but some \
codes are generic and only the message tells the class.

Classes:
- cloud_outage: a transient cloud-side problem (throttling, service unavailable, internal \
errors, network resets or timeouts while calling a cloud service). Retrying should help.
- user_input_error: the producer's submission is wrong (source object missing or unreadable, \
access denied, declared schema does not match the data, invalid spec). The producer must fix it.
- unsupported_transformation: the input is valid but the platform cannot process this format \
or shape yet. Needs a platform code change.
- unknown: none of the above can be determined from the input.

Answer with exactly one class name and nothing else."""

PROMPT_VERSION = hashlib.sha256(SYSTEM_PROMPT.encode()).hexdigest()[:12]


def user_message(failure_text: str) -> str:
    return f"Failure:\n{failure_text}\n\nClass:"


def parse_label(output: str) -> str | None:
    """Exact class name after trimming; otherwise the single class name mentioned; else None."""
    text = output.strip().strip("`'\".").lower()
    if text in LABELS:
        return text
    found = [label for label in LABELS if label in text]
    return found[0] if len(found) == 1 else None
