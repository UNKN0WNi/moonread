#!/usr/bin/env bash
# 校验 / 拉取 MoonRead 的外部依赖（fzip 已接入，x 提供 native 文件读取）。
# 依赖声明在 moon.mod 的 `import {}` 里，本脚本只负责更新索引并验证可解析。
set -euo pipefail
cd "$(dirname "$0")/.."

export PATH="$HOME/.moon/bin:$PATH"
# 会话级工具链可能不在默认路径，复用项目里的探测脚本。
if [ -f scripts/toolchain-env.sh ]; then
  # shellcheck disable=SC1091
  source scripts/toolchain-env.sh
fi

echo "== 1. 更新 registry 索引 =="
moon update

echo
echo "== 2. 校验依赖可解析 =="
moon check --target native --deny-warn || {
  echo "FAIL: 依赖未就绪。检查 moon.mod 的 import 是否含 fzip / x。" >&2
  exit 2
}

echo
cat >&2 <<'TXT'
OK  依赖就绪：
  - hustcer/fzip@0.8.8  真实 ZIP 解压（src/zipio/fzip_adapter.mbt）
  - moonbitlang/x@0.5.7 native 文件读取（仅 apps/epub-cli 使用）

验证真实 EPUB：
  moon run --target native apps/epub-cli /path/to/book.epub

如要换 fzip 版本，改 moon.mod 的 import 后重跑本脚本。
TXT
