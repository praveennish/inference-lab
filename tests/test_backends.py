"""Backends against fake HTTP servers: the request we send and how we read the reply.

No network: the Anthropic SDK runs over httpx2.MockTransport, the OpenAI-compatible backend
over httpx.MockTransport. Response bodies follow the documented wire formats.
"""

import json

import anthropic
import httpx
import httpx2
import pytest

from bench.classify.backends import AnthropicBackend, OpenAICompatBackend
from bench.classify.dataset import LABELS, Example
from bench.classify.prompt import SYSTEM_PROMPT

EXAMPLE = Example(
    "cls-x", "error_code: S3.SlowDown\nattempt: 1\nmessage: slow down", "cloud_outage"
)


def anthropic_reply(text: str, stop_reason: str = "end_turn") -> dict:
    return {
        "id": "msg_test",
        "type": "message",
        "role": "assistant",
        "model": "claude-opus-5-5",
        "content": [{"type": "text", "text": text}] if text else [],
        "stop_reason": stop_reason,
        "stop_sequence": None,
        "usage": {"input_tokens": 400, "output_tokens": 50},
    }


def make_anthropic(reply: dict, seen: list) -> AnthropicBackend:
    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(json.loads(request.content))
        return httpx2.Response(200, json=reply)

    client = anthropic.Anthropic(
        api_key="test-not-a-key",
        http_client=httpx2.Client(transport=httpx2.MockTransport(handler)),
        max_retries=0,
    )
    return AnthropicBackend("claude-opus-5-5", effort="low", client=client)


def test_anthropic_request_shape_and_cost():
    seen: list = []
    p = make_anthropic(anthropic_reply('{"label": "cloud_outage"}'), seen).classify(EXAMPLE)
    body = seen[0]
    assert body["model"] == "claude-opus-5-5"
    assert body["system"] == SYSTEM_PROMPT
    assert body["output_config"]["effort"] == "low"
    schema = body["output_config"]["format"]["schema"]
    assert schema["properties"]["label"]["enum"] == list(LABELS)
    # These models reject sampling parameters; a fallback model would hide refusals.
    assert not {"temperature", "top_p", "top_k", "fallbacks", "thinking"} & body.keys()
    assert (p.label, p.input_tokens, p.output_tokens) == ("cloud_outage", 400, 50)
    assert p.cost_usd == pytest.approx((400 * 4.0 + 50 * 20.0) / 1e6)


def test_anthropic_refusal_is_recorded_not_parsed():
    p = make_anthropic(anthropic_reply("", stop_reason="refusal"), []).classify(EXAMPLE)
    assert p.label is None and p.stop_reason == "refusal"


def test_anthropic_http_error_is_recorded_per_example():
    def handler(request: httpx2.Request) -> httpx2.Response:
        return httpx2.Response(
            400, json={"type": "error", "error": {"type": "invalid_request_error", "message": "x"}}
        )

    client = anthropic.Anthropic(
        api_key="test-not-a-key",
        http_client=httpx2.Client(transport=httpx2.MockTransport(handler)),
        max_retries=0,
    )
    p = AnthropicBackend("claude-opus-5-5", client=client).classify(EXAMPLE)
    assert p.label is None and "BadRequestError" in p.error


def make_openai(content: str, seen: list, constrained: bool = False, status: int = 200):
    def handler(request: httpx.Request) -> httpx.Response:
        seen.append((request.url.path, json.loads(request.content)))
        return httpx.Response(
            status,
            json={
                "choices": [{"message": {"content": content}, "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 210, "completion_tokens": 4},
            },
        )

    return OpenAICompatBackend(
        "http://fake:8000/",
        "qwen",
        "fake",
        constrained=constrained,
        http_client=httpx.Client(transport=httpx.MockTransport(handler)),
    )


def test_openai_request_is_greedy_seeded_and_same_prompt():
    seen: list = []
    p = make_openai("cloud_outage", seen).classify(EXAMPLE)
    path, body = seen[0]
    assert path == "/v1/chat/completions"
    assert body["messages"][0] == {"role": "system", "content": SYSTEM_PROMPT}
    assert (body["temperature"], body["seed"], body["max_tokens"]) == (0, 1234, 16)
    assert "structured_outputs" not in body
    assert (p.label, p.input_tokens, p.output_tokens, p.stop_reason) == (
        "cloud_outage",
        210,
        4,
        "stop",
    )


def test_openai_constrained_mode_restricts_choices():
    seen: list = []
    make_openai("unknown", seen, constrained=True).classify(EXAMPLE)
    assert seen[0][1]["structured_outputs"] == {"choice": list(LABELS)}


def test_openai_unparseable_and_http_errors():
    assert make_openai("I think it is a network thing", []).classify(EXAMPLE).label is None
    p = make_openai("", [], status=500).classify(EXAMPLE)
    assert p.label is None and "HTTPStatusError" in p.error
