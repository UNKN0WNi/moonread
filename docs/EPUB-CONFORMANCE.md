# EPUB 标准符合性声明

本文回答一个具体问题：**moonread 对 EPUB 标准的支持终点在哪里，以及合法输入会得到什么解析结果。**

文中每条都给出规范条款、实现位置与可运行的断言。所有「预期结果」都由 `moon test` 与 `tools/corpus_check.py --require-probe` 自动核对，不是人工承诺。

## 1. 支持终点（conformance target）

| 项目 | 声明 |
|---|---|
| 目标规范 | **EPUB 3.3**（W3C Recommendation）与 **EPUB 2.0.1 / OPF 2.0 + NCX** |
| 符合范围 | **阅读内核**：容器结构解包、包文档元数据、导航数据、阅读顺序、章节资源定位 |
| 处理模型 | 合法文档按规范语义解析；可降级缺陷返回 `Ok(book) + warnings`；致命缺陷返回 `Err`；任何输入不 panic |
| 非目标 | DRM 解密、完整 CSS 布局与脚本执行、字体栅格化、OPF `collection` 多文档、RAR/7z 容器 |

「支持」的判定口径是：**规范规定的语义在内核结果中可查询、不丢失**，而不是必须渲染像素。绘制交给渲染后端（`RenderBackend`），内核不声称实现视觉层。

### 1.1 为什么内部叫「XML 子集」

解析器 `src/xml/xml.mbt` 处理的是 **EPUB 实际使用的 XML 1.0 良构子集**，不是自创格式。它实现且只实现 EPUB 规范要求的特性：

- `<?xml?>` 声明、注释、`DOCTYPE`（含内部子集）、CDATA、处理指令；
- 五个预定义实体 + 数字字符引用（十进制/十六进制）+ `nbsp`；
- 命名空间前缀原样保留，用 `local_name` 去前缀后比较（不依赖 DTD/外部实体，符合 EPUB 的 XXE 禁令）；
- `lenient` 模式覆盖真实书的常见脏写法（未闭合的 HTML 空元素、大小写不一致的结束标签、未声明实体按字面保留）。

明确**不支持**且会给出清晰错误：自定义 DTD 实体、外部/网络实体（EPUB 安全要求）、命名空间 URI 归一化。这些不在 EPUB 内容文档的必需行为内。

## 2. 规范条款 → 实现 → 断言

以下条款均引自 EPUB 3.3 规范正文（W3C Recommendation）。

### 2.1 容器（OCF）

| 规范要求 | 实现 | 合法输入 → 预期解析结果 |
|---|---|---|
| `mimetype` 必须为首个条目且内容为 `application/epub+zip` | `src/zipio/fzip_adapter.mbt` | 首位正确 → 无告警；顺序错误 → 告警但继续读取（读取侧容忍） |
| `container.xml` 的 `rootfiles/rootfile@full-path` 指向 OPF | `parse_container` | 路径 `OEBPS/content.opf` → `book.opf_path == "OEBPS/content.opf"` |
| `container.xml` 缺失 | `open_with` 扫描 `*.opf` 降级 | 仍能定位 OPF 并解析全部章节，记一条告警 |

断言：`src/epub/epub_test.mbt` 的 `mimetype 不在首位`、`缺 container.xml：扫描 *.opf 降级`。

### 2.2 包文档元数据（title / language / identifier）

规范原文（§The dc:title element）：

> The first dc:title element in document order is the main title of the EPUB publication (i.e., the primary one reading systems present to users).
> Attributes: dir [optional] id [optional] xml:lang [optional] Content Model: Text

| 合法输入 | 预期解析结果 | 断言 |
|---|---|---|
| 单个 `<dc:title>T</dc:title>` | `metadata.title == "T"` | `EPUB3 基本书` |
| 两个 `dc:title`，首个 `xml:lang="en"`、次个 `xml:lang="ja"` | 主标题仍取**首个**（符合规范）；`metadata.titles` 两条全保留，各自 `lang` 与 `id` 可取 | `EPUB3 多 dc:title` |
| 标题含 `&lt;` / `&gt;` / 数字实体 | 解码后文本 `带实体 <标记> 的书` | `标题内实体会被解码` |

实现：`src/epub/parse.mbt::parse_metadata` 收集全部 `dc:title` 到 `Metadata.titles`（`TitleInfo{value, lang, id}`），`metadata.title` 保持为首个以兼容既有 API。

### 2.3 refines 修饰关系（角色 / 别名 / file-as）

规范原文（§The refines attribute）：

> Establishes an association between the current expression and the element or resource identified by its value.

> `<meta refines="#creator02" property="role" scheme="marc:relators">ill</meta>`

