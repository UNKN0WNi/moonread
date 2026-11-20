#!/usr/bin/env bash
# 运行 moon prove。
#
# moon prove 在找不到 SMT 求解器时会打印错误但仍然以 0 退出，
# 因此这里先显式检查求解器，避免把「没跑」误当成「证明通过」。
# 本地没装求解器时默认 SKIP；CI 用 MOONREAD_REQUIRE_PROVE=1 强制必须真跑。
set -euo pipefail
cd "$(dirname "$0")/.."

export TOOLCHAIN_ENV_QUIET=1
source scripts/toolchain-env.sh

have() { command -v "$1" >/dev/null 2>&1; }

if ! have moon; then
  echo "SKIP: 未找到 moon 工具链。先装 MoonBit：curl -fsSL https://bit.ly/moonbit | bash" >&2
  exit 0
fi

if ! have z3 && ! have cvc5 && ! have alt-ergo &&
  [ -z "${Z3PATH:-}" ] && [ -z "${CVC5PATH:-}" ] && [ -z "${ALTERGOPATH:-}" ]; then
  if [ "${MOONREAD_REQUIRE_PROVE:-0}" = "1" ]; then
    echo "FAIL: moon prove 需要 SMT 求解器（z3 / cvc5 / alt-ergo）。先运行 bash scripts/setup_solver.sh。" >&2
    exit 1
  fi
  echo "SKIP: 未找到 SMT 求解器，跳过 moon prove（CI 会安装后强制执行）。" >&2
  exit 0
fi

printf '\n=== moon prove ===\n'
out="$(moon prove --deny-warn 2>&1)"
printf '%s\n' "$out"

# 当前工具链即使证明失败也以 0 退出，因此必须读汇总行自己判定。
summary="$(printf '%s\n' "$out" | grep -Eo '[0-9]+ of [0-9]+ packages proved' | tail -n 1 || true)"
if [ -z "$summary" ]; then
  echo "FAIL: moon prove 没有输出证明汇总行，无法确认结果。" >&2
  exit 1
fi
set -- $summary
if [ "$1" = "0" ] || [ "$1" != "$3" ]; then
  echo "FAIL: 证明未全部通过（$summary）。" >&2
  exit 1
fi
