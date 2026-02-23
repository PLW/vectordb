#!/usr/bin/env python3

# Generated (ChatGPT 5.2) from : prompts/base_prompt

from __future__ import annotations

import argparse
import pathlib
import re
from typing import List

from openai import OpenAI


CPP_SYSTEM = """You are a senior C++ engineer.
Generate production-quality C++ source code for a repository.
Hard rules:
- Output ONLY the code for a single .cpp file (no markdown, no backticks, no commentary).
- The file must compile as C++17 (unless the prompt explicitly requires otherwise).
- Prefer small, clear APIs; avoid unnecessary dependencies.
- Include any necessary #includes.
- Do NOT assume external libraries beyond the C++ standard library unless the prompt explicitly names them.
- If you need to define a public interface, keep it in the .cpp file (no new headers) unless the prompt explicitly requests headers.
"""

GTEST_SYSTEM = """You are a senior C++ test engineer.
Write GoogleTest unit tests for the provided C++ source file.
Hard rules:
- Output ONLY the code for a single *_test.cpp file (no markdown, no backticks, no commentary).
- Use <gtest/gtest.h>.
- Tests must be deterministic and fast.
- If the source file provides no directly testable functions/classes, add minimal test hooks ONLY if they can be added without changing external behavior; otherwise write compilation/smoke tests.
- Avoid global state and flaky timing assumptions.
"""


def sanitize_stem(stem: str) -> str:
    stem = stem.strip()
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem)
    return stem or "generated"


def read_text(p: pathlib.Path) -> str:
    return p.read_text(encoding="utf-8")


def write_text(p: pathlib.Path, s: str) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(s, encoding="utf-8")


def list_prompt_files(prompt_dir: pathlib.Path) -> List[pathlib.Path]:
    files = []
    for ext in ("*.txt", "*.md", "*.prompt"):
        files.extend(sorted(prompt_dir.glob(ext)))
    # stable unique ordering
    seen = set()
    out = []
    for f in files:
        if f.resolve() not in seen and f.is_file():
            out.append(f)
            seen.add(f.resolve())
    return out


def call_model(client: OpenAI, model: str, system: str, user: str) -> str:
    resp = client.responses.create(
        model=model,
        input=[
            {
                "role": "system",
                "content": [{"type": "input_text", "text": system}],
            },
            {
                "role": "user",
                "content": [{"type": "input_text", "text": user}],
            },
        ],
        # Keep output more deterministic; adjust if you want more creativity:
        temperature=0.2,
    )
    return (resp.output_text or "").strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--new-name", required=True)
    ap.add_argument("--prompt-dir", required=True)
    ap.add_argument("--src-dir", required=True)
    ap.add_argument("--test-dir", required=True)
    ap.add_argument("--model", default="gpt-5.2")
    args = ap.parse_args()

    prompt_dir = pathlib.Path(args.prompt_dir)
    src_dir = pathlib.Path(args.src_dir)
    test_dir = pathlib.Path(args.test_dir)

    prompts = list_prompt_files(prompt_dir)
    if not prompts:
        raise SystemExit(f"No prompt files found in {prompt_dir}")

    client = OpenAI()

    for pf in prompts:
        stem = sanitize_stem(pf.stem)
        cpp_path = src_dir / f"{stem}.cpp"
        test_path = test_dir / f"{stem}_test.cpp"

        prompt_text = read_text(pf)

        # 1) Generate the .cpp from the prompt file
        user_cpp = f"""Repository module: {args.new_name}
Prompt file: {pf.name}

TASK:
{prompt_text}

OUTPUT:
Generate the single C++ implementation file {cpp_path.as_posix()}.
"""
        cpp_code = call_model(client, args.model, CPP_SYSTEM, user_cpp)
        if not cpp_code:
            raise SystemExit(f"Model returned empty C++ for {pf}")

        write_text(cpp_path, cpp_code)

        # 2) Generate gtest for that .cpp (one per object file)
        user_test = f"""Repository module: {args.new_name}
Source file path: {cpp_path.as_posix()}

SOURCE CODE:
{cpp_code}

OUTPUT:
Generate the single GoogleTest file {test_path.as_posix()} that tests the above source.
"""
        test_code = call_model(client, args.model, GTEST_SYSTEM, user_test)
        if not test_code:
            raise SystemExit(f"Model returned empty tests for {pf}")

        write_text(test_path, test_code)

        print(f"Generated: {cpp_path} and {test_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

