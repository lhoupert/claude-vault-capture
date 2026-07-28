"""Regression tests for _invoke_via_subscription against a fake claude_agent_sdk.

W30 lost 4 paid responses to the SDK surfacing the CLI's error result as an
exception: 3x "Reached maximum number of turns (1)" and 1x a non-zero exit
whose result text was literally "success". These pin the two mitigations:
a max_turns buffer > 1, and salvaging reply text that streamed before the
error instead of discarding it.
"""

import sys
import types
from dataclasses import dataclass, field

import pytest

import curate


@dataclass
class _TextBlock:
    text: str


@dataclass
class _AssistantMessage:
    content: list = field(default_factory=list)


@dataclass
class _ResultMessage:
    usage: dict | None = None


class _CapturedOptions:
    last_kwargs: dict = {}

    def __init__(self, **kwargs):
        _CapturedOptions.last_kwargs = kwargs
        self.__dict__.update(kwargs)


def _install_fake_sdk(monkeypatch, messages, error=None):
    """Inject a claude_agent_sdk whose query() yields `messages`, then optionally raises."""

    async def query(*, prompt, options):
        for m in messages:
            yield m
        if error is not None:
            raise error

    fake = types.ModuleType("claude_agent_sdk")
    fake.query = query
    fake.ClaudeAgentOptions = _CapturedOptions
    fake.AssistantMessage = _AssistantMessage
    fake.TextBlock = _TextBlock
    fake.ResultMessage = _ResultMessage
    monkeypatch.setitem(sys.modules, "claude_agent_sdk", fake)


def test_clean_run_returns_text_and_tokens(monkeypatch):
    _install_fake_sdk(
        monkeypatch,
        [
            _AssistantMessage(content=[_TextBlock('{"title": "x"}')]),
            _ResultMessage(
                usage={
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 30,
                    "output_tokens": 7,
                }
            ),
        ],
    )
    text, tokens_in, tokens_out = curate._invoke_via_subscription(
        "claude-sonnet-4-6", "system", "transcript"
    )
    assert text == '{"title": "x"}'
    assert tokens_in == 60
    assert tokens_out == 7


def test_max_turns_leaves_headroom(monkeypatch):
    """max_turns=1 turned any pre-reply turn (e.g. an attempted tool call) into
    error_max_turns and a lost response — the buffer must stay above 1."""
    _install_fake_sdk(monkeypatch, [_AssistantMessage(content=[_TextBlock("null")])])
    curate._invoke_via_subscription("claude-sonnet-4-6", "system", "transcript")
    assert _CapturedOptions.last_kwargs["max_turns"] > 1
    assert _CapturedOptions.last_kwargs["allowed_tools"] == []


def test_error_after_streamed_reply_is_salvaged(monkeypatch):
    _install_fake_sdk(
        monkeypatch,
        [_AssistantMessage(content=[_TextBlock('{"title": "kept"}')])],
        error=Exception(
            "Claude Code returned an error result: Reached maximum number of turns (4)"
        ),
    )
    text, _, _ = curate._invoke_via_subscription(
        "claude-sonnet-4-6", "system", "transcript"
    )
    assert text == '{"title": "kept"}'


def test_error_before_any_reply_still_raises(monkeypatch):
    _install_fake_sdk(
        monkeypatch,
        [],
        error=Exception("Claude Code returned an error result: success"),
    )
    with pytest.raises(Exception, match="error result"):
        curate._invoke_via_subscription("claude-sonnet-4-6", "system", "transcript")
