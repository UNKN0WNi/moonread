# 架构

本文只写能在代码里对照检查的内容。

## 1. 分层与包映射

```text
L1  util / jsonio / xml
L2  container / resource / epub / comic / zipio
L3  render
L4  paginate / paginator / toc / bookmark / rules / config / core
应用 apps/embed-demo
```

| 层 | 包 | 职责 |
|---|---|---|
| L1 | `util` | 字符串、字符、数值、路径、JSON 辅助 |
| L1 | `jsonio` | 严格 JSON：有序对象、严格转义、未知字段拒绝、错误位置 |
| L1 | `xml` | XML 子集 tokenizer + tree builder，EPUB OPF / nav / NCX 的基础 |
| L2 | `container` | `Archive` 抽象，统一 ZIP / CBZ 暴露方式 |
| L2 | `resource` | 相对路径、URL 编码、base64 内嵌、远程资源策略 |
| L2 | `epub` | container.xml → OPF → spine / manifest → nav / NCX → 章节 |
| L2 | `comic` | CBZ 页面顺序、RTL、跨页、格式登记 |
| L2 | `zipio` | ZIP 解压：`fzip_adapter.mbt` 是唯一 `@fzip` 调用点，`entries_to_archive` 保持可替换 |
| L3 | `render` | `RenderBackend`：`Null` 与 `Crater` |
| L4 | `paginate` | 分页算法与不丢内容 / 不越界 / 单调 / 幂等不变式 |
| L4 | `paginator` | 页码、进度、定位 |
| L4 | `toc` | 目录树 |
| L4 | `bookmark` | 书签与阅读位置持久化 |
| L4 | `rules` | JSON 规则加载与规则应用 |
| L4 | `config` | 严格 JSON 配置与分页参数换算 |
| L4 | `core` | 门面：把 L2 / L3 / L4 编排成可嵌入 API |

## 2. 数据流

```text
字节输入
  -> container/archive
  -> epub::open
       -> container.xml
       -> OPF（manifest / spine / metadata）
       -> nav / NCX
  -> chapter XHTML 源码
  -> renderer.measure（当前为 Null 后端）
  -> paginate（块 -> 页）
  -> paginator（进度 / 定位）
  -> rules / bookmark / config 持久化
```

`core` 是唯一编排点。其他包保持可独立测试的边界。

## 3. 依赖规则

- L1 不 import L2 及以上；
- L2 不 import `render`，归档解析与渲染解耦；
- L3 不反向依赖 L4；
- L4 依赖 L2 + L3，但不被它们依赖；
- `core` 不 import 任何 UI 框架；
- 每个包的 `moon.pkg` 用 `import { "模块名/目录" }` 列出直接依赖。

## 4. 依赖取舍

| 能力 | 本仓库做法 | 原因 |
|---|---|---|
| XML | 自实现 `src/xml` | 主线零依赖可编译；只需 XML 1.0 良构子集 |
| ZIP | `src/zipio` 用 `hustcer/fzip` 真实解压，调用收敛在 `fzip_adapter.mbt` | 换解压后端只改一个文件，`entries_to_archive` 不受影响 |
| 渲染 | `Backend::Null` 可测，`Backend::Crater` 留占位 | crater 公共 API 尚未稳定，先固定度量接口 |

## 5. 当前限制

- `Backend::Crater` 尚未接入真实 crater；
- `apps/epub-cli` 依赖 `moonbitlang/x/fs` 读磁盘文件，因此只在 native 运行；内核本身四端可编译；
- 仓库没有 Web / 桌面 / 服务端应用壳，只有 `apps/embed-demo` 与 native 的 `apps/epub-cli`；
- `moon prove` 依赖外部 SMT 求解器；`scripts/setup_solver.sh` 负责安装，`scripts/prove.sh` 负责执行，已接入 CI。
