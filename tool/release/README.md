# Release bundle wrapper

`tool/release_bundles.py` prepares seven local release assets. It never publishes,
changes a tag, downloads dependencies, or certifies the release gates. Run it
with Python 3.11+ from any working directory, using absolute input paths:

```sh
python /path/to/tool/release_bundles.py \
  --source /path/to/clean-final-source \
  --expected-commit FULL_FINAL_COMMIT \
  --transports /path/to/transports \
  --packed /path/to/packed \
  --guide /path/to/tool/release/QUICKSTART.txt \
  --ci-evidence /path/to/reviewed-ci-evidence \
  --output /path/to/fresh-release
```

`transports` contains `linux-x64`, `macos-arm64`, `windows-x64` directories,
each with the original `installation.tar` and `provenance.json`. `packed`
contains the original npm tgz, `npm-pack.json`, `packed-evidence.json`, and
optional recorded runtime versions. The optional `ci-evidence` directory should
contain the verified workflow run identity and original job/installed-route
reports. Those are preserved verbatim, not interpreted as proof of success by
this wrapper. Inputs must be ordinary files, with no symbolic-link aliases.

The wrapper reuses the bounded CI transport validator and pack verifier,
reconstructs the expected npm stage from the exact clean source, verifies every
payload, adds tracked schemas, a guide, a version/hash manifest, and the source
LICENSE if present, and verifies final archive bytes/modes. Native archive roots
contain `bin/`, `native/`, `assets/`, `schemas/`, `README.txt`, `manifest.json`,
and `LICENSE` for licensed source. The npm tgz and original CI evidence are never
rewritten. Outputs appear only after verification; existing outputs are refused.

Before publication, separately verify the source includes the approved LICENSE,
all source and release metadata agree, the tag names this source, the source's
actual workflow succeeded, all required installed-route jobs passed, and final
native bundles were extracted and executed on the actual three target hosts.
The Linux-only local wrapper test does not establish macOS/Windows execution,
signing/notarization, Windows 11 support, or registry availability.

`python test/release_bundle_process_test.py` uses actual historical CI artifacts
when the sibling `combine-pack-evidence` and `archway-transport-source` fixtures
exist. Otherwise it explicitly skips. Its old commit is a packaging regression
fixture, never final-source release proof. It checks hashes/modes/layout,
preserved proof, rehashed malicious tar rejection, aliases, wrong source,
existing-output refusal, and relocated Linux policy execution without runtimes.

## Final archive CI gate

Run [the package-delivery workflow](../../.github/workflows/package-delivery-probe.yml)
with `workflow_dispatch` at the exact final source commit. Its `release-native`
job extracts and executes the prepared native archives on Ubuntu 24.04 x64,
macOS 15 arm64, and Windows Server 2025 x64 via
[`release_native_smoke.py`](../ci/release_native_smoke.py). The `release-finalize`
job requires those jobs plus the npm and pub installed-route matrices, binds
receipts to the source/run and tested artifacts, and retains `release-ready`
files without rebuilding the tested native archives or publishing them.
Inspect the actual run and retained reports before treating any gate as passed;
workflow wiring and local tests alone do not establish target-host acceptance.
