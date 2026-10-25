#!/usr/bin/env sh
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$dir"
. "$dir/scripts/engine-env.sh"
trap engine_env_cleanup EXIT INT TERM
engine_env_resolve
CINT_REQUIRE_SERVER="${CINT_REQUIRE_SERVER:-1}"
export CINT_REQUIRE_SERVER
for spec in protocol_spec schema_pin_spec live_spec render_spec annotations_spec labels_spec hover_spec stripes_spec config_spec display_spec candidates_spec review_spec v2_server_spec; do
  nvim --headless -u "$dir/tests/minimal_init.lua" -l "$dir/tests/$spec.lua"
done
