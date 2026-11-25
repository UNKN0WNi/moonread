///|
/// 内存 EPUB 构造器。
///
/// 这些构造器同时服务两个目的：
/// 1. `moon test` 的语料（出口条件要求「≥5 本，含 EPUB2/3」，
///    要求「自建最小 EPUB ≥15」——用参数化生成器覆盖，见 `all_fixtures`）；
/// 2. `tools/gen_fixtures.py` 的**期望值参照**：磁盘上的 .epub 与这里生成的
///    归档必须解析出同样的 manifest.json 断言。
#derive(Debug, Eq)
pub(all) struct FixtureSpec {
  mut title : String
  mut creator : String
  mut language : String
  /// `(item id, 章节标题)`；正文由 `chapter_xhtml` 生成。
  mut chapters : Array[(String, String)]
  mut epub3 : Bool
  mut with_nav : Bool
  mut with_ncx : Bool
  mut with_css : Bool
  mut with_cover : Bool
  /// 故意制造脏数据用：true 时不写 META-INF/container.xml。
  mut omit_container : Bool
  /// true 时 mimetype 放在最后一个条目（违反规范，测试降级）。
  mut mimetype_last : Bool
  /// true 时 spine 引用一个不存在的 idref（测试降级）。
  mut broken_idref : Bool
  /// true 时 OPF 写成非法 XML（测试不 panic）。
  mut malformed_opf : Bool
  /// true 时写入 META-INF/encryption.xml（测试 DRM 检测）。
  mut encrypted : Bool
  /// true 时写合法 EPUB3 富语义元数据：多 dc:title + xml:lang、
  /// `<meta refines>` 角色/别名、nav 的 span 分组与 hidden 分支。
  mut rich_metadata : Bool
  /// true 时 OPF 写 DOCTYPE 内部实体声明，标题用 &title; 引用；
  /// 章节正文用命名空间前缀元素引用实体（EPUB 3.3 合法输入）。
  mut internal_entities : Bool
  /// 语义对账变体：每条只针对一项 EPUB 3.3 条款，避免「另一条路径恰好通过」
  /// 掩盖实现缺陷。取值见 `all_fixtures()`。
  mut semantic_variant : String
}

///|
pub fn simple_spec() -> FixtureSpec {
  FixtureSpec::{
    title: "MoonRead 样例",
    creator: "MOONBIT",
    language: "zh",
    chapters: [("ch1", "第一章"), ("ch2", "第二章")],
    epub3: true,
    with_nav: true,
    with_ncx: false,
    with_css: true,
    with_cover: false,
    omit_container: false,
    mimetype_last: false,
    broken_idref: false,
    malformed_opf: false,
    encrypted: false,
    rich_metadata: false,
    internal_entities: false,
    semantic_variant: "",
  }
}

///|
pub fn chapter_xhtml(title : String) -> String {
  @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
    "<html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"zh\">",
    "<head><title>" + title + "</title>",
    "<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>",
    "</head>",
    "<body>",
    "<h1>" + title + "</h1>",
    "<p>Hello from MoonBit.</p>",
    "<p>第二段用于撑出分页所需的块高度。</p>",
    "</body>",
    "</html>",
  ])
}

