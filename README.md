# MoonRead（月读）

[![CI](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml/badge.svg)](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml)

用 MoonBit 写的、可嵌入任何宿主的**阅读内核**：解析 EPUB / CBZ，把渲染交给生态里现成的引擎，补上它们唯一缺的一环——**分页**。

仓库附带一个独立的示范工具，能把任意本地 EPUB 变成一页可翻的 HTML——**不用装 MoonBit，一条命令就能看到效果**。

- 模块 `moonread/moonread` · 许可 Apache-2.0
- 工具链 `moon 0.1.20261117`（`moonc v0.10.21+06da1ed44`）

---

## 30 秒上手：把一本 EPUB 变成可翻的网页

这是理解本项目最快的方式。只需要 Python 3（标准库，无需 pip 安装任何东西）。

```bash
# 克隆后进入项目目录
python3 tools/render_html.py /path/to/your-book.epub
```

命令结束后，会在 EPUB **同目录**生成一个同名 `.html` 文件。用浏览器打开它，就能看到：

- 左侧目录，点击任意章节直接跳转
- 正文按中文阅读习惯排版（首行缩进、两端对齐）
- 上一章 / 下一章按钮，或键盘 `←` `→` 翻页
- 顶部可调字号、切换夜间模式

想指定输出位置，加 `-o`：

```bash
python3 tools/render_html.py book.epub -o ./preview.html
```

不带参数运行 `python3 tools/render_html.py --help` 可查看完整用法。

> 这个工具在真实书籍上验证过：一本 161 章、127 万字的小说合集，生成约 3.7 MB 的单文件 HTML，全部章节可正常翻阅。

### 它是怎么做的

渲染工具只做一件事：**把 EPUB 的内部结构摊开，装进一个自带目录和翻页逻辑的 HTML 文件**。六步如下：

| 步骤 | 做法 | 用到的东西 |
|---|---|---|
| 1. 解包 | EPUB 本质是 ZIP，读出里面所有文件 | Python `zipfile` |
| 2. 找书目 | 读 `.opf` 里的 `dc:title` / `dc:creator` | `xml.etree` |
| 3. 定顺序 | 按 `.opf` 的 `spine` 排列阅读顺序 | `xml.etree` |
| 4. 取目录 | 读 `.ncx`，还原章节标题与层级 | `xml.etree` |
| 5. 提正文 | 逐个 XHTML 去掉标签，抽出段落文字 | `re` + `html` |
| 6. 出页面 | 把书目/目录/正文内嵌进一个 HTML 模板 | 字符串替换 |

成品是完全自包含的：文字和目录都在 HTML 里，断网也能看。

**注意**：`tools/render_html.py` 是一个**独立示范工具**，它用 Python 标准库直接解析 EPUB，不调用 MoonBit 内核，也不需要 `moon`。它展示的是「结构如何变成可读页面」。要验证 MoonBit 内核本身，用下面 `apps/epub-cli` 那条路径。

---

## 两条路径，别混淆

| | 渲染示范 | 内核验证 |
|---|---|---|
| 命令 | `python3 tools/render_html.py book.epub` | `moon run --target native apps/epub-cli book.epub` |
| 实现 | Python 标准库 | MoonBit + `hustcer/fzip` |
| 需要 moon | 不需要 | 需要 |
| 输出 | 可翻章的 HTML 文件 | 元数据 / 目录 / 逐章分页报告 |
| 用途 | 直观看到一本书被解析成什么 | 证明 MoonBit 内核真实打开了这本书 |

两者读取的是同一本 EPUB，解析规则也对应，但**是两套独立实现**。

---

## MoonRead 内核是什么

MoonBit 生态里零件齐全，但缺一个成品阅读内核：

| 环节 | 生态现状 |
|---|---|
| HTML5 解析 | `moonbit-community/html5-mbt` |
| CSS 解析 / 级联 | `mizchi/css` |
| 布局 / 绘制 | `mizchi/crater` |
| ZIP 容器 | `hustcer/fzip` |
| **EPUB / 漫画阅读内核** | **MoonRead 补这一块** |

现有阅读器通常绑定 Lua、Electron、WebKit 或 GTK。MoonRead 的目标是把内核编译到 wasm，保持小体积、零 UI 依赖，让宿主自己决定界面。

本仓库交付的是**可编译、可测试、可嵌入的阅读内核**，不是完整阅读器应用。当前能力：

- EPUB 容器解析（`container.xml` / OPF / nav / NCX / DRM 检测）与真实 ZIP 解压
- CBZ 漫画基础（RTL、跨页、格式登记）
- 分页策略与四条不变式、页码 / 进度 / 定位、目录树、书签
- JSON 规则引擎与配置，严格校验（未知字段拒绝）
- 内核门面 `core`，不依赖任何 UI 框架，可整体编成 wasm

---

## 内核快速上手

### 安装工具链

