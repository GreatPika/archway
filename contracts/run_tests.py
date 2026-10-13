"""Run finite specification conformance checks; does not run Archway or compilers."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
COMMANDS = [
    "json/verify_contract.py",
    "json/test_entrypoint_oracle.py",
    "assignment/verify.py",
    "compatibility/test_lexical_reference.py",
    "helper/test_contract.py",
    "regressions/test_cross_contract.py",
    "regressions/test_entrypoints.py",
]


def helper_fixtures():
    return {path: path.read_bytes() for path in (ROOT / "helper/fixtures").glob("*.json")}


def verify_manifest(root):
    inventory = json.loads((root / "manifest.json").read_text())["files"]
    actual = {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*")
        if path.is_file() and path != root / "manifest.json"
        and "__pycache__" not in path.relative_to(root).parts
        and path.suffix != ".pyc"
    }
    errors = [f"unlisted file: {name}" for name in sorted(actual.keys() - inventory.keys())]
    errors += [f"missing file: {name}" for name in sorted(inventory.keys() - actual.keys())]
    errors += [f"hash mismatch: {name}" for name in sorted(actual.keys() & inventory.keys())
               if actual[name] != inventory[name]]
    return errors


def main():
    try:
        errors = verify_manifest(ROOT)
    except (OSError, ValueError, KeyError, TypeError) as error:
        errors = [str(error)]
    if errors:
        print("Contract manifest failed: " + "; ".join(errors), file=sys.stderr)
        return 1
    fixture_snapshot = helper_fixtures()
    failed = []
    for command in COMMANDS:
        print(f"\n=== {command} ===", flush=True)
        result = subprocess.run([sys.executable, command], cwd=ROOT)
        if result.returncode:
            failed.append(command)
    if helper_fixtures() != fixture_snapshot:
        failed.append("helper fixtures changed during contract checks")
    if failed:
        print("Failed: " + ", ".join(failed), file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
