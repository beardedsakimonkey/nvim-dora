#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

check=false
if [ "${1:-}" = "--check" ]; then
  check=true
  export DORA_DOCS_CHECK=1
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "usage: sh scripts/docs.sh [--check]" >&2
  exit 2
fi

NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set rtp^=$PWD" \
  -c "luafile scripts/docs.lua" \
  -c "qa"

if $check; then
  sh scripts/vimdoc.sh --check
else
  sh scripts/vimdoc.sh
fi