///|
fn opf_xml(spec : FixtureSpec) -> String {
  if spec.malformed_opf {
    return @util.join_nl([
      "<?xml version=\"1.0\"?>", "<package version=\"3.0\"", "<broken>",
    ])
  }
  let lines : Array[String] = []
  lines.push("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
  if spec.internal_entities {
    // 合法 EPUB 3.3：DOCTYPE 内部子集声明内部实体（非外部实体）。
    // 标题值由实体提供，验证「合法输入语义不丢失」。
    lines.push("<!DOCTYPE package [")
    lines.push("  <!ENTITY book.title \"" + spec.title + "\">")
    lines.push("  <!ENTITY book.lang \"" + spec.language + "\">")
    lines.push("]>")
  }
  let ver = if spec.epub3 { "3.0" } else { "2.0" }
  let lang_attr = if spec.semantic_variant == "package-lang" {
    " xml:lang=\"zh-Hant\""
  } else {
    ""
  }
  lines.push(
    "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"" +
    ver +
    "\"" +
    lang_attr +
    " unique-identifier=\"uid\">",
  )
  lines.push("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">")
  lines.push(
    "    <dc:identifier id=\"uid\">urn:uuid:moonread-sample</dc:identifier>",
  )
  if spec.internal_entities {
    // 合法 EPUB 3.3：标题文本与属性都引用内部实体。
    lines.push(
      "    <dc:title id=\"title-main\" xml:lang=\"&book.lang;\">&book.title;</dc:title>",
    )
  } else if spec.rich_metadata {
    // 合法 EPUB 3.3：首个 dc:title 是主标题；另有带 xml:lang 的别名标题。
    lines.push(
      "    <dc:title id=\"title-main\" xml:lang=\"en\">" +
      spec.title +
      "</dc:title>",
    )
    lines.push(
      "    <dc:title id=\"title-alt\" xml:lang=\"ja\">副題サンプル</dc:title>",
    )
    // 合法 EPUB 3.3：creator 角色用 <meta refines> 表达，而非 opf:role 属性。
    lines.push(
      "    <dc:creator id=\"creator-main\">" + spec.creator + "</dc:creator>",
    )
    lines.push("    <dc:creator id=\"creator-ill\">Illustrator</dc:creator>")
    lines.push(
      "    <meta refines=\"#creator-main\" property=\"role\" scheme=\"marc:relators\">aut</meta>",
    )
    lines.push(
      "    <meta refines=\"#creator-ill\" property=\"role\" scheme=\"marc:relators\">ill</meta>",
    )
    lines.push(
      "    <meta refines=\"#creator-main\" property=\"alternate-script\" xml:lang=\"ja\">著者サンプル</meta>",
    )
    lines.push(
      "    <meta refines=\"#creator-main\" property=\"file-as\">MOONBIT, </meta>",
    )
  } else {
    lines.push("    <dc:title>" + spec.title + "</dc:title>")
    lines.push("    <dc:creator>" + spec.creator + "</dc:creator>")
  }
  lines.push("    <dc:language>" + spec.language + "</dc:language>")
  if spec.semantic_variant == "multivalue-dc" {
    lines.push(
      "    <dc:publisher>P1</dc:publisher><dc:publisher>P2</dc:publisher>",
    )
    lines.push(
      "    <dc:description>D1</dc:description><dc:description>D2</dc:description>",
    )
    lines.push("    <dc:date>2026-01-01</dc:date><dc:date>2026-02-02</dc:date>")
    lines.push("    <dc:source>S1</dc:source><dc:source>S2</dc:source>")
    lines.push("    <dc:type>Text</dc:type><dc:coverage>World</dc:coverage>")
    lines.push(
      "    <dc:relation>R</dc:relation><dc:format>application/xhtml+xml</dc:format>",
    )
  }
  if spec.epub3 {
    lines.push(
      "    <meta property=\"dcterms:modified\">2026-11-19T00:00:00Z</meta>",
    )
  }
  if spec.with_cover || spec.semantic_variant == "cover-legacy" {
    lines.push("    <meta name=\"cover\" content=\"cover-img\"/>")
  }
  lines.push("  </metadata>")
  lines.push("  <manifest>")
  if spec.with_nav {
    lines.push(
      "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
    )
  }
  for kv in spec.chapters {
    lines.push(
      "    <item id=\"" +
      kv.0 +
      "\" href=\"" +
      kv.0 +
      ".xhtml\" media-type=\"application/xhtml+xml\"/>",
    )
  }
  if spec.with_css {
    lines.push(
      "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
    )
  }
  if spec.semantic_variant == "cover-legacy" {
    // EPUB2 遗留方式：没有 properties=cover-image，且另一张图排在前面。
    lines.push(
      "    <item id=\"other-img\" href=\"other.png\" media-type=\"image/png\"/>",
    )
    lines.push(
      "    <item id=\"cover-img\" href=\"cover.png\" media-type=\"image/png\"/>",
    )
  }
  if spec.with_cover {
    lines.push(
      "    <item id=\"cover-img\" href=\"cover.png\" media-type=\"image/png\" properties=\"cover-image\"/>",
    )
  }
  if spec.semantic_variant == "fallback" {
    lines.push(
      "    <item id=\"foreign\" href=\"foreign.jpg\" media-type=\"image/jpeg\" fallback=\"ch1\"/>",
    )
  }
  if spec.semantic_variant == "svg" {
    lines.push(
      "    <item id=\"svg\" href=\"page.svg\" media-type=\"image/svg+xml\"/>",
    )
  }
  if spec.with_ncx {
    lines.push(
      "    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
    )
  }
  lines.push("  </manifest>")
  lines.push("  <spine>")
  if spec.with_ncx {
    lines.push("    <itemref idref=\"ncx\" linear=\"no\"/>")
  }
  for kv in spec.chapters {
    lines.push("    <itemref idref=\"" + kv.0 + "\"/>")
  }
  if spec.semantic_variant == "fallback" {
    lines.push("    <itemref idref=\"foreign\"/>")
  }
  if spec.semantic_variant == "svg" {
    lines.push("    <itemref idref=\"svg\"/>")
  }
  if spec.broken_idref {
    lines.push("    <itemref idref=\"ghost\"/>")
  }
  lines.push("  </spine>")
  lines.push("</package>")
  @util.join_nl(lines)
}

///|
fn nav_xhtml(spec : FixtureSpec) -> String {
  if spec.semantic_variant == "nav-multivalue" {
    let item_lines : Array[String] = []
    for kv in spec.chapters {
      item_lines.push(
        "<li><a href=\"" + kv.0 + ".xhtml\">" + kv.1 + "</a></li>",
      )
    }
    let items = @util.join_nl(item_lines)
    return @util.join_nl([
      "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">",
      "<head><title>目录</title></head><body>", "<nav epub:type=\"landmarks\"><ol><li><a href=\"ch1.xhtml\">地标项</a></li></ol></nav>",
      "<nav epub:type=\"toc landmarks\"><h1>目录</h1><ol>", items, "</ol></nav>",
      "</body></html>",
    ])
  }
  let lines : Array[String] = []
  lines.push("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
  lines.push(
    "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\">",
  )
  lines.push("<head><title>目录</title></head>")
  lines.push("<body>")
  lines.push("<nav epub:type=\"toc\" id=\"toc\">")
  lines.push("<h1>目录</h1>")
  lines.push("<ol>")
  if spec.rich_metadata {
    // 合法 EPUB 3.3：span 分组标题（无 href）+ 嵌套 ol；
    // 组内第二个 ol 带 hidden 空值，隐藏仅供机器处理的分支。
    lines.push("<li><span>分组：样例章</span>")
    lines.push("<ol>")
  }
  for kv in spec.chapters {
    lines.push("<li><a href=\"" + kv.0 + ".xhtml\">" + kv.1 + "</a></li>")
  }
  if spec.rich_metadata {
    lines.push(
      "<li hidden=\"\"><a href=\"" +
      (if spec.chapters.length() > 0 { spec.chapters[0].0 } else { "ch1" }) +
      ".xhtml\">隐藏分支</a></li>",
    )
    lines.push("</ol></li>")
  }
  lines.push("</ol>")
  lines.push("</nav>")
  lines.push("</body>")
  lines.push("</html>")
  @util.join_nl(lines)
}

///|
fn ncx_xml(spec : FixtureSpec) -> String {
  let lines : Array[String] = []
  lines.push("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
  lines.push(
    "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">",
  )
  lines.push("  <head>")
  lines.push(
    "    <meta name=\"dtb:uid\" content=\"urn:uuid:moonread-sample\"/>",
  )
  lines.push("    <meta name=\"dtb:depth\" content=\"1\"/>")
  lines.push("  </head>")
  lines.push("  <docTitle><text>" + spec.title + "</text></docTitle>")
  lines.push("  <navMap>")
  let mut order = 1
  for kv in spec.chapters {
    lines.push(
      "    <navPoint id=\"np" +
      order.to_string() +
      "\" playOrder=\"" +
      order.to_string() +
      "\">",
    )
    lines.push("      <navLabel><text>" + kv.1 + "</text></navLabel>")
    lines.push("      <content src=\"" + kv.0 + ".xhtml\"/>")
    lines.push("    </navPoint>")
    order = order + 1
  }
  lines.push("  </navMap>")
  lines.push("</ncx>")
  @util.join_nl(lines)
}

///|
fn encryption_xml() -> String {
  @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<encryption xmlns=\"https://www.w3.org/2001/04/xmlenc#\"",
    "           xmlns:epub=\"http://www.idpf.org/2007/ops\">", "  <EncryptedModule catalog=\"true\" NameSpace=\"urn:oasis:names:tc:opendocument:xmlns:container\">",
    "    <EncryptionMethod Algorithm=\"http://www.w3.org/2001/04/xmlenc#rsa-oaep-mgf1p\"/>",
    "  </EncryptedModule>", "</encryption>",
  ])
}

///|
/// 按 spec 生成归档。条目顺序遵守 EPUB 规范（mimetype 第一，除非 spec 故意打乱）。
pub fn build(spec : FixtureSpec) -> @container.Archive {
  let items : Array[(String, String)] = []
  let head : Array[(String, String)] = [("mimetype", "application/epub+zip")]
  if !spec.mimetype_last {
    for kv in head {
      items.push(kv)
    }
  }
  if !spec.omit_container {
    items.push(
      (
        "META-INF/container.xml",
        @util.join_nl([
          "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">",
          "  <rootfiles>", "    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>",
          "  </rootfiles>", "</container>",
        ]),
      ),
    )
  }
  if spec.encrypted {
    items.push(("META-INF/encryption.xml", encryption_xml()))
  }
  items.push(("OEBPS/content.opf", opf_xml(spec)))
  if spec.with_nav {
    items.push(("OEBPS/nav.xhtml", nav_xhtml(spec)))
  }
  if spec.with_ncx {
    items.push(("OEBPS/toc.ncx", ncx_xml(spec)))
  }
  for kv in spec.chapters {
    items.push(("OEBPS/" + kv.0 + ".xhtml", chapter_xhtml(kv.1)))
  }
  if spec.with_css {
    items.push(
      (
        "OEBPS/style.css",
        @util.join_nl([
          "body { margin: 0; padding: 1em; }", "h1 { font-size: 1.6em; page-break-before: always; }",
          "p { line-height: 1.6; text-align: justify; }",
        ]),
      ),
    )
  }
  if spec.with_cover || spec.semantic_variant == "cover-legacy" {
    items.push(("OEBPS/cover.png", "PNG-BYTES-PLACEHOLDER"))
  }
  if spec.semantic_variant == "cover-legacy" {
    items.push(("OEBPS/other.png", "PNG-BYTES-PLACEHOLDER"))
  }
  if spec.semantic_variant == "fallback" {
    items.push(("OEBPS/foreign.jpg", "JPEG-BYTES-PLACEHOLDER"))
  }
  if spec.semantic_variant == "svg" {
    items.push(
      ("OEBPS/page.svg", "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"),
    )
  }
  if spec.mimetype_last {
    for kv in head {
      items.push(kv)
    }
  }
  @container.archive("fixture.epub", items)
}

///| 语料集合：出口条件要求 ≥5 本且含 EPUB2/3；要求自建 ≥15。

///|
/// 每一项都是一个可断言的变体（正常 / 降级 / 脏数据），不是同构复制。
pub fn all_fixtures() -> Array[(String, FixtureSpec)] {
  let out : Array[(String, FixtureSpec)] = []
  out.push(("epub3-basic", simple_spec()))
  let s2 = simple_spec()
  s2.epub3 = false
  s2.with_ncx = true
  s2.with_nav = false
  out.push(("epub2-ncx", s2))
  let s3 = simple_spec()
  s3.chapters = []
  out.push(("zero-chapters", s3))
  let s4 = simple_spec()
  let many : Array[(String, String)] = []
  let mut i = 1
  while i <= 30 {
    many.push(("c" + i.to_string(), "第" + i.to_string() + "章"))
    i = i + 1
  }
  s4.chapters = many
  out.push(("thirty-chapters", s4))
  let s5 = simple_spec()
  s5.with_nav = false
  out.push(("no-nav", s5))
  let s6 = simple_spec()
  s6.omit_container = true
  out.push(("no-container", s6))
  let s7 = simple_spec()
  s7.mimetype_last = true
  out.push(("mimetype-last", s7))
  let s8 = simple_spec()
  s8.broken_idref = true
  out.push(("broken-idref", s8))
  let s9 = simple_spec()
  s9.malformed_opf = true
  out.push(("malformed-opf", s9))
  let s10 = simple_spec()
  s10.encrypted = true
  out.push(("encrypted", s10))
  let s11 = simple_spec()
  s11.with_cover = true
  out.push(("with-cover", s11))
  let s12 = simple_spec()
  s12.with_css = false
  out.push(("no-css", s12))
  let s13 = simple_spec()
  s13.title = "带实体 &lt;标记&gt; 的书"
  out.push(("entity-title", s13))
  let s14 = simple_spec()
  s14.chapters = [("a", "A"), ("b", "B"), ("c", "C"), ("d", "D"), ("e", "E")]
  s14.with_ncx = true
  out.push(("five-both-toc", s14))
  let s15 = simple_spec()
  s15.creator = ""
  s15.language = ""
  out.push(("missing-creator-lang", s15))
  let s16 = simple_spec()
  s16.title = "Rich Metadata Sample"
  s16.creator = "MOONBIT"
  s16.rich_metadata = true
  out.push(("rich-metadata", s16))
  let s17 = simple_spec()
  s17.title = "内部实体书名：月亮与六便士"
  s17.internal_entities = true
  out.push(("internal-entities", s17))
  // 语义对账：每条只验证一个规范条款，避免另一条路径掩盖缺陷。
  for
    variant in [
      "fallback", "svg", "nav-multivalue", "cover-legacy", "package-lang", "multivalue-dc",
    ] {
    let s = simple_spec()
    s.semantic_variant = variant
    out.push(("semantic-" + variant, s))
  }
  out
}
