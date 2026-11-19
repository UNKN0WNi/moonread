# MoonRead

[![CI](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml/badge.svg)](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml)

一个用 MoonBit 编写、可嵌入任何宿主的 EPUB / 漫画阅读内核。它解析容器格式、管理阅读语义（分页、目录、书签、进度、规则），把实际绘制交给渲染后端，并可整体编译为 wasm。

## Features

- **真实文件解析**：通过 `hustcer/fzip` 从磁盘直接解压 `.epub` / `.cbz`，解析 OPF、NCX、nav 目录与 DRM 标记
- **完整阅读语义**：分页（含四条不变式）、目录树、书签、进度定位、JSON 规则引擎与严格配置校验
- **可嵌入**：`core` 门面不依赖 UI 框架，四端（native / js / wasm / wasm-gc）可编译
- **开箱即看的示范**：附带独立工具，一条命令把任意 EPUB 渲染成可翻章的单文件 HTML（仅需 Python）
- **质量门禁**：CI 覆盖格式、四端测试、跨端一致性与数据自检

## Quick Start

### 渲染一本 EPUB

不需要 MoonBit，只要有 Python 3：

```bash
python3 tools/render_html.py /path/to/book.epub
```

生成的 `.html` 与 EPUB 同目录，用浏览器打开即可：左侧目录跳转、中文排版、键盘 `←` `→` 翻页、可调字号与夜间模式。手动指定输出位置用 `-o`：

```bash
python3 tools/render_html.py book.epub -o ./preview.html
```

> 这是一个**独立示范工具**，用 Python 标准库解析 EPUB，不调用 MoonBit 内核。下面是内核本身的用法。

### 用内核打开真实 EPUB

```bash
# 安装 MoonBit: https://www.moonbitlang.com/download/
moon run --target native apps/epub-cli /path/to/book.epub
```

从磁盘读真实字节 → fzip 解压 → 内核打开 → 打印元数据、目录和逐章分页报告。

### 跑示例与验证

```bash
moon run apps/embed-demo        # 内存示例（四端）
bash scripts/ci.sh              # 全部本地检查
```

## Documentation

- [架构](docs/ARCHITECTURE.md) — 分层、依赖方向与关键取舍
- [分页](docs/PAGINATION.md) — 策略、不变式与术语
- [EPUB 覆盖范围](docs/EPUB-COVERAGE.md) — 支持的能力与边界
- [渲染后端](docs/RENDER-BACKEND.md) — `Backend::Null` 与 Crater 占位
- [开发指南](docs/DEV-GUIDE.md) — 包清单约定、命令与配置说明
- [示例配置与规则](examples/) · [JSON Schema](schema/)

## Status

本仓库交付的是**阅读内核 + 最小 CLI**，不是完整阅读器应用；Web / 桌面壳由宿主提供。DRM / 加密 EPUB 只检测不解密，`Backend::Crater` 尚未接入真实渲染器。

当前验证：四端 `moon check --deny-warn` 零警告、四端各 101 项测试通过、native / js / wasm-gc 输出一致，JSON 与语料自检通过。

## License

Apache-2.0。测试语料为项目自建，来源见 `tests/fixtures/manifest.json`。
