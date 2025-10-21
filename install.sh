#!/usr/bin/env bash
set -euo pipefail

cargo build --release

# 将产物复制到当前仓库的 lib/ 目录，由插件在 runtimepath 中查找
rm lib -rf
mkdir -p lib
cp target/release/ts-hl-daemon lib/

echo "Installed to ./lib. Ensure this plugin directory is on 'runtimepath'."
