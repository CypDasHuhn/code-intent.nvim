#!/usr/bin/env sh
set -eu
dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$dir"
nvim --headless -u "$dir/tests/minimal_init.lua" -l "$dir/tests/render_spec.lua"
