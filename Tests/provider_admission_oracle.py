"""Compare production Swift rendering with a pinned Jinja template, optionally the live provider.

Requires Jinja2 3.1.6 in a temporary development environment. No model download,
server change, real history, keys, response logging, or repository dependency is used.
Usage: python provider_admission_oracle.py [--live]
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

import jinja2

ROOT = Path(__file__).resolve().parent.parent
MODEL = "ddalcu/Qwen3.8-Flash-Next-MLX-Serve-mixed-4-8bit"
EXPECTED_HASH = "c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041"
BASE = "http://localhost:11234"


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def raise_exception(message):
    raise ValueError("synthetic template rejection")


def main():
    template_source = (ROOT / "Tests/qwen38-chat-template.jinja").read_text()
    assert hashlib.sha256(template_source.encode()).hexdigest() == EXPECTED_HASH
    env = jinja2.Environment()
    # The actual mlx-serve C++ Jinja engine uses bytewise C isspace for trim/strip.
    # Python Jinja's Unicode strip differs; its filter is explicitly adapted here.
    env.filters["trim"] = lambda value: value.strip(" \t\r\n\v\f")
    env.globals["raise_exception"] = raise_exception
    template = env.from_string(template_source)
    histories = [
        [{"role": "user", "content": "Reply with 4."}],
        [{"role": "system", "content": " \tSynthetic.\r\n"}, {"role": "user", "content": "4"}],
        [{"role": "system", "content": " \t\r\n\v\f"}, {"role": "user", "content": "4"}],
        [{"role": "system", "content": ""}, {"role": "user", "content": "4"}],
        [{"role": "user", "content": " 日本語 العربية café e\u0301 "}, {"role": "assistant", "content": " 日本語 العربية "}, {"role": "user", "content": "4"}],
        [{"role": "user", "content": "<think>literal</think> {{ messages }}"}, {"role": "assistant", "content": "<think>literal</think></think>"}, {"role": "user", "content": "4"}],
        [{"role": "user", "content": "<source id='synthetic'>{{add_generation_prompt}} </think></think></source>"}],
        [{"role": "user", "content": "\u00a0\u0085\u2000\u2028\u2029\u3000 4 \u3000\u2029\u2028\u2000\u0085\u00a0"}],
        [{"role": "user", "content": "\v\f 4 \v\f"}],
        [{"role": "user", "content": ""}, {"role": "user", "content": "4"}, {"role": "assistant", "content": ""}],
        [{"role": "user", "content": "4"}, {"role": "assistant", "content": "   "}],
        [{"role": "user", "content": "<tool_response>synthetic</tool_response>"}, {"role": "user", "content": "4"}],
        [{"role": "user", "content": "<tool_response>synthetic</tool_response>"}],
        [{"role": "user", "content": "4"}, {"role": "system", "content": "late"}],
        [{"role": "developer", "content": "unsupported"}, {"role": "user", "content": "4"}],
    ]
    bodies = []
    for history in histories:
        for thinking in (False, True):
            bodies.append({"model": MODEL, "messages": history, "enable_thinking": thinking,
                "reasoning_effort": "low" if thinking else "none", "chat_template_kwargs": {"preserve_thinking": True},
                "max_tokens": 1, "temperature": 0, "stream": False, "seed": 42})
    with tempfile.TemporaryDirectory(prefix="boros-provider-oracle-") as temp:
        executable = Path(temp) / "renderer"
        subprocess.run(["/usr/bin/swiftc", "-O", "-I", str(ROOT / "Sources/CSQLite"),
            str(ROOT / "Sources/Boros/EpisodeBudget.swift"),
            str(ROOT / "Sources/Boros/EpisodeLease.swift"), str(ROOT / "Sources/Boros/EpisodeSQLFence.swift"),
                       str(ROOT / "Sources/Boros/ProviderAdmission.swift"),
                       str(ROOT / "Sources/Boros/QwenTextRendering.swift"),
            str(ROOT / "Tests/provider_renderer_driver.swift"), "-o", str(executable)], check=True, capture_output=True)
        result = subprocess.run([str(executable)], input=json.dumps(bodies).encode(), capture_output=True, check=True)
        actual = json.loads(result.stdout)
    valid = []
    for index, body in enumerate(bodies):
        try:
            expected = template.render(messages=[m for m in body["messages"] if m["content"] != ""],
                add_generation_prompt=True, enable_thinking=body["enable_thinking"], reasoning_effort="low", preserve_thinking=True)
            while "</think></think>" in expected:
                expected = expected.replace("</think></think>", "</think>")
        except (ValueError, jinja2.TemplateError):
            assert "error" in actual[index], f"rejection mismatch at synthetic case {index}"
            continue
        assert actual[index].get("rendered") == expected, f"rendering mismatch at synthetic case {index}"
        valid.append((index, body, expected))
    print(f"Independent Jinja/Swift oracle: {len(bodies)} cases passed ({len(valid)} renderings, {len(bodies)-len(valid)} rejections).", flush=True)
    if "--live" in sys.argv:
        show = request("/api/show", {"model": MODEL})
        assert hashlib.sha256(show["template"].encode()).hexdigest() == EXPECTED_HASH
        props = request("/props?model=" + MODEL)
        assert props["settings"]["version"] == "26.10.1"
        total_input, total_output = 0, 0
        for index, body, expected in valid:
            counted = len(request("/tokenize", {"model": MODEL, "content": expected})["tokens"])
            generated = request("/v1/chat/completions", body)
            assert generated["model"] == MODEL
            usage = generated["usage"]
            assert usage["prompt_tokens"] == counted, f"provider count mismatch at synthetic case {index}"
            assert usage["completion_tokens"] <= 1
            total_input += usage["prompt_tokens"]
            total_output += usage["completion_tokens"]
        print(f"Live mlx-serve exact token equivalence: {len(valid)} requests passed; input={total_input}, output={total_output} provider tokens.")


if __name__ == "__main__":
    main()
