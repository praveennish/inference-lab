"""Accuracy, per-class precision and recall, macro-F1 and a confusion matrix. Pure functions."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from bench.classify.dataset import LABELS

INVALID = "invalid"


@dataclass(frozen=True)
class Scores:
    n: int
    correct: int
    accuracy: float
    macro_f1: float
    invalid: int
    per_class: dict[str, dict[str, float]] = field(default_factory=dict)
    confusion: dict[str, dict[str, int]] = field(default_factory=dict)


def score(gold: list[str], pred: list[str | None]) -> Scores:
    if len(gold) != len(pred):
        raise ValueError("gold and pred differ in length")
    predicted = [p if p is not None else INVALID for p in pred]
    pairs = Counter(zip(gold, predicted, strict=True))
    per_class: dict[str, dict[str, float]] = {}
    f1s = []
    for label in LABELS:
        tp = pairs[(label, label)]
        fp = sum(c for (g, p), c in pairs.items() if p == label and g != label)
        fn = sum(c for (g, p), c in pairs.items() if g == label and p != label)
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        per_class[label] = {
            "support": tp + fn,
            "precision": round(precision, 4),
            "recall": round(recall, 4),
            "f1": round(f1, 4),
        }
        f1s.append(f1)
    correct = sum(c for (g, p), c in pairs.items() if g == p)
    columns = [*LABELS, INVALID]
    confusion = {g: {p: pairs[(g, p)] for p in columns} for g in LABELS}
    return Scores(
        n=len(gold),
        correct=correct,
        accuracy=round(correct / len(gold), 4) if gold else 0.0,
        macro_f1=round(sum(f1s) / len(f1s), 4),
        invalid=predicted.count(INVALID),
        per_class=per_class,
        confusion=confusion,
    )
