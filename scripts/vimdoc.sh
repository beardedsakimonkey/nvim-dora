#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
root=$PWD
check=false

if [ "${1:-}" = "--check" ]; then
  check=true
  shift
fi

if [ "$#" -ne 0 ]; then
  echo "usage: sh scripts/vimdoc.sh [--check]" >&2
  exit 2
fi

panvimdoc=${PANVIMDOC:-}
if [ -z "$panvimdoc" ] && [ -n "${PANVIMDOC_DIR:-}" ]; then
  panvimdoc=$PANVIMDOC_DIR/panvimdoc.sh
fi
if [ -z "$panvimdoc" ]; then
  panvimdoc=$(command -v panvimdoc.sh || true)
fi
if [ ! -x "$panvimdoc" ]; then
  echo "panvimdoc.sh not found; set PANVIMDOC or PANVIMDOC_DIR" >&2
  exit 1
fi
panvimdoc_dir=$(cd "$(dirname "$panvimdoc")" && pwd)
panvimdoc=$panvimdoc_dir/$(basename "$panvimdoc")

pandoc=${PANDOC:-$(command -v pandoc || true)}
if [ ! -x "$pandoc" ]; then
  echo "pandoc 3.0+ not found; set PANDOC or add pandoc to PATH" >&2
  exit 1
fi
pandoc_major=$("$pandoc" --version | sed -n '1s/^pandoc \([0-9][0-9]*\).*/\1/p')
if [ -z "$pandoc_major" ] || [ "$pandoc_major" -lt 3 ]; then
  echo "panvimdoc requires pandoc 3.0+" >&2
  exit 1
fi
PATH=$(dirname "$pandoc"):$PATH
export PATH

tmp=$(mktemp -d "${TMPDIR:-/tmp}/nvim-dora-vimdoc.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/doc"

(
  cd "$tmp"
  "$panvimdoc" \
    --project-name dora \
    --input-file "$root/README.md" \
    --vim-version "Neovim 0.12+" \
    --toc true \
    --description "Directory explorer for Neovim" \
    --dedup-subheadings true \
    --treesitter true \
    --ignore-rawblocks true \
    --doc-mapping false \
    --doc-mapping-project-name true \
    --shift-heading-level-by 0 \
    --increment-heading-level-by 0 \
    --scripts-dir "$panvimdoc_dir/scripts"
)

if $check; then
  if ! cmp -s "$tmp/doc/dora.txt" "$root/doc/dora.txt"; then
    echo "doc/dora.txt is stale. Run: sh scripts/docs.sh" >&2
    exit 1
  fi
else
  mkdir -p "$root/doc"
  cp "$tmp/doc/dora.txt" "$root/doc/dora.txt"
fi
