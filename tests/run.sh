#!/usr/bin/env sh
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$dir"
for spec in live_spec render_spec annotations_spec config_spec; do
  nvim --headless -u "$dir/tests/minimal_init.lua" -l "$dir/tests/$spec.lua"
done
