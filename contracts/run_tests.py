"""Run finite specification conformance checks; does not run Archway or compilers."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
COMMANDS = [
    "json/verify_contract.py",
    "json/test_entrypoint_oracle.py",
    "assignment/verify.py",
    "compatibility/test_lexical_reference.py",
    "helper/test_contract.py",
    "independent/probe.py",
    "independent-entrypoints/probe.py",
]


def helper_fixtures():
    return {path: path.read_bytes() for path in (ROOT / "helper/fixtures").glob("*.json")}


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
sys.exit(1 if failed else 0)