> `<meta refines="#creator" property="alternate-script" xml:lang="ja">村上 春樹</meta>`

| 合法输入 | 预期解析结果 | 断言 |
|---|---|---|
| `<dc:creator id="c1">A</dc:creator>` + `<meta refines="#c1" property="role">ill</meta>` | 该作者角色为 `ill`，不再误标为默认 `aut` | `EPUB3 meta refines：角色/别名/file-as 不再丢失` |
| `<meta refines="#c1" property="alternate-script" xml:lang="ja">著者サンプル</meta>` | `refine(...,"alternate-script")` 取到值，`refine_all()[0].lang == "ja"` | 同上 |
| `<meta refines="#c1" property="file-as">...</meta>` | `refine(...,"file-as")` 可取 | 同上 |
| `meta refines` 出现在被修饰元素之前 | 仍能关联（解析前先建修饰表） | 同上（fixture 中 refines 位于 creator 之后，逻辑对两种顺序均成立） |

实现：`Metadata.refines : Array[RefineInfo]` 与访问器 `refine` / `refine_all`（`src/epub/model.mbt`）；`parse_metadata` 先扫 `meta refines` 再解析 `dc:` 元素。

### 2.4 导航数据（EPUB3 nav / EPUB2 NCX）

规范原文（§Navigation document requirements）：

> A valid EPUB navigation document MUST include exactly one toc nav element.

> Content Model: `li` In this order: ([^span^] or [^a^]) [exactly 1] [^ol^] [0 or 1]

> EPUB creators can hide navigation elements that are only for machine processing ... with the hidden attribute.

| 合法输入 | 预期解析结果 | 断言 |
|---|---|---|
| `<nav epub:type="toc"><ol><li><a href="ch1.xhtml">第一章</a></li></ol></nav>` | `nav_toc[0].label == "第一章"`，`path == "OEBPS/ch1.xhtml"` | `EPUB3 nav 目录树` |
| `<li><span>分组</span><ol>...子项...</ol></li>` | 一条 `is_group == true` 的节点，标签为「分组」，子项递归保留；不再丢弃 | `EPUB3 nav：span 分组标题与 hidden 空布尔值语义不丢失` |
| `<li hidden="">` | `hidden == true`（空值也算，符合 HTML 布尔属性语义），文字仍保留 | 同上 |
| EPUB2 `<navMap><navPoint><navLabel><text>…</text></navLabel><content src=…/>` | `ncx_toc` 递归树，标签与 src 均可取 | `EPUB2 + NCX 双支持` |
| 既无 nav 也无 NCX | 按 spine 合成一级目录，来源标记 `spine-fallback` | `缺 nav：降级可用` |

实现：`src/epub/parse.mbt::parse_nav_list` 识别 `span` 与 `hidden`；`NavPoint` / `TocItem` 增加 `is_group` / `hidden` 字段透传给 UI。

### 2.5 阅读顺序与资源定位

| 规范要求 | 实现 | 合法输入 → 预期解析结果 |
|---|---|---|
| `spine@itemref@idref` 引用 manifest item | `parse_spine` | 合法 idref → 按 spine 顺序得到 `chapter_paths`；坏 idref → 降级保留并告警 |
| `linear="no"` 项不进入主阅读顺序 | `chapter_paths` | NCX（linear=no）不计入章节数 |
| href 相对路径 / 百分号编码 / 锚点 | `src/resource/resource.mbt` | `ch%201.xhtml#s2` → 归档内路径 + `fragment == "s2"` |
| `properties="nav"` 标记导航文档 | `find_nav_item` | 有该属性 → 解析 nav；无 → 回退 NCX |

## 3. 可复现的验证命令

```bash
# 四端编译 + 测试 + 一致性 + 语料对账 + 形式化证明（需 MoonBit 工具链）
bash scripts/ci.sh

# 只看内核对账：磁盘 EPUB 经 fzip + 内核解析，与 manifest 的标题/章节/目录/资源逐项核对
python3 tools/corpus_check.py --require-manifest --require-probe
```

当前结果：四端各 122 项测试通过；跨端输出一致；18 本 EPUB（16 自建 + 2 第三方公版）内核对账全部通过；`moon prove` 在 CI 的 Linux 任务中由 SMT 求解器验证。

## 4. 语料来源

- 16 本自建最小 EPUB：由 `tools/gen_fixtures.py` 与 `src/epub/fixture.mbt` 成对生成，Apache-2.0，见 `tests/fixtures/manifest.json`。其中 `rich-metadata.epub` 专门承载本文 §2.2–2.4 的合法语义样例。
- 2 本第三方公版 EPUB：来源 URL 与 SHA-256 钉在 `tests/corpus/manifest.json`，避免上游静默变更。
