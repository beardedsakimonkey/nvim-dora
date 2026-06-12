#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

DORA_DOCS_CHECK=1 \
NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set noswapfile" \
  -c "set rtp^=$PWD" \
  -c "lua local ok, err = xpcall(function() dofile('scripts/docs.lua') end, debug.traceback); if not ok then vim.api.nvim_err_writeln(err); vim.cmd.cquit() end" \
  -c "qa"

NVIM_LOG_FILE="${TMPDIR:-/tmp}/dora-nvim.log" \
nvim --headless -u NONE -i NONE --noplugin \
  -c "set noswapfile" \
  -c "set rtp^=$PWD" \
  -c "runtime plugin/dora.lua" \
  -c "lua local ok, err = xpcall(function() dofile('scripts/smoke.lua') end, debug.traceback); if not ok then vim.api.nvim_err_writeln(err); vim.cmd.cquit() end" \
  -c "qa"
