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

解析器 `src/xml/xml.mbt` 处理的是 **EPUB 实际使用的 XML 1.0 + XML Namespaces 1.0 子集**，不是自创格式。EPUB 3.3「XML conformance」条款原文：

> Any publication resource that is an XML-based media type … MUST be a conformant XML 1.0 Document as defined in Conformance of Documents **[XML Namespaces]** … MAY only specify a document type declaration that references an external identifier appropriate for its media type — or that omits external identifiers … **MUST NOT contain external entity declarations in the internal DTD subset.**

这里有三个必须同时满足的事实，构成本项目**符合标准的 XML/容器处理终点**：

1. **命名空间是元素身份的一部分**：EPUB 3.3 规范性引用 XML Namespaces 1.0，元素身份 = `{命名空间 URI}local name`，不是裸 local name。标准词汇（`dc:title`、`opf:item`/`itemref`、OPF 容器元素与 `meta`、`epub:type`）必须按前缀绑定的 URI 识别，外来命名空间的同名入口不得冒充。XML 前缀区分大小写：`xmlns:X` 绑定的是 `X`，绑定键与元素/属性前缀都按原样比较，不得小写化绕过守卫。
2. **禁令只针对外部实体声明**：条款「MUST NOT」的宾语是 *external entity declarations in the internal DTD subset*，不覆盖内部一般实体，也不覆盖合法内部参数实体。
3. **外部标识符可出现但不加载**：DOCTYPE 可引用允许的外部标识符或不带标识符，内核不解析外部 DTD。

据此，实体与命名空间的终点精确划分为：

| 实体/语法类别 | 是否支持 | 依据 |
|---|---|---|
| 五个预定义实体（`lt/gt/amp/quot/apos`）+ 数字引用（十进制/十六进制） | ✅ 全部展开 | XML 1.0 预定义 |
| **DOCTYPE 内部子集声明的内部实体** `<!ENTITY name "value">` | ✅ 文本中替换值按标记重新解析（可产生元素），属性值按字符串展开；值可再含实体引用（递归，深度上限 8） | 规范未禁止，属合法 EPUB 输入；XML 1.0 §4.4.5 |
| **合法内部参数实体** `<!ENTITY % name "value">` | ✅ 接受声明；**仅在实体值内**按 `%name;` 展开（用已声明的参数实体构造后续实体值）；单独一条声明 `%d;` 形式的参数实体引用**不展开**、不产生声明；不进入正文实体表 | EPUB 3.3 未禁止内部参数实体声明；XML 1.0 §4.4.8 |
| `DOCTYPE` 外部标识符（`PUBLIC`/`SYSTEM` 的 DTD 引用） | ✅ 允许出现在前言；不加载外部 DTD | 规范条款明确 MAY |
| **外部实体声明**（一般或参数）`<!ENTITY x SYSTEM "…">` / `PUBLIC "…" "…"`、`<!ENTITY % x SYSTEM "…">` | ❌ 拒绝并给清晰错误 | 规范 MUST NOT（XXE 防线） |
| **命名空间识别** | ✅ 按 `{URI}local name`：前缀从作用域 `xmlns` 绑定解析（前缀大小写原样保留）；DC 词汇、OPF 容器/`item`/`itemref`/`meta`/`guide` 与 `epub:type` 都按 URI 守卫；URI 为空的历史语料按 local name 兼容；URI 非空且不匹配标准词汇时判为外来入口并忽略且告警 | XML Namespaces 1.0 + EPUB 3.3 §1.6 / §3.9 |

`lenient` 模式覆盖真实书的常见脏写法（未闭合的 HTML 空元素、大小写不一致的结束标签、**未声明实体按字面保留**）——但**不放宽**外部实体禁令，安全约束在两种模式下一致。

本划分回应了「合法文档语义不丢失」：内部实体与内部参数实体都是合法输入，之前把「参数实体」整体排除、把命名空间降格为「按 local name 比较」都是过度收窄，与所声明的 EPUB 3.3 终点冲突。现改为精确支持合法内部实体/参数实体与按 URI 的命名空间识别，只拒绝规范明令禁止的外部实体声明和外来命名空间同名入口。两类边界的合法输入与预期结果见 §2.9。

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

### 2.6 内部 DTD 实体与命名空间（EPUB 3.3 XML conformance）

规范条款（§XML conformance，原文见 §1.1）：DOCTYPE 可引用外部标识符或省略，但 **MUST NOT contain external entity declarations in the internal DTD subset**。据此，「内部实体支持、外部实体拒绝」是精确终点，不是折中。

**案例 A：内部实体标题（合法输入 → 预期解析结果）**

合法输入（`tests/fixtures/epub/internal-entities.epub` 的 OPF 片段）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE package [
  <!ENTITY book.title "内部实体书名：月亮与六便士">
  <!ENTITY book.lang "zh">
]>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title id="title-main" xml:lang="&book.lang;">&book.title;</dc:title>
    …
