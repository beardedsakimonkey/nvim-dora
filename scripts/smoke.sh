#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DORA_DOCS_CHECK=1 \
DORA_TEST_FILE=scripts/docs.lua \
NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set noswapfile" \
  -c "set rtp^=$PWD" \
  -c "luafile scripts/run-headless.lua" \
  -c "qa"

DORA_TEST_FILE=scripts/smoke.lua \
NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set noswapfile" \
  -c "set rtp^=$PWD" \
  -c "runtime plugin/dora.lua" \
  -c "luafile scripts/run-headless.lua" \
  -c "qa"
