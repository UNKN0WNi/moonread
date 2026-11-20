#!/usr/bin/env bash
# / ：MoonBit 工具链自带 Why3，但**不附带 SMT 求解器**。
# `moon prove` 需要 alt-ergo / cvc5 / z3 之一。本脚本把它装好并自检。
set -euo pipefail

export PATH="$HOME/.moon/bin:$PATH"

PREFERRED="${PREFERRED_SOLVER:-z3}"

have() { command -v "$1" >/dev/null 2>&1; }

# GitHub Actions 的 runner 不是 root，但有免密 sudo；本地容器里通常直接是 root。
SUDO=""
if [ "$(id -u)" != "0" ] && have sudo; then
  SUDO="sudo"
fi

install_with_apt() {
  $SUDO apt-get update
  $SUDO apt-get install -y "$PREFERRED"
}

install_from_release() {
  # 无 apt 或 apt 镜像不可达时的退路：直接抓 GitHub release 的二进制
  local ver="4.13.3"
  local url="https://github.com/Z3Prover/z3/releases/download/z3-${ver}/z3-${ver}-x64-glibc-2.35.zip"
  local dest="$HOME/.local/bin"
  mkdir -p "$dest"
  curl -fsSL -o /tmp/z3.zip "$url"
  unzip -o -q /tmp/z3.zip -d /tmp/z3
  cp -f /tmp/z3/bin/z3 "$dest/z3"
  chmod +x "$dest/z3"
  echo "export PATH=\"$dest:\$PATH\"" >> "$HOME/.bashrc"
  export PATH="$dest:$PATH"
}

if have "$PREFERRED"; then
  echo "已存在：$(command -v "$PREFERRED")"
else
  echo "安装 $PREFERRED ..."
  if have apt-get && { [ "$(id -u)" = "0" ] || have sudo; }; then
    install_with_apt || install_from_release
  else
    install_from_release
  fi
fi

echo
echo "== 自检 =="
if have "$PREFERRED"; then
  "$PREFERRED" --version
else
  echo "FAIL: 求解器仍不在 PATH。可设 Z3PATH/CVC5PATH/ALTERGOPATH 环境变量。" >&2
  exit 1
fi

echo
echo "求解器就绪。执行证明请运行：bash scripts/prove.sh"
