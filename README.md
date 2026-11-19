# MoonRead（月读）

[![CI](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml/badge.svg)](https://github.com/UNKN0WNi/moonread/actions/workflows/ci.yml)

> 用 MoonBit 写的、可嵌入任何宿主的阅读内核：解析 EPUB / CBZ，复用生态现有的
> 浏览器引擎级渲染能力（HTML5 解析 → CSS 级联 → 布局 → 绘制），并补上它唯一缺失的一环——**分页**。

- 模块：`moonread/moonread`
- 许可：Apache-2.0
- 工具链：`moon 0.1.20261117`（`moonc v0.10.21+06da1ed44`）

---

## 当前状态

本仓库交付的是**可编译、可测试、可嵌入的阅读内核**，不是完整阅读器应用。

| 层 | 状态 | 说明 |
|---|---|---|
| L1 基础件 | ✅ 已实现 | `src/util`、`src/jsonio`（严格 JSON）、`src/xml`（XML 子集） |
| L2 容器层 | ✅ 已实现 | `src/container`、`src/resource`、`src/epub`、`src/comic` |
| L3 渲染层 | 🟡 抽象就绪 | `Backend::Null` 可用；`Backend::Crater` 是外部依赖占位 |
| L4 阅读语义 | ✅ 已实现 | `src/paginate`、`src/paginator`、`src/toc`、`src/bookmark`、`src/rules`、`src/config` |
| L4 门面 | ✅ 已实现 | `src/core`，不依赖任何 UI 框架，可整体编成 wasm 嵌入宿主 |
| ZIP 解压 | 🟡 接入点就绪 | `src/zipio` 零依赖可用；真实 `fzip` 调用示例见 `fzip_adapter.mbt.example` |
| L5 应用壳 | ⬜ 未提供 | 仓库只提供 `apps/embed-demo` 示例，不含 Web / 桌面 / 服务端壳 |

已验证：

- `moon fmt --check`：通过
- `moon check --deny-warn`：native / js / wasm / wasm-gc 四端通过，零警告
- `moon test`：四端各 98 项，全部通过
- `scripts/cross_target.sh`：native / js / wasm-gc 输出统一换行后完全一致
- `tools/validate_json.py`：schema、字段表、示例配置对账通过
- `tools/corpus_check.py`：15 本自建最小 EPUB 语料清单自检通过

---

## 快速上手

### 1. 安装工具链

从 <https://www.moonbitlang.com/download/> 安装 MoonBit。项目脚本会自动探测
`~/.moon/bin`、`MOON_BIN_DIR` 以及当前工作区里的受管工具链；也可以显式指定：

```bash
export MOON=/path/to/moon
```

### 2. 一键验证

```bash
bash scripts/ci.sh
```

这个脚本会依次执行：格式检查、四端严格编译、四端测试、三端一致性、JSON 自检、语料自检。

### 3. 手动常用命令

```bash
source scripts/toolchain-env.sh

moon fmt
moon check --deny-warn
moon test --target native
moon test --target js
moon test --target wasm
moon test --target wasm-gc

python3 tools/validate_json.py
python3 tools/corpus_check.py --require-manifest --skip-missing-books
```

### 4. 跑一个端到端示例

```bash
moon run apps/embed-demo
```

示例会在内存里构造一本 EPUB，然后演示：打开归档 → 解析 OPF / 目录 → 分页 →
检查不变式 → 保存 / 恢复进度 → 应用规则。

---

## 它解决什么问题

MoonBit 生态里零件齐全，但缺少一个成品阅读内核：

| 环节 | 生态现状 |
|---|---|
| HTML5 解析 | `moonbit-community/html5-mbt` |
| CSS 解析 / 级联 | `mizchi/css` |
| 布局 / 绘制 | `mizchi/crater` |
| 字体 / 图像 / SVG | `mizchi/font` / `mizchi/image-mbt` / `mizchi/svg` |
| ZIP 容器 | `hustcer/fzip` |
| UI / 桌面壳 | `rabbita` / `luna.mbt` / `proton` / `moonbit-webview` |
| **EPUB / 漫画阅读内核** | **MoonRead 补这一块** |

现有阅读器通常绑定 Lua、Electron、WebKit 或 GTK。MoonRead 的目标是把内核编译到
wasm，保持小体积、零 UI 依赖，让宿主自己决定界面。

---

## 架构

```text
L5 应用壳      apps/embed-demo（示例）；Web / 桌面 / 服务端壳由宿主提供
L4 阅读语义    paginate · paginator · toc · bookmark · rules · config · core
L3 渲染层      render（Backend::Null | Backend::Crater）
L2 容器层      container · resource · epub · comic · zipio
L1 基础设施    util · jsonio · xml
```

依赖方向：

- L1 不依赖 L2 及以上；
- L2 不依赖渲染层，归档解析可独立测试；
- L3 只提供抽象，`Null` 用于确定性度量，`Crater` 留给外部实现；
- L4 依赖 L2 + L3，不被它们依赖；
- `moonread-core` 不依赖任何 UI 框架。

详见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

---

## 目录

```text
moonread/
├── moon.mod · moon.work.json
├── schema/            config.schema.json · rules.schema.json
├── examples/          config.json · rules.json（带 _comment 说明）
├── src/
│   ├── util/          L1 字符串 / 路径 / 数值
│   ├── jsonio/        L1 严格 JSON（有序对象、严格转义、未知字段拒绝）
│   ├── xml/           L1 XML 子集 tokenizer + tree builder
│   ├── container/     L2 Archive 抽象
│   ├── resource/      L2 资源路径与媒体类型
│   ├── epub/          L2 container.xml / OPF / nav / NCX / DRM 检测 / 容错
│   ├── comic/         L2 CBZ / RTL / 跨页 / 格式登记
│   ├── render/        L3 RenderBackend
│   ├── paginate/      L4 分页策略层 + 四条不变式
│   ├── paginator/     L4 页码 / 进度 / 定位
│   ├── toc/           L4 目录树
│   ├── bookmark/      L4 书签
│   ├── rules/         L4 JSON 规则引擎
│   ├── config/        L4 JSON 配置
│   ├── core/          L4 门面
│   └── zipio/         ZIP 接入点（默认零依赖）
├── apps/embed-demo/   可运行示例
├── tests/             fixtures · corpus · reference
├── tools/             validate_json.py · corpus_check.py · gen_fixtures.py
├── scripts/           ci.sh · cross_target.sh · toolchain-env.sh · ...
└── docs/              ARCHITECTURE · PAGINATION · EPUB-COVERAGE · RENDER-BACKEND · DEV-GUIDE
```

---

## 配置与规则

`examples/config.json` 和 `examples/rules.json` 是可直接修改的样例。JSON 里以 `_`
开头的键是给人看的注释，运行时会忽略：

```json
{
  "_comment": "字号单位是 pt，行高是倍数。",
  "typography": {
    "font_size_pt": 12,
    "line_height": 1.6
  }
}
```

严格性约定：

- 未知字段会报错，不会静默忽略；
- `config.json` 的 `page` 段负责换算分页参数；
- 规则按数组顺序执行，重复 `id` 会报错；
- 修改后用 `python3 tools/validate_json.py` 校验。

详情见 [`schema/`](schema/) 和 [`docs/DEV-GUIDE.md`](docs/DEV-GUIDE.md)。

---

## 分页

分页层把「怎么排」交给渲染后端，把「怎么断」留给自己：

| 不变式 | 含义 |
|---|---|
| 不丢内容 | 分页前后所有块高度 / 行数总和一致 |
| 不越界 | 每页用量不超过页容量 |
| 单调 | 后续页不会回到前面 |
| 幂等 | 同样输入重复运行得到同样结果 |

`orphan_min` / `widow_min` 采用 CSS 原始定义：作用于**被拆分的那个块**在前页 /
后页的最小行数。详见 [`docs/PAGINATION.md`](docs/PAGINATION.md)。

---

## 明确非目标

- DRM / 加密 EPUB 只检测并提示，不解密；
- 不做 PDF、商店、账号、云同步；
- 不移植 KOReader / Readest / foliate 代码；
- 不内置 RAR / 7z 解码器；
- 不附带任何商业电子书或漫画。

---

## 许可

Apache-2.0。详见 [`LICENSE`](LICENSE)。测试语料均为项目自建，来源与许可记录在
`tests/fixtures/manifest.json`。
