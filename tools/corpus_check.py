#!/usr/bin/env python3
"""语料批量解析回归。

对每个语料目录读 `manifest.json`，把期望值与内核输出对账。
本脚本**不实现 EPUB 解析**——它只负责：
  1. 校验 manifest 自身合法（严格 JSON + 必填字段）；
  2. 调用 `moon run tools/probe` 之类的内核导出程序（若存在）拿实际值；
  3. 输出差异表。

当内核导出程序不存在时，退化为「只做 manifest 自检 + 文件存在性检查」，
并明确打印 skip 原因，不假装通过。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ["file", "license", "source", "expect"]
REQUIRED_EXPECT = ["title", "chapters", "toc_items", "resources"]


def load_strict(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def check_manifests(corpus_dirs):
    problems = []
    entries = []
    for d in corpus_dirs:
        mf = d / "manifest.json"
        if not mf.exists():
            problems.append(f"{mf.relative_to(ROOT)}: 缺少 manifest.json")
            continue
        try:
            doc = load_strict(mf)
        except Exception as e:  # noqa: BLE001
            problems.append(f"{mf.relative_to(ROOT)}: 非法 JSON：{e}")
            continue
        books = doc.get("books", [])
        if not isinstance(books, list):
            problems.append(f"{mf.relative_to(ROOT)}: books 必须是数组")
            continue
        for i, b in enumerate(books):
            tag = f"{mf.relative_to(ROOT)} books[{i}]"
            for k in REQUIRED:
                if k not in b:
                    problems.append(f"{tag}: 缺少必填字段 {k!r}")
            exp = b.get("expect", {})
            if isinstance(exp, dict):
                for k in REQUIRED_EXPECT:
                    if k not in exp:
                        problems.append(f"{tag}: expect 缺少 {k!r}")
            book_path = (d / b.get("file", "")).resolve()
            if not book_path.exists():
                problems.append(f"{tag}: 语料文件不存在 {b.get('file')}")
            entries.append((tag, d, b))
    return entries, problems


def run_kernel_probe(dirs):
    """调用内核导出程序；跑不起来则返回 None。"""
    cmd = ["moon", "run", "--target", "native", "tools/probe"] + [
        str(d.relative_to(ROOT)) for d in dirs
    ]
    try:
        out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=300)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        print("  probe stderr:", out.stderr.strip()[:400])
        return None
    text = out.stdout.strip()
    if not text.startswith("{"):
        return None
    return json.loads(text)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="tests/corpus,tests/fixtures")
    ap.add_argument(
        "--require-manifest",
        action="store_true",
        help="manifest 缺失或不合法即失败（CI 默认开启）",
    )
    ap.add_argument("--skip-missing-books", action="store_true")
    ap.add_argument(
        "--require-probe",
        action="store_true",
        help="要求内核对账真正执行；探针缺失或期望值不符即失败（CI 必开）",
    )
    args = ap.parse_args()

    dirs = [ROOT / p.strip() for p in args.corpus.split(",") if p.strip()]
    dirs = [d for d in dirs if d.exists()]
    if not dirs:
        print("没有找到任何语料目录")
        return 1 if args.require_manifest else 0

    entries, problems = check_manifests(dirs)
    print(f"== manifest 自检：{len(entries)} 本 ==")

    missing_books = [t for t, d, b in entries if not (d / b["file"]).exists()]
    if missing_books:
        print(f"  提示：{len(missing_books)} 本语料文件尚未取得（需要网络下载或 gen_fixtures.py）")
        if args.require_manifest and not args.skip_missing_books:
            print("  FAIL --require-manifest 下缺文件视为失败")
            print("       真实语料需要网络；本仓库默认构建里只有内存生成的 fixture")
            return 1

    # 真实语料必须逐字节可复现：manifest 里钉死 SHA-256。
    for tag, d, b in entries:
        want = b.get("sha256")
        if not want:
            continue
        p = (d / b["file"]).resolve()
        if not p.exists():
            continue
        actual = hashlib.sha256(p.read_bytes()).hexdigest()
        if actual != want:
            problems.append(f"{tag}: sha256 期望 {want}，实际 {actual}")

    for p in problems:
        print(f"  FAIL {p}")

    probe = run_kernel_probe(dirs)
    if probe is None:
        print("== 内核对账：SKIP ==")
        print("  内核探针 tools/probe 未能运行。manifest 已自检，")
        print("  但期望值与实际解析结果**未对账**。")
        if args.require_probe:
            print("  FAIL --require-probe 下不允许跳过内核对账")
            return 1
    else:
        print("== 内核对账 ==")
        bad = 0
        for tag, _d, b in entries:
            got = probe.get(b["file"])
            if got is None:
                if args.require_probe:
                    print(f"  FAIL {tag}: 内核输出里没有这一本")
                    bad += 1
                else:
                    print(f"  SKIP {tag}: 内核输出里没有这一本")
                continue
            for k, v in b["expect"].items():
                if got.get(k) != v:
                    print(f"  FAIL {tag}.{k}: 期望 {v}，实际 {got.get(k)}")
                    bad += 1
        print(f"  已对账 {len(entries) - bad}/{len(entries)} 本")
        if bad:
            return 1

    return 1 if (problems and args.require_manifest) else 0


if __name__ == "__main__":
    sys.exit(main())
