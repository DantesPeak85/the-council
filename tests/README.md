# Tests

Integration tests for The Council scripts. No framework — just bash scripts that run end-to-end against the real `codex` and `agy` CLIs.

## Prerequisites
- `agy` CLI 1.0.2+ installed and authenticated
- `bash` 4+, `mktemp`, `grep`

## Run

    bash tests/test_gemini_invocation.sh

Each test creates and cleans up its own tempdir under `$TMPDIR`. Tests are slow (each one invokes `agy --print` end-to-end, ~30-90s per run).