```

预期解析结果：

| 字段 | 期望值 | 断言 |
|---|---|---|
| `metadata.title` | `内部实体书名：月亮与六便士` | `EPUB3 内部实体标题与命名空间属性：合法输入语义不丢失` |
| `metadata.titles[0].lang` | `zh`（由 `&book.lang;` 展开） | 同上 |
| `main_title` | 同上（首个 `dc:title`，符合规范） | 同上 |

**案例 B：命名空间处理行为**

上例的 `<dc:title>` 带命名空间前缀 `dc:`，属性 `xml:lang` 带 `xml:`。解析行为（详见 §2.9 与 XML Namespaces 1.0）：

- 标签原样保留为 `dc:title`，属性值按实体规则展开；
- 解析时把作用域内 `xmlns` 绑定存到每个 `Element.ns`：`xmlns:dc="http://purl.org/dc/elements/1.1/"` 使 `dc` 绑定到 DC URI；
- 标准词汇用 `element_is(el, "title", DC_NS)` 判定——local name 相等**且**前缀绑定 URI 等于 DC URI；外来命名空间同名入口（如 `<x:title xmlns:x="urn:foreign">`）不算；
- 未声明命名空间的历史语料（URI 为空）按 local name 兼容命中，不破坏既有书库；
- `xml:lang` 经属性查找的 `local_name` 去前缀后读取（传 `"lang"`），语义不丢失；
- 内部实体展开发生在命名空间元素/属性**内部**，前缀与实体处理互不干扰。

对应 XML 层断言：`命名空间：外来同名入口不命中标准词汇`、`命名空间：前缀绑定沿作用域继承`、`命名空间：未声明前缀保持 local name 兼容`、`DOCTYPE 内部实体：标题与属性按语义展开`。

**案例 C：外部实体被拒绝、合法内部参数实体被接受（安全终点）**

| 合法输入？ | 输入片段 | 预期结果 |
|---|---|---|
| ❌ 违规 | `<!ENTITY xxe SYSTEM "file:///etc/passwd">` | `Err("…EPUB 禁止外部实体声明…")`，strict 与 lenient 一致 |
| ❌ 违规 | `<!ENTITY xxe PUBLIC "-//EVIL//DTD" "http://evil/x.dtd">` | 同上 |
| ❌ 违规 | `<!ENTITY % ext SYSTEM "http://evil/x.dtd">` | `Err("…EPUB 禁止外部实体声明（参数实体）…")`（外部标识符才是禁令对象） |
| ✅ 合法 | `<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "…/xhtml11.dtd">` | 正常解析，不加载外部 DTD |
| ✅ 合法 | `<!ENTITY % book.name "月亮与六便士"><!ENTITY title "书名：%book.name;">` | 参数实体值在内部子集展开，`&title;` 得到 `书名：月亮与六便士`（见 §2.9） |

断言：`DOCTYPE 外部参数实体与循环引用被拒绝`、`合法内部参数实体声明按语义展开`、`合法内部参数实体独立声明不影响文档解析`、`DOCTYPE 外部标识符仍可解析`。

实现位置：`src/xml/xml.mbt` 的 `skip_doctype` / `parse_internal_subset` / `decode_text_nodes` / `decode_entities_in` / `resolve_entity`；端到端断言在 `src/epub/epub_test.mbt`。磁盘夹具 `internal-entities.epub` 与内存 fixture 成对生成，直接进入 27 本内核对账。

## 2.7 语义保真复审后的修正（2026-11-25）

第三方审查指出：旧门禁只证明「能打开」，不证明「解析结果与规范语义等价」。本轮逐项修正并把每条变成可复现断言：

| 条款 | 合法输入 → 预期解析结果 | 断言 / 夹具 |
|---|---|---|
| §3.5.1 / §5.7.2 fallback | spine 指向 foreign item 且 fallback 到 XHTML → 章节列表包含 fallback 路径，并给出一条告警 | `fallback 链…`；`semantic-fallback.epub` |
| §3.1.3 SVG 核心内容文档 | `image/svg+xml` 直接进 spine → 计入章节，无需 fallback | `SVG 内容文档…`；`semantic-svg.epub` |
| §C.2 `epub:type` 多值 | `epub:type="toc landmarks"` → 命中 toc nav，不是地标 nav | `epub:type=…`；`semantic-nav-multivalue.epub` |
| EPUB2 `meta name/content` | `<meta name="cover" content="cover-img"/>` → 封面取 `cover.png`，即使另一张图排在前面 | `EPUB2 封面…`；`semantic-cover-legacy.epub` |
| §5.3.7 `package/@xml:lang` | package 上标注 → 未标注 `dc:title` 继承该语言 | `package@xml:lang…`；`semantic-package-lang.epub` |
| OPF2 `spine/@toc` | 多份 NCX → 按 toc id 取对应目录 | `EPUB2 spine@toc…` |
| Repeatable Dublin Core | publisher/description/date/source/type/coverage/relation/format 全保留；单数槽位为首值 | `可重复 Dublin Core…`；`semantic-multivalue-dc.epub` |
| §D.3.10 role scheme | 只采纳 `marc:relators` 的 role，自定义 scheme 不覆盖作者角色 | `可重复 Dublin Core…` |
| HTML5 混合内容 | 块容器里块子节点前后的裸文本各自成度量块 | `块容器内的裸文本不再丢失` |
| `<br>` / `<pre>` | `<br>` 贡献换行；`<pre>` 不折叠空白 | `br 与 pre 的文本语义不再丢失` |
| 列表 / 表格 | `ol/li` 产出带有序标记、层级、序号的 `BKList`；表格单元格文字进入 `Block.text` | `有序列表…`、`表格单元格文字…` |
| XML WFC / Char | 重复属性、`&#x0;` 被拒绝；属性值空白归一化；深度上限 512 | `重复属性与 &#x0;…`、`属性值空白…`、`合法深层嵌套…` |

