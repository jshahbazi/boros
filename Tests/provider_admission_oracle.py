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
JSON_CONTRACT = "mlx-serve-qwen38-json-object-v1"
JSON_INSTRUCTION_HASH = "7291d7ca4c4f2045ce0f23a5ce750792eb630b6bb2541ca69759cd3811a4f14a"
# Independent constant from tagged server.zig:8729-8749, not Swift output.
JSON_INSTRUCTION = "Respond with valid JSON only. No other text, no markdown fences (no ``` or ```json), no explanation. Begin your response with `{` or `[`."


def normalize(value):
    while "</think></think>" in value:
        value = value.replace("</think></think>", "</think>")
    return value


def preprocess(body):
    """Tagged server parsing precedes format injection, which precedes Jinja trim."""
    if "response_format" in body:
        if body["response_format"] != {"type": "json_object"}:
            raise ValueError("unsupported synthetic format")
        # Tagged server can rerender joint JSON/thinking requests using runtime
        # protocol/budget state that the adapter cannot observe. Refuse this mode.
        if body["enable_thinking"]:
            raise ValueError("unverified synthetic JSON thinking mode")
    messages = [dict(message) for message in body["messages"] if message["content"] != ""]
    if not messages:
        raise ValueError("empty synthetic message inventory")
    if "response_format" in body:
        if messages[0]["role"] == "system":
            messages[0]["content"] += "\n\n" + JSON_INSTRUCTION
        else:
            messages.insert(0, {"role": "system", "content": JSON_INSTRUCTION})
    return messages


def oracle_render(template, body):
    labels = body.get("oracle_assignments")
    if labels is not None:
        if len(labels) != len(body["messages"]) or any(label not in ("mandatory", "recent", "evidence") for label in labels):
            raise ValueError("invalid synthetic attribution")
        if any(message["role"] == "system" and label != "mandatory" for message, label in zip(body["messages"], labels)):
            raise ValueError("optional synthetic system")
    rendered = normalize(template.render(messages=preprocess(body), add_generation_prompt=True,
        enable_thinking=body["enable_thinking"], reasoning_effort="low", preserve_thinking=True))
    components = {"recent": "", "evidence": ""}
    if labels is not None:
        # Render historical blocks through Jinja independently. A final sentinel
        # user fixes historical placement and supplies the template's query.
        sentinel = {"role": "user", "content": "ORACLE_FINAL_SENTINEL_74929"}
        suffix = normalize(template.render(messages=[sentinel], add_generation_prompt=False,
            enable_thinking=False, reasoning_effort="low", preserve_thinking=True))
        for message, label in zip(body["messages"], labels):
            if label not in components or message["content"] == "":
                continue
            block = normalize(template.render(messages=[message, sentinel], add_generation_prompt=False,
                enable_thinking=False, reasoning_effort="low", preserve_thinking=True))
            assert block.endswith(suffix), "synthetic attribution sentinel mismatch"
            components[label] += block[:-len(suffix)]
    return rendered, components


