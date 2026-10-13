"""Harness preparation ceiling, separate from production runtime deadlines."""
# Explicit local tarball npm exec resolves its manifest by extraction on every call.
NPM_PREPARATION_TIMEOUT = 120