不变式也补齐：`invariant_no_content_loss` 改称 `invariant_no_pagination_loss`（只承诺分页高度守恒），新增 `invariant_visible_text_preserved` 核对源文档可见字符是否全部进入块文本。后者在 `core.open_chapter` 中以告警暴露，避免 DOM→度量块阶段静默丢字。

## 2.8 复审残留项的收口（2026-11-25）

复审报告 `moonread-conformance-rereview.md` 残留 3 项 P3，均已收口：

| 项 | 合法输入 / 边界 → 预期结果 | 断言 / 夹具 |
|---|---|---|
| R1 `epub:type` 前缀写死 | `<html xmlns:o="http://www.idpf.org/2007/ops">` + `o:type="toc landmarks"` → 命中目录 nav；普通无前缀 `type` 不算 | `绑定到 OPS 命名空间的任意前缀…`；`semantic-nav-prefix.epub`。沿 DOM 作用域累积绑定到 OPS URI 的前缀，默认保留 `epub` 兼容省略声明的历史语料 |
| R2 role scheme 子串误判 | `scheme="http://evil.example/marc:relators"` → 不采纳该 role，回退 `aut` | `role scheme 子串匹配不再覆盖作者角色`；`semantic-scheme-substring.epub`（探针对账 `creator_role=aut`） |
| R3 超高不可拆标题 | 标题高于整页内容区 → 仍独占一页不丢内容，但单独给出溢出告警 | `超高不可拆块被检出，普通标题不误报`；`oversized_unbreakable_blocks` 在 `core.open_chapter` 中输出告警 |

另外，`mimetype` 的 STORED 压缩方式仍无法校验：当前 `Archive` 模型不记录 ZIP 压缩方法，属只读场景的检测缺口，不影响语义保真。

## 2.9 本轮驳回收口：命名空间终点与内部参数实体（2026-11-26）

审核指出：附件声明的「按 local name 比较、不做 URI 归一化」与「参数实体一律拒绝」和所声明的 EPUB 3.3 兼容终点冲突，不能支撑「合法文档语义不丢失」。本轮按规范原文修正终点，并用两组合法输入说明预期解析结果。

**终点修正（对照 §1.1）**：

| 旧声明（冲突） | 新终点（符合标准） | 规范依据 |
|---|---|---|
| 命名空间不归一化，只按 local name 比较 | 元素身份 = `{URI}local name`；标准词汇按前缀绑定的 URI 识别；外来命名空间同名入口忽略 | EPUB 3.3 §3.9 规范性引用 XML Namespaces 1.0；§1.6 保留前缀 |
| 参数实体 `<!ENTITY % …>` 一律拒绝 | 合法**内部**参数实体接受并在内部子集展开；带 SYSTEM/PUBLIC **外部标识符**的参数实体才拒绝 | EPUB 3.3 §3.9 的 MUST NOT 宾语是「external entity declarations in the internal DTD subset」，不含内部参数实体 |

**案例 D：外来命名空间同名入口（合法输入 → 预期解析结果）**

合法输入（OPF 元数据，两个元素 local name 都是 `title`）：

```xml
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:x="urn:foreign">
  <dc:title>真标题</dc:title>
  <x:title>外来污染</x:title>
</metadata>
```

预期解析结果：

| 字段 | 期望值 | 说明 |
|---|---|---|
| `metadata.title` | `真标题` | 只取 DC 命名空间的首个 `dc:title` |
| `metadata.titles.length()` | `1` | `x:title` 不是 DC 词汇，不计入 |
| `warnings` | 含一条「忽略外来命名空间的 dc 同名入口」 | 明确告知外来入口被忽略，不静默 |

