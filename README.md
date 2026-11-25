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

## Desktop app

想要即下即读的 Windows 桌面版？[MoonRead Desktop](https://github.com/UNKN0WNi/moonread-desktop) 复用本项目的 EPUB 解析规则，提供约 13 MB 的绿色单文件 `MoonRead.exe`——免安装、不写注册表，界面用系统 WebView2 渲染，不打包浏览器内核。[下载](https://github.com/UNKN0WNi/moonread-desktop/releases)。

> 需要 Windows 10/11 与 WebView2 Runtime（Win11 与较新 Win10 默认自带）。当前解析为纯文本 + 目录，不含图片排版与 DRM。

## Documentation

- [架构](docs/ARCHITECTURE.md) — 分层、依赖方向与关键取舍
- [分页](docs/PAGINATION.md) — 策略、不变式与术语
- [EPUB 标准符合性声明](docs/EPUB-CONFORMANCE.md) — 支持终点、规范条款与合法输入/预期结果
- [EPUB 覆盖范围](docs/EPUB-COVERAGE.md) — 支持的能力与边界
- [渲染后端](docs/RENDER-BACKEND.md) — `Backend::Null` 与 Crater 占位
- [开发指南](docs/DEV-GUIDE.md) — 包清单约定、命令与配置说明
- [示例配置与规则](examples/) · [JSON Schema](schema/)

## Status

本仓库交付的是**阅读内核 + 最小 CLI**，不是完整阅读器应用；桌面壳见 [MoonRead Desktop](https://github.com/UNKN0WNi/moonread-desktop)，Web 壳由宿主提供。DRM / 加密 EPUB 只检测不解密，`Backend::Crater` 尚未接入真实渲染器。

当前验证：四端 `moon check --deny-warn` 零警告、四端各 150 项测试通过、native / js / wasm-gc 输出一致，JSON 校验、`moon prove` 形式化证明，以及 27 本 EPUB（25 本自建 + 2 本真实公版书）的内核对账全部通过。

## License

Apache-2.0。25 本自建语料与 2 本第三方公版 EPUB 的来源、许可与 SHA-256 分别见 `tests/fixtures/manifest.json` 与 `tests/corpus/manifest.json`。