从 <https://www.moonbitlang.com/download/> 安装 MoonBit。项目脚本会自动探测 `~/.moon/bin`、`MOON_BIN_DIR` 和受管工具链；也可显式指定：

```bash
export MOON=/path/to/moon
```

### 从磁盘打开真实 EPUB

```bash
moon run --target native apps/epub-cli /path/to/book.epub
```

`apps/epub-cli` 从磁盘读真实字节 → `src/zipio` 用 `hustcer/fzip` 解压 → `src/core` 打开 → 打印元数据、目录和逐章分页。已在《工作、消费主义和新穷人》《刘慈欣三大长篇代表作》等真实 EPUB 上验证。

> 只有 `apps/epub-cli` 依赖 `moonbitlang/x/fs`（native 读文件）。内核本身保持四端可编译、可嵌入 wasm。

### 内存示例（四端可跑）

```bash
moon run apps/embed-demo
```

示例在内存里构造一本 EPUB，演示：打开归档 → 解析 OPF / 目录 → 分页 → 检查不变式 → 保存 / 恢复进度 → 应用规则。

### 一键验证

```bash
bash scripts/ci.sh
```

依次执行：格式检查、四端严格编译、四端测试、三端输出一致性、JSON 自检、语料自检。

当前验证结果：

- `moon fmt --check` 通过；四端 `moon check --deny-warn` 零警告
- 四端 `moon test` 各 101 项全部通过
- `scripts/cross_target.sh`：native / js / wasm-gc 输出统一换行后完全一致
- `tools/validate_json.py`、`tools/corpus_check.py` 自检通过

手动常用命令：

```bash
source scripts/toolchain-env.sh
moon fmt
moon check --deny-warn
moon test --target native       # 也支持 js / wasm / wasm-gc
python3 tools/validate_json.py
python3 tools/corpus_check.py --require-manifest --skip-missing-books
```

---

## 架构

```text
L5 应用壳      apps/embed-demo（内存示例）· apps/epub-cli（真实 EPUB，native）
L4 阅读语义    paginate · paginator · toc · bookmark · rules · config · core
L3 渲染层      render（Backend::Null | Backend::Crater）
L2 容器层      container · resource · epub · comic · zipio（fzip 解压）
L1 基础设施    util · jsonio（严格 JSON）· xml
```

依赖方向：L1 不依赖上层；L2 不依赖渲染层，归档解析可独立测试；L3 只给抽象，`Null` 用于确定性度量，`Crater` 留给外部；L4 依赖 L2 + L3，`core` 不依赖任何 UI 框架。详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

分页层把「怎么排」交给渲染后端，把「怎么断」留给自己，保证四条不变式：不丢内容、不越界、单调、幂等。详见 [`docs/PAGINATION.md`](docs/PAGINATION.md)。

---

## 目录结构

```text
moonread/
├── moon.mod · moon.work.json
├── schema/            config.schema.json · rules.schema.json
├── examples/          config.json · rules.json（带 _comment 说明）
├── src/               L1~L4 各层包（见上）
├── apps/
│   ├── embed-demo/    内存 EPUB 示例（四端）
│   └── epub-cli/      真实 EPUB 读取器（native）
├── tools/
│   ├── render_html.py EPUB → 可翻章 HTML（渲染示范，纯 Python）
│   ├── validate_json.py · corpus_check.py · gen_fixtures.py
├── scripts/           ci.sh · cross_target.sh · toolchain-env.sh · fetch_deps.sh
├── tests/             fixtures · corpus · reference
└── docs/              ARCHITECTURE · PAGINATION · EPUB-COVERAGE · RENDER-BACKEND · DEV-GUIDE
```

---

## 配置与规则

[`examples/config.json`](examples/config.json) 和 [`examples/rules.json`](examples/rules.json) 可直接改。JSON 里以 `_` 开头的键是给人看的注释，运行时忽略：

```json
{
  "_comment": "字号单位是 pt，行高是倍数。",
  "typography": { "font_size_pt": 12, "line_height": 1.6 }
}
```

约定：未知字段会报错而非静默忽略；规则按数组顺序执行，重复 `id` 报错；改完用 `python3 tools/validate_json.py` 校验。详见 [`schema/`](schema/) 与 [`docs/DEV-GUIDE.md`](docs/DEV-GUIDE.md)。

---

## 限制与非目标

- DRM / 加密 EPUB 只检测并提示，不解密
- `Backend::Crater` 尚未接入真实 crater；需外部依赖，目前请用 `Backend::Null`
- 不做 PDF、商店、账号、云同步；不附带任何商业电子书
- 不移植 KOReader / Readest / foliate 代码；不内置 RAR / 7z 解码器
- 渲染工具针对带 `.opf` + `.ncx` 的 EPUB；极简或无目录的 EPUB 仍能出正文，但目录可能为空

---

## 许可

Apache-2.0，详见 [`LICENSE`](LICENSE)。测试语料均为项目自建，来源与许可记录在 `tests/fixtures/manifest.json`。
