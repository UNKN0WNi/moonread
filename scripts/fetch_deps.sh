#!/usr/bin/env bash
# 取外部依赖并把 src/zipio 的 fzip 适配器接入构建。
# （fzip）+ 已知踩坑（workspace 依赖仍需版本号）。
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.moon/bin:$PATH"

FZIP_VERSION="${FZIP_VERSION:-0.8.8}"

echo "== 0. 连通性检查 =="
if ! curl -fsSL -m 20 -o /dev/null https://pkg.mooncakes.io/; then
  cat >&2 <<'TXT'
FAIL: 无法访问 mooncakes 包源。
      本次交付的默认构建**不需要**任何外部依赖（src/zipio 的 fzip 调用点
      以 .mbt.example 形式排除在构建外），因此这个失败不影响 moon test。
      要启用真实 ZIP 解压，请在能联网的机器上重跑本脚本。
TXT
  exit 1
fi
echo "OK  包源可达"

echo
echo "== 1. 取包 =="
moon update || true
moon install 2>/dev/null || true

echo
echo "== 2. 接入适配器 =="
if [ ! -f src/zipio/fzip_adapter.mbt.example ]; then
  echo "FAIL: 找不到 src/zipio/fzip_adapter.mbt.example" >&2
  exit 1
fi
if [ -f src/zipio/fzip_adapter.mbt ]; then
  echo "已接入（src/zipio/fzip_adapter.mbt 存在），跳过改名"
else
  git mv src/zipio/fzip_adapter.mbt.example src/zipio/fzip_adapter.mbt 2>/dev/null \
    || mv src/zipio/fzip_adapter.mbt.example src/zipio/fzip_adapter.mbt
  echo "已改名。fzip 版本假设：$FZIP_VERSION"
fi

cat >&2 <<TXT

== 3. 还需要手工完成的 3 处签名核对 ==
打开 src/zipio/fzip_adapter.mbt，搜索 TODO(签名核对)：
  1/3 @fzip 的输入类型（Bytes / Array[Int] / String）
  2/3 unzip_sync 的返回形状（是否 Result、条目字段名）
  3/3 条目顺序是否等于中央目录顺序（EPUB 的 mimetype 首位判定依赖它）
并在 src/zipio/moon.pkg.json 的 imports 里加入 "hustcer/fzip@$FZIP_VERSION"。

== 4. 验证 ==
  moon check --deny-warn
  moon test
  bash scripts/cross_target.sh    # 三端逐字节一致必须仍然成立（）

TXT

echo "== 4. 尝试编译 =="
moon check --deny-warn || {
  echo
  echo "如上是预期的签名错误。按第 3 步逐条修正后重跑。" >&2
  exit 2
}
