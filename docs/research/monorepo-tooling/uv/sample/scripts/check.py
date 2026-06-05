#!/usr/bin/env -S uv run --script
# A PEP 723 inline-script "task": `uv run scripts/check.py` resolves the
# embedded dependency in an ephemeral environment, independent of the workspace.
# /// script
# requires-python = ">=3.12"
# dependencies = ["tqdm>=4,<5"]
# ///
"""Standalone workspace smoke-check task driven by `uv run`."""

from tqdm import tqdm


def main() -> None:
    for _ in tqdm(range(3), desc="checking workspace"):
        pass
    print("ok")


if __name__ == "__main__":
    main()
