# Repository-wide DCM metrics

Run from the repository root, with Dart, Git, and DCM on PATH:

```bash
dart run tool/dcm_metrics/check_metrics.dart
```

`--root=PATH` selects a Git root (default: working directory), `--dcm=PATH` an
executable or `.dart` wrapper, and `--timeout-seconds=N` a positive per-process
timeout including output drainage (default 120). `--help` prints usage.

The runner inventories tracked and non-ignored untracked Dart files; keep sources
unchanged during the scan. Candidates may be excluded by DCM's policy in
[analysis_options.yaml](../../analysis_options.yaml). Only analyzed-line-limit
rejection triggers partitioning into directories or files.

After successful preflight, the printed temporary directory holds attempt logs
and `summary.json`: inventory, scope tree, completion, and deduplicated violations.
Exit `0` means complete and clean, `1` complete with violations, and `2` incomplete
(single file over the limit, tool failure, unknown output, or invalid invocation).
Preflight failure prints to stderr without creating a report.

Thresholds for Dart metrics are configured in the root
[analysis_options.yaml](../../analysis_options.yaml). Flutter widget metrics are
not enabled. DCM must resolve this configuration; an unconfigured DCM run skips
metric analysis even when its console output says no violations were found.

Owning behavioral evidence: `dart test test/dcm_metrics_test.dart`.
