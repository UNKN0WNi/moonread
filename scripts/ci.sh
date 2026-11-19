#!/usr/bin/env bash
# MoonRead 本地 / CI 主流程：格式、四端编译、四端测试、跨端一致性、JSON 与语料自检。
set -euo pipefail
cd "$(dirname "$0")/.."

export TOOLCHAIN_ENV_QUIET=1
source scripts/toolchain-env.sh

step() { printf '\n=== %s ===\n' "$1"; }

step "moon fmt --check"
moon fmt --check

for target in native js wasm wasm-gc; do
  step "moon check --target $target --deny-warn"
  moon check --target "$target" --deny-warn

  step "moon test --target $target"
  moon test --target "$target"

  step "moon build --target $target"
  moon build --target "$target"
done

step "native / js / wasm-gc 输出一致性"
bash scripts/cross_target.sh

step "严格 JSON 自检"
python3 tools/validate_json.py

step "语料 manifest 自检"
python3 tools/corpus_check.py --require-manifest --skip-missing-books

step "完成"
