#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DORA_DOCS_CHECK=1 \
NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set rtp^=$PWD" \
  -c "luafile scripts/docs.lua" \
  -c "qa"

NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set rtp^=$PWD" \
  -c "runtime plugin/dora.lua" \
  -c "luafile scripts/smoke.lua" \
  -c "qa"
