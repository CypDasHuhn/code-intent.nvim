#!/usr/bin/env sh
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)"
. "$dir/scripts/engine-env.sh"
trap engine_env_cleanup EXIT INT TERM
engine_env_resolve

if [ ! -x "$CINT_SERVER_BIN" ]; then
  echo "FAIL: cint-server is not installed at $CINT_SERVER_BIN" >&2
  echo "Run 'just release' in the engine repo and set CINT_ENGINE_ARTIFACT, or run 'just install' for a local checkout" >&2
  exit 2
fi
if [ ! -f "$CINT_PROTOCOL_SCHEMA" ]; then
  echo "FAIL: engine protocol schema is missing at $CINT_PROTOCOL_SCHEMA" >&2
  exit 2
fi

echo "Checking code-intent.nvim protocol pin against $CINT_PROTOCOL_SCHEMA and $CINT_SERVER_BIN"
CINT_REQUIRE_SERVER=1 nvim --headless -u "$dir/tests/minimal_init.lua" -l "$dir/tests/schema_pin_spec.lua"
CINT_REQUIRE_SERVER=1 nvim --headless -u "$dir/tests/minimal_init.lua" -l "$dir/tests/v2_server_spec.lua"
