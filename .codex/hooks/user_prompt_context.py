#!/usr/bin/env python3
"""Inject the repository's research and grilling workflow into each turn."""

import json


POLICY = (
    "Before answering a repository question, identify the facts needed for a "
    "reliable answer. Verify missing facts with one or more focused "
    "`codebase_researcher` agents; investigate independent gaps in parallel "
    "and follow up if needed. Never ask the user for facts you can find "
    "yourself. If material facts remain unverified, state the gap instead of "
    "guessing. Ask the user only for decisions or information you cannot "
    "obtain. When the task needs user decisions, use `$grilling` to map the "
    "decision tree and ask all currently answerable questions in one round."
)


def main() -> None:
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "UserPromptSubmit",
                    "additionalContext": POLICY,
                }
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
