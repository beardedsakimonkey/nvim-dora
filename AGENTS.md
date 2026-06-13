# Repository Notes

- Run the full smoke suite with `./scripts/smoke.sh`.
- When running the smoke suite from Codex, use sandbox escalation. Neovim's
  filesystem watchers may repeatedly fire inside the sandbox and stall the run.
- Regenerate README config docs with `PANVIMDOC_DIR=~/code/panvimdoc ./scripts/docs.sh`.
- For ad hoc headless Neovim checks, set `NVIM_LOG_FILE=/dev/null` to avoid creating `nvim.log` in the repo and use `set noswapfile` to prevent swap-file errors.
