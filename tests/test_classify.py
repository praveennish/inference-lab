from bench.classify import dataset
from bench.classify.metrics import score
from bench.classify.prompt import PROMPT_VERSION, parse_label


def test_dataset_is_the_recorded_copy():
    examples = dataset.load()
    assert len(examples) == 65
    assert {e.label for e in examples} == set(dataset.LABELS)


def test_parse_signal_keeps_multiline_message():
    s = dataset.parse_signal("error_code: IO.ERROR\nattempt: 3\nmessage: a: b\nsecond line")
    assert (s.error_code, s.attempt, s.message) == ("IO.ERROR", 3, "a: b\nsecond line")


def test_parse_label_exact_and_lenient():
    assert parse_label(" cloud_outage\n") == "cloud_outage"
    assert parse_label("`unknown`.") == "unknown"
    assert parse_label("The class is user_input_error") == "user_input_error"
    assert parse_label("cloud_outage or unknown") is None
    assert parse_label("") is None


def test_score_counts_invalid_as_wrong():
    gold = ["cloud_outage", "unknown", "unknown", "user_input_error"]
    pred = ["cloud_outage", "unknown", None, "cloud_outage"]
    s = score(gold, pred)
    assert (s.correct, s.invalid, s.accuracy) == (2, 1, 0.5)
    assert s.confusion["unknown"]["invalid"] == 1
    assert s.per_class["cloud_outage"]["precision"] == 0.5
    assert s.per_class["unknown"]["recall"] == 0.5


def test_prompt_version_is_frozen():
    # Changing the prompt invalidates comparisons; update deliberately and say so in the report.
    assert PROMPT_VERSION == PROMPT_VERSION_EXPECTED


PROMPT_VERSION_EXPECTED = "20f64f2540e2"