大小写变体同样成立：`<X:title xmlns:X="urn:foreign">` 中的 `X` 是独立前缀，绑定键按原样存储、按原样查找；不得把 `xmlns:X` 小写化成 `x` 后让 `<X:title>` 解析出空 URI、再当作历史语料命中 `dc:title`。此守卫同样覆盖非 DC 标准词汇：外来 `<X:meta property="dcterms:modified">` 不写 `modified`，外来 `<X:item>` / `<X:itemref>` 不进 manifest/spine，外来 `<X:metadata>` / `<X:manifest>` / `<X:spine>` 不冒充 OPF 容器，外来 `X:type="toc"` 不冒充 OPS 导航语义；每类忽略均给告警。

未声明命名空间的旧语料 `<metadata><title>兼容</title></metadata>` 仍按 local name 命中（`namespace_uri` 为空即兼容），不破坏既有书库。断言：`外来命名空间同名 title 不污染 dc 元数据`、`命名空间：大小写前缀按原样绑定，不能绕过外来识别`、`OPF 标准词汇守卫覆盖 meta/manifest/spine/rights/subject`、`OPF 容器元素外来命名空间被忽略`、`nav 前缀按大小写原样匹配，外来大写前缀不冒充 OPS`。夹具：`semantic-namespace-foreign.epub`。

**案例 E：合法内部参数实体声明（合法输入 → 预期解析结果）**

合法输入（DOCTYPE 内部子集；XML 1.0 §4.4.8 允许）：

```xml
<!DOCTYPE package [
  <!ENTITY % book.name "月亮与六便士">
  <!ENTITY book.title "内部实体书名：%book.name;">
]>
<package …><metadata …><dc:title>&book.title;</dc:title></metadata>…</package>
```

预期解析结果：

| 字段 | 期望值 | 说明 |
|---|---|---|
| `%book.name;` | 在实体值内展开为 `月亮与六便士` | 参数实体只在 DTD **实体值内**生效，不进入正文实体表；声明层出现 `%d;` 单独代表一条声明时不展开（见 §1.1 表） |
| `metadata.title` | `内部实体书名：月亮与六便士` | 一般实体 `book.title` 的值中 `%book.name;` 先展开，正文 `&book.title;` 得到完整标题 |
| 非法 `<!ENTITY % ext SYSTEM "…">` | `Err("…禁止外部实体声明（参数实体）…")` | 外部标识符才是 EPUB 禁令对象，strict/lenient 一致 |

内部子集扫描按 XML 词法跳过引号、注释与 PI：实体值中的 `]` / `>` 不提前结束子集，注释中出现的 `<!ENTITY … SYSTEM …>` 不触发禁令。断言：`DOCTYPE 实体值内的 ] 与 > 不提前结束内部子集`、`DOCTYPE 注释中的外部实体样例不触发禁令`。夹具：`semantic-param-entity.epub`。

实现位置：`src/xml/xml.mbt` 的 `XP.param_entities` / `skip_doctype` / `parse_internal_subset` / `expand_param_value` / `merge_ns_scope` / `Element.ns` / `element_is` / `namespace_uri`；EPUB 层守卫在 `src/epub/parse.mbt` 的 `foreign_ns` / `find_opf_child` / `dc_vocabulary` / `with_ops_prefixes`。

## 3. 可复现的验证命令

```bash
# 四端编译 + 测试 + 一致性 + 语料对账 + 形式化证明（需 MoonBit 工具链）
bash scripts/ci.sh

# 只看内核对账：磁盘 EPUB 经 fzip + 内核解析，与 manifest 的标题/章节/目录/资源逐项核对
python3 tools/corpus_check.py --require-manifest --require-probe
```

当前结果：四端各 166 项测试通过；跨端输出一致；29 本 EPUB（27 自建 + 2 第三方公版）内核对账全部通过；`moon prove` 在 CI 的 Linux 任务中由 SMT 求解器验证。

## 4. 语料来源

- 27 本自建最小 EPUB：由 `tools/gen_fixtures.py` 与 `src/epub/fixture.mbt` 成对生成，Apache-2.0，见 `tests/fixtures/manifest.json`。其中 `rich-metadata.epub` 承载本文 §2.2–2.4 的合法语义样例，`internal-entities.epub` 承载 §2.6 的内部实体标题与命名空间案例，`semantic-*` 承载 §2.7–2.8 的逐条款回归；`semantic-namespace-foreign.epub` 与 `semantic-param-entity.epub` 分别承载 §2.9 的案例 D / E。
- 2 本第三方公版 EPUB：来源 URL 与 SHA-256 钉在 `tests/corpus/manifest.json`，避免上游静默变更。