def request(path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


def raise_exception(message):
    raise ValueError("synthetic template rejection")


def main():
    assert len(JSON_INSTRUCTION.encode()) == 137
    assert hashlib.sha256(JSON_INSTRUCTION.encode()).hexdigest() == JSON_INSTRUCTION_HASH
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
    pairs = []
    for history in histories:
        for thinking in (False, True):
            original = {"model": MODEL, "messages": history, "enable_thinking": thinking,
                "reasoning_effort": "low" if thinking else "none", "chat_template_kwargs": {"preserve_thinking": True},
                "max_tokens": 1, "temperature": 0, "stream": False, "seed": 42}
            pairs.append((len(bodies), len(bodies) + 1))
            bodies.extend([original, dict(original, response_format={"type": "json_object"})])
    # Historical human and assistant blocks deliberately cross role/allocation
    # boundaries. Injected system bytes must affect neither optional allocation.
    attributed = [
        ([{"role": "system", "content": "Synthetic host  \t\n"},
          {"role": "user", "content": " 日本語 e\u0301 "}, {"role": "assistant", "content": " café </think></think> "},
          {"role": "user", "content": "Synthetic question"}], ["mandatory", "evidence", "recent", "mandatory"]),
        ([{"role": "system", "content": ""}, {"role": "user", "content": ""},
          {"role": "user", "content": "Synthetic history"}, {"role": "assistant", "content": " العربية "},
          {"role": "user", "content": "Synthetic question"}], ["mandatory", "recent", "recent", "evidence", "mandatory"]),
        ([{"role": "system", "content": " \t\r\n\v\f"}, {"role": "user", "content": "Synthetic history"},
          {"role": "assistant", "content": "Synthetic answer"}, {"role": "user", "content": "Synthetic question"}],
         ["mandatory", "evidence", "evidence", "mandatory"]),
    ]
    for history, labels in attributed:
        for thinking in (False, True):
            original = dict(bodies[int(thinking) * 2], messages=history, oracle_assignments=labels)
            pairs.append((len(bodies), len(bodies) + 1))
            bodies.extend([original, dict(original, response_format={"type": "json_object"})])
    unsupported = [None, False, "json_object", [], {}, {"type": None}, {"type": False}, {"type": 1},
        {"type": "json_schema"}, {"type": "text"}, {"type": "JSON_OBJECT"},
        {"type": "json_object", "strict": True}, {"type": "json_object", "json_schema": {}},
        {"type": "json_object", "extra": None}]
    for value in unsupported:
        for thinking in (False, True):
            bodies.append(dict(bodies[int(thinking) * 2], response_format=value))
    for history in ([], [{"role": "system", "content": ""}, {"role": "user", "content": ""}]):
        for thinking in (False, True):
            bodies.append(dict(bodies[int(thinking) * 2], messages=history, response_format={"type": "json_object"}))
    for labels in (["mandatory"], ["evidence", "evidence", "recent", "mandatory"],
                   ["mandatory", "unknown", "recent", "mandatory"]):
        bodies.append(dict(bodies[0], messages=attributed[0][0], oracle_assignments=labels,
            response_format={"type": "json_object"}))
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
        assert actual[index]["json_contract_version"] == JSON_CONTRACT
        assert actual[index]["json_instruction_bytes"] == 137
        assert actual[index]["json_instruction_sha256"] == actual[index]["json_instruction_pin"] == JSON_INSTRUCTION_HASH
        try:
            expected, components = oracle_render(template, body)
        except (ValueError, jinja2.TemplateError):
            assert "error" in actual[index], f"rejection mismatch at synthetic case {index}"
            continue
        assert actual[index].get("rendered") == expected, f"rendering mismatch at synthetic case {index}"
        assert actual[index]["recent"] == components["recent"], f"recent attribution mismatch at synthetic case {index}"
        assert actual[index]["evidence"] == components["evidence"], f"evidence attribution mismatch at synthetic case {index}"
        valid.append((index, body, expected))
    for original, formatted in pairs:
        if "error" not in actual[original] and "error" not in actual[formatted]:
            assert actual[original]["recent"] == actual[formatted]["recent"], "synthetic recent allocation changed"
            assert actual[original]["evidence"] == actual[formatted]["evidence"], "synthetic evidence allocation changed"
            assert actual[original]["rendered"] != actual[formatted]["rendered"], "synthetic injection absent"
    print(f"Independent Jinja/Swift oracle: {len(bodies)} cases passed ({len(valid)} renderings, {len(bodies)-len(valid)} rejections).", flush=True)
    if "--live" in sys.argv:
        show = request("/api/show", {"model": MODEL})
        assert hashlib.sha256(show["template"].encode()).hexdigest() == EXPECTED_HASH
        props = request("/props?model=" + MODEL)
        assert props["settings"]["version"] == "26.10.1"
        total_input, total_output = 0, 0
        for index, body, expected in valid:
            counted = len(request("/tokenize", {"model": MODEL, "content": expected})["tokens"])
            generated = request("/v1/chat/completions", {key: value for key, value in body.items() if key != "oracle_assignments"})
            assert generated["model"] == MODEL
            usage = generated["usage"]
            assert usage["prompt_tokens"] == counted, f"provider count mismatch at synthetic case {index}"
            assert usage["completion_tokens"] <= 1
            total_input += usage["prompt_tokens"]
            total_output += usage["completion_tokens"]
        print(f"Live mlx-serve exact token equivalence: {len(valid)} requests passed; input={total_input}, output={total_output} provider tokens.")


if __name__ == "__main__":
    main()
