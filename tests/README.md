# Tests

Integration tests for The Council scripts. No framework — just bash scripts. Most lanes run against PATH-injected fakes in `fixtures/` (fake codex / agy / gemini / curl), so they need no network and spend nothing; `test_gemini_invocation.sh` still drives the real `agy`.

`test_openrouter_seats.sh` covers the 1.6.0 OpenRouter seat lane end to end with `fixtures/fake-curl.sh` (SSE stream, starvation, error envelope, timeout salvage, key hygiene, live-listing resolution and its fallbacks).

## Prerequisites
- `agy` CLI 1.0.2+ installed and authenticated
- `bash` 4+, `mktemp`, `grep`

## Run

    bash tests/test_gemini_invocation.sh

Each test creates and cleans up its own tempdir under `$TMPDIR`. Tests are slow (each one invokes `agy --print` end-to-end, ~30-90s per run).
