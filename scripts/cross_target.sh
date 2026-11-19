#!/usr/bin/env bash
# 同一用例在 native / js / wasm-gc 三端的输出必须逐字节相同。
# 输出保存在项目内的 _build/consistency，便于失败时查看差异。
set -euo pipefail
cd "$(dirname "$0")/.."

export TOOLCHAIN_ENV_QUIET=1
source scripts/toolchain-env.sh

OUT="_build/consistency"
mkdir -p "$OUT"

for target in native js wasm-gc; do
  echo "=== 构建 $target ==="
  moon build --target "$target" >/dev/null
  echo "=== 运行 $target ==="
  moon run --target "$target" apps/embed-demo > "$OUT/out.$target.txt" 2>&1
done

# Windows 下 native 后端输出 CRLF，js / wasm-gc 输出 LF。
# 逐字节比对前统一去掉 CR，比较的是实际文本内容。
for target in native js wasm-gc; do
  tr -d '\r' < "$OUT/out.$target.txt" > "$OUT/out.$target.norm.txt"
done

echo
echo "=== 内容一致性比对（已统一换行） ==="
if cmp -s "$OUT/out.native.norm.txt" "$OUT/out.js.norm.txt"; then
  echo "OK  native == js"
else
  echo "FAIL native != js"
  diff "$OUT/out.native.norm.txt" "$OUT/out.js.norm.txt" | head -40 || true
  exit 1
fi

if cmp -s "$OUT/out.native.norm.txt" "$OUT/out.wasm-gc.norm.txt"; then
  echo "OK  native == wasm-gc"
else
  echo "FAIL native != wasm-gc"
  diff "$OUT/out.native.norm.txt" "$OUT/out.wasm-gc.norm.txt" | head -40 || true
  exit 1
fi

echo
echo "摘要："
md5sum "$OUT"/out.*.norm.txt
