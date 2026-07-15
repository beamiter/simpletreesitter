#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$repo_dir"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo was not found; install Rust 1.85+ first" >&2
  exit 1
fi

cargo build --release --locked

binary="target/release/ts-hl-daemon"
if [[ -f "${binary}.exe" ]]; then
  binary="${binary}.exe"
fi
if [[ ! -f "$binary" ]]; then
  echo "error: build completed but $binary was not produced" >&2
  exit 1
fi

# 只原子替换 daemon，保留 lib/ 中可能存在的其它文件。
mkdir -p lib
destination="lib/$(basename -- "$binary")"
temporary="${destination}.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT
install -m 0755 -- "$binary" "$temporary"
mv -f -- "$temporary" "$destination"
trap - EXIT

echo "Installed $destination"
