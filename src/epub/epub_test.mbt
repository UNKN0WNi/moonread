///|
/// EPUB 容器层集成测试（ / 出口条件 / 出口条件的可断言版本）。
fn open_fixture(name : String) -> @epub.EpubBook {
  let specs = @epub.all_fixtures()
  let mut picked : @epub.FixtureSpec? = None
  for kv in specs {
    if kv.0 == name {
      picked = Some(kv.1)
    }
  }
  match picked {
    None => panic()
    Some(sp) =>
      match @epub.open(@epub.build(sp)) {
        Ok(b) => b
        Err(_) => panic()
      }
  }
}

///|
fn open_result(name : String) -> Result[@epub.EpubBook, String] {
  let specs = @epub.all_fixtures()
  let mut picked : @epub.FixtureSpec? = None
  for kv in specs {
    if kv.0 == name {
      picked = Some(kv.1)
    }
  }
  match picked {
    None => Err("没有这个 fixture")
    Some(sp) => @epub.open(@epub.build(sp))
  }
}

///|
fn warning_count(b : @epub.EpubBook, needle : String) -> Int32 {
  let mut n = 0
  for w in b.warnings {
    if @util.contains(w, needle) {
      n = n + 1
    }
  }
  n
}

///|
test "EPUB3 基本书：元数据 / 清单 / spine / 章节 / 目录" {
  let b = open_fixture("epub3-basic")
  assert_true(
    b.metadata.title == "MoonRead 样例",
    msg="标题：" + b.metadata.title,
  )
  assert_true(b.metadata.language == "zh", msg="语言")
  assert_true(@epub.primary_creator(b.metadata) == "MOONBIT", msg="作者")
  assert_true(
    @util.contains(b.metadata.modified, "2026-11-19"),
    msg="dcterms:modified：" + b.metadata.modified,
  )
  assert_true(
    b.opf_path == "OEBPS/content.opf",
    msg="OPF 路径：" + b.opf_path,
  )
  assert_true(b.package_version == "3.0", msg="package version")
  assert_true(b.container_version == "1.0", msg="container version")
  assert_true(
    b.manifest.length() == 4,
    msg="manifest 4 项（nav/ch1/ch2/css）",
  )
  assert_true(b.spine.length() == 2, msg="spine 2 项")
  assert_true(@epub.chapter_paths(b).length() == 2, msg="两章")
  assert_true(
    @epub.chapter_paths(b)[0] == "OEBPS/ch1.xhtml",
    msg="章节顺序即 spine 顺序",
  )
  assert_true(@epub.css_paths(b).length() == 1, msg="一份 CSS")
  assert_true(
    b.warnings.length() == 0,
    msg="规范文档不应有告警：" + @epub.report(b),
  )
}

///|
test "章节正文可读（渲染层输入）" {
  let b = open_fixture("epub3-basic")
  match @epub.read_chapter(b, 0) {
    Err(_) => panic()
    Ok(text) => {
      assert_true(
        @util.contains(text, "Hello from MoonBit."),
        msg="正文含样例段落",
      )
      assert_true(
        @util.contains(text, "<h1>第一章</h1>"),
        msg="正文含标题",
      )
    }
  }
  assert_true(
    match @epub.read_chapter(b, 9) {
      Err(_) => true
      Ok(_) => false
    },
    msg="越界序号返回错误而非 panic",
  )
  assert_true(@epub.read_all_css(b).length() == 1, msg="CSS 源码可读")
}

///|
test "EPUB3 nav 目录树" {
  let b = open_fixture("epub3-basic")
  assert_true(b.nav_toc.length() == 2, msg="两个目录项")
  assert_true(b.nav_toc[0].label == "第一章", msg="目录标题")
  assert_true(b.nav_toc[0].path == "OEBPS/ch1.xhtml", msg="目录路径")
  assert_true(@epub.count_nav_points(b.nav_toc) == 2, msg="无嵌套")
  assert_true(b.ncx_toc.length() == 0, msg="无 NCX")
}

///|
test "EPUB2 + NCX 双支持" {
  let b = open_fixture("epub2-ncx")
  assert_true(b.package_version == "2.0", msg="package version 2.0")
  assert_true(b.ncx_toc.length() == 2, msg="NCX 两项")
  assert_true(b.ncx_toc[1].label == "第二章", msg="NCX 标签")
  assert_true(b.nav_toc.length() == 0, msg="无 nav")
  assert_true(
    @epub.chapter_paths(b).length() == 2,
    msg="NCX 不计入章节（linear=no）",
  )
  assert_true(
    warning_count(b, "dcterms:modified") == 1,
    msg="EPUB2 缺 modified 只告警",
  )
}

///|
test "缺 nav：降级可用" {
  let b = open_fixture("no-nav")
  assert_true(@epub.chapter_paths(b).length() == 2, msg="正文仍可读")
  assert_true(b.nav_toc.length() == 0, msg="目录为空")
  assert_true(
    warning_count(b, "properties=nav") == 1,
    msg="应告警缺少 nav",
  )
}

///|
test "缺 container.xml：扫描 *.opf 降级" {
  let b = open_fixture("no-container")
  assert_true(
    b.opf_path == "OEBPS/content.opf",
    msg="扫描定位 OPF：" + b.opf_path,
  )
  assert_true(@epub.chapter_paths(b).length() == 2, msg="章节仍完整")
  assert_true(warning_count(b, "container.xml") >= 1, msg="应告警")
}

///|
test "mimetype 不在首位：告警但不失败" {
  let b = open_fixture("mimetype-last")
  assert_true(warning_count(b, "mimetype") == 1, msg="mimetype 顺序告警")
  assert_true(@epub.chapter_paths(b).length() == 2, msg="仍可阅读")
}

///|
test "spine 引用不存在的 idref：降级保留" {
  let b = open_fixture("broken-idref")
  assert_true(b.spine.length() == 3, msg="三条 itemref")
  assert_true(!b.spine[2].resolved, msg="第三条未解析")
  assert_true(b.spine[2].idref == "ghost", msg="保留 idref 供诊断")
  assert_true(@epub.chapter_paths(b).length() == 2, msg="章节数不受影响")
  assert_true(warning_count(b, "ghost") == 1, msg="告警点名 ghost")
}

///|
test "非法 OPF：返回 Err 且不 panic" {
  match open_result("malformed-opf") {
    Ok(_) => panic()
    Err(e) => assert_true(e.length() > 0, msg="错误信息非空：" + e)
  }
}

///|
test "加密检测：仅提示不解密" {
  let b = open_fixture("encrypted")
  assert_true(b.encryption.encrypted, msg="应检测到加密")
  assert_true(
    @util.contains(b.encryption.schemes, "rsa-oaep"),
    msg="算法登记：" + b.encryption.schemes,
  )
  assert_true(
    @util.contains(b.encryption.message, "不实现解密"),
    msg="提示语",
  )
  assert_true(warning_count(b, "加密") >= 1, msg="告警包含加密")
}

///|
test "封面解析：meta name=cover 与 cover-image" {
  let b = open_fixture("with-cover")
  assert_true(
    b.metadata.cover_path == "OEBPS/cover.png",
    msg="封面路径：" + b.metadata.cover_path,
  )
  assert_true(@epub.image_paths(b).length() == 1, msg="manifest 图片一项")
}

///|
test "无 CSS：css_paths 为空但仍可打开" {
  let b = open_fixture("no-css")
  assert_true(@epub.css_paths(b).length() == 0, msg="无 CSS")
  assert_true(@epub.chapter_paths(b).length() == 2, msg="正文正常")
}

///|
test "标题内实体会被解码" {
  let b = open_fixture("entity-title")
  assert_true(
    b.metadata.title == "带实体 <标记> 的书",
    msg="解码结果：" + b.metadata.title,
  )
}

///|
test "缺作者与语言：分别告警" {
  let b = open_fixture("missing-creator-lang")
  assert_true(warning_count(b, "dc:language") == 1, msg="语言告警")
  assert_true(b.metadata.creators.length() == 0, msg="无作者不报错")
}

///|
test "零章节与三十章" {
  let b0 = open_fixture("zero-chapters")
  assert_true(@epub.chapter_paths(b0).length() == 0, msg="零章")
  assert_true(b0.spine.length() == 0, msg="空 spine")
  assert_true(warning_count(b0, "spine 为空") == 1, msg="空 spine 告警")
  let b30 = open_fixture("thirty-chapters")
  assert_true(@epub.chapter_paths(b30).length() == 30, msg="三十章")
  assert_true(@epub.count_nav_points(b30.nav_toc) == 30, msg="目录三十项")
  assert_true(b30.manifest.length() == 32, msg="nav + 30 章 + css")
}

///|
test "语料集合规模满足 （自建 ≥15）" {
  assert_true(
    @epub.all_fixtures().length() >= 15,
    msg="fixture 数量：" + @epub.all_fixtures().length().to_string(),
  )
}

///|
test "全部 fixture 打开要么成功要么清晰报错，绝不 panic" {
  let mut ok_count = 0
  let mut err_count = 0
  for kv in @epub.all_fixtures() {
    match @epub.open(@epub.build(kv.1)) {
      Ok(_) => ok_count = ok_count + 1
      Err(_) => err_count = err_count + 1
    }
  }
  assert_true(
    ok_count + err_count == @epub.all_fixtures().length(),
    msg="全部覆盖",
  )
  assert_true(
    err_count <= 1,
    msg="最多一个 fixture 应彻底失败（malformed-opf）",
  )
}

///|
test "describe / report 输出可读" {
  let b = open_fixture("epub3-basic")
  assert_true(
    @util.contains(@epub.describe(b), "标题 = MoonRead 样例"),
    msg="describe",
  )
  assert_true(
    @util.contains(@epub.describe(b), "章节数 = 2"),
    msg="章节计数",
  )
  let r = @epub.report(open_fixture("no-nav"))
  assert_true(@util.contains(r, "--- 告警 ---"), msg="report 带告警段")
}

///|
test "严格模式与默认模式的差异被记录" {
  match open_result("no-container") {
    Err(_) => panic()
    Ok(b) =>
      assert_true(
        warning_count(b, "宽松模式") == 1,
        msg="应记录「严格失败后转宽松」：" +
          @util.join_nl(b.warnings),
      )
  }
}

///|
test "guide 解析（EPUB2 遗留）" {
  match @xml.parse_document(opf_with_guide()) {
    Err(_) => panic()
    Ok(root) => {
      let warnings : Array[String] = []
      let g = @epub.parse_guide("OEBPS/content.opf", root, warnings)
      assert_true(g.length() == 2, msg="两条 guide reference")
      assert_true(g[0].typ == "toc", msg="type")
      assert_true(
        g[0].path == "OEBPS/nav.xhtml",
        msg="guide href 按 OPF 路径解析：" + g[0].path,
      )
    }
  }
}

///|
/// 以下测试对应复审要求「合法输入与预期解析结果」。
/// 输入是符合 EPUB 3.3 的合法结构，断言语义不丢失。
test "EPUB3 多 dc:title：主标题仍取首个，全部标题与 xml:lang 保留" {
  let b = open_fixture("rich-metadata")
  assert_true(
    b.metadata.titles.length() == 2,
    msg="两个 dc:title：" + b.metadata.titles.length().to_string(),
  )
  assert_true(
    @epub.main_title(b.metadata) == "Rich Metadata Sample",
    msg="主标题=首个 dc:title，符合 EPUB 3.3",
  )
  assert_true(b.metadata.title == "Rich Metadata Sample", msg="旧字段兼容")
  assert_true(
    b.metadata.titles[0].lang == "en",
    msg="首标题 xml:lang：" + b.metadata.titles[0].lang,
  )
  assert_true(
    b.metadata.titles[1].value == "副題サンプル",
    msg="别名标题未被丢弃：" + b.metadata.titles[1].value,
  )
  assert_true(
    b.metadata.titles[1].lang == "ja",
    msg="别名语言：" + b.metadata.titles[1].lang,
  )
  assert_true(
    b.metadata.titles[1].id == "title-alt",
    msg="标题 id 保留供 refines 关联",
  )
}

///|
/// EPUB 3.3「XML conformance」：DOCTYPE 内部实体是合法输入，
/// 标题文本与 xml:lang 属性引用内部实体必须按语义展开，不得丢弃。
test "EPUB3 内部实体标题与命名空间属性：合法输入语义不丢失" {
  let b = open_fixture("internal-entities")
  assert_true(
    b.metadata.title == "内部实体书名：月亮与六便士",
    msg="标题由 &book.title; 展开：" + b.metadata.title,
  )
  assert_true(
    b.metadata.titles[0].lang == "zh",
    msg="xml:lang 由 &book.lang; 展开：" + b.metadata.titles[0].lang,
  )
  // dc:title 带命名空间前缀，按 local name 命中，且实体展开发生在命名空间元素内
  assert_true(
    @epub.main_title(b.metadata) == "内部实体书名：月亮与六便士",
    msg="主标题保持规范语义",
  )
}

///|
test "EPUB3 meta refines：角色/别名/file-as 不再丢失" {
  let b = open_fixture("rich-metadata")
  // 首位作者仍是主作者（文档顺序首个 dc:creator）。
  assert_true(
    @epub.primary_creator(b.metadata) == "MOONBIT",
    msg="主作者=首个 dc:creator",
  )
  // refines 的 role 覆盖：插画师不能被当成作者角色 aut。
  assert_true(
    b.metadata.creators[1].1 == "ill",
    msg="插画师角色：" + b.metadata.creators[1].1,
  )
  assert_true(
    @epub.refine(b.metadata, "creator-main", "role") == "aut",
    msg="主作者 role refines",
  )
  assert_true(
    @epub.refine(b.metadata, "creator-main", "alternate-script") ==
    "著者サンプル",
    msg="作者别名保留：",
  )
  let alt_scripts = @epub.refine_all(
    b.metadata,
    "creator-main",
    "alternate-script",
  )
  assert_true(alt_scripts.length() == 1, msg="别名 refinement 数量")
  assert_true(
    alt_scripts[0].lang == "ja",
    msg="别名 xml:lang 保留：" + alt_scripts[0].lang,
  )
  assert_true(
    @epub.refine(b.metadata, "creator-main", "file-as") == "MOONBIT,",
    msg="file-as 保留（值按元数据惯例 trim）",
  )
}

///|
test "EPUB3 nav：span 分组标题与 hidden 空布尔值语义不丢失" {
  let b = open_fixture("rich-metadata")
  assert_true(b.nav_toc.length() == 1, msg="顶层一个分组节点")
  let group = b.nav_toc[0]
  assert_true(group.is_group, msg="span 节点标记为分组")
  assert_true(
    group.label == "分组：样例章",
    msg="分组标题文字保留：" + group.label,
  )
  assert_true(group.path == "", msg="分组无跳转目标")
  // 分组内：2 章 + 1 个 hidden 分支。
  assert_true(group.children.length() == 3, msg="组内三项")
  assert_true(!group.children[0].hidden, msg="普通章不隐藏")
  assert_true(group.children[2].hidden, msg="hidden=\"\" 被识别为隐藏")
  assert_true(
    group.children[2].label == "隐藏分支",
    msg="隐藏分支文字仍保留（不丢弃语义）",
  )
}

///|
test "EPUB3 富语义书不产生告警（合法输入）" {
  let b = open_fixture("rich-metadata")
  assert_true(
    b.warnings.length() == 0,
    msg="合法书不应降级：" + @epub.report(b),
  )
}

///|
/// 审查 P0-1：foreign content document 的 fallback 链必须进入阅读顺序，
/// 且替换要可见（告警），不能静默丢章。
test "fallback 链：外国内容文档按 fallback 加入章节并告警" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"3.0\" unique-identifier=\"uid\">",
    "  <metadata><dc:title xmlns:dc=\"http://purl.org/dc/elements/1.1/\">T</dc:title></metadata>",
    "  <manifest>", "    <item id=\"ch1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/>",
    "    <item id=\"foreign\" href=\"foreign.jpg\" media-type=\"image/jpeg\" fallback=\"ch1\"/>",
    "  </manifest>", "  <spine><itemref idref=\"ch1\"/><itemref idref=\"foreign\"/></spine>",
    "</package>",
  ])
  let a = @container.archive("fallback.epub", [
    ("mimetype", "application/epub+zip"),
    (
      "META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>",
    ),
    ("OEBPS/content.opf", opf),
  ])
  match @epub.open(a) {
    Err(_) => panic()
    Ok(book) => {
      assert_true(
        @epub.chapter_paths(book).length() == 2,
        msg="fallback 章节不能消失",
      )
      assert_true(
        @epub.chapter_paths(book)[1] == "OEBPS/ch1.xhtml",
        msg="foreign 指向 fallback 的 XHTML",
      )
      assert_true(
        warning_count(book, "fallback") == 1,
        msg="fallback 替换必须告警",
      )
    }
  }
}

///|
/// 审查 P0-2：`image/svg+xml` 是 EPUB 3.3 核心内容文档，可直接进 spine。
test "SVG 内容文档直接进入阅读顺序" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"3.0\" unique-identifier=\"uid\">",
    "  <metadata><dc:title xmlns:dc=\"http://purl.org/dc/elements/1.1/\">T</dc:title></metadata>",
    "  <manifest>", "    <item id=\"svg\" href=\"page.svg\" media-type=\"image/svg+xml\"/>",
    "  </manifest>", "  <spine><itemref idref=\"svg\"/></spine>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) => {
      assert_true(info.spine.length() == 1, msg="spine 一项")
      assert_true(
        @resource.is_markup_media(info.spine[0].media_type),
        msg="SVG 属于内容文档",
      )
    }
  }
}

///|
/// 审查 P1-3：§C.2 把 epub:type 定义为空白分隔列表。
test "epub:type=\"toc landmarks\" 命中目录而不是地标" {
  let nav = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<html xmlns:epub=\"http://www.idpf.org/2007/ops\">",
    "<body>", "<nav epub:type=\"landmarks\"><ol><li><a href=\"a.xhtml\">地标项</a></li></ol></nav>",
    "<nav epub:type=\"toc landmarks\"><ol><li><a href=\"b.xhtml\">目录项</a></li></ol></nav>",
    "</body></html>",
  ])
  match @epub.parse_nav("OEBPS/nav.xhtml", nav) {
    Err(_) => panic()
    Ok((points, _)) => {
      assert_true(points.length() == 1, msg="一项目录")
      assert_true(
        points[0].label == "目录项",
        msg="多值 token 命中：" + points[0].label,
      )
    }
  }
}

///|
/// 审查 P1-4：EPUB2 遗留封面读 `meta@content`，不是元素文本。
test "EPUB2 封面：meta name=cover content=ITEM-ID 不被第一张图冒充" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"2.0\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", "    <dc:title>T</dc:title>",
    "    <meta name=\"cover\" content=\"cover-img\"/>", "  </metadata>", "  <manifest>",
    "    <item id=\"other-img\" href=\"other.png\" media-type=\"image/png\"/>", "    <item id=\"cover-img\" href=\"cover.png\" media-type=\"image/png\"/>",
    "  </manifest>", "  <spine><itemref idref=\"ch1\"/></spine>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) =>
      assert_true(
        info.metadata.cover_path == "OEBPS/cover.png",
        msg="封面路径：" + info.metadata.cover_path,
      )
  }
}

///|
/// 审查 P1-5：`package/@xml:lang` 才是默认语言，不是 metadata 元素的 lang。
test "package@xml:lang 作为 dc:title 的默认语言" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"3.0\" xml:lang=\"zh-Hant\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", "    <dc:title>繁体标题</dc:title>",
    "  </metadata>", "  <manifest/>", "  <spine/>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) =>
      assert_true(
        info.metadata.titles[0].lang == "zh-Hant",
        msg="默认语言：" + info.metadata.titles[0].lang,
      )
  }
}

///|
/// 审查 P1-7：多份 NCX 时必须按 `spine/@toc` 选，不能取第一份。
test "EPUB2 spine@toc 指定正确的 NCX" {
  let items = [
    ("mimetype", "application/epub+zip"),
    (
      "META-INF/container.xml", "<?xml version=\"1.0\"?><container version=\"1.0\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>",
    ),
    (
      "OEBPS/content.opf",
      @util.join_nl([
        "<?xml version=\"1.0\"?>", "<package version=\"2.0\" unique-identifier=\"uid\">",
        "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>T</dc:title></metadata>",
        "  <manifest>", "    <item id=\"ncxA\" href=\"a.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
        "    <item id=\"ncxB\" href=\"b.ncx\" media-type=\"application/x-dtbncx+xml\"/>",
        "  </manifest>", "  <spine toc=\"ncxB\"><itemref idref=\"ncxA\" linear=\"no\"/></spine>",
        "</package>",
      ]),
    ),
    (
      "OEBPS/a.ncx", "<?xml version=\"1.0\"?><ncx><navMap><navPoint><navLabel><text>甲目录</text></navLabel><content src=\"a.xhtml\"/></navPoint></navMap></ncx>",
    ),
    (
      "OEBPS/b.ncx", "<?xml version=\"1.0\"?><ncx><navMap><navPoint><navLabel><text>乙目录</text></navLabel><content src=\"b.xhtml\"/></navPoint></navMap></ncx>",
    ),
  ]
  match @epub.open(@container.archive("two-ncx.epub", items)) {
    Err(_) => panic()
    Ok(b) =>
      assert_true(
        b.ncx_toc.length() == 1 && b.ncx_toc[0].label == "乙目录",
        msg="按 spine@toc 选 NCX",
      )
  }
}

///|
fn opf_with_guide() -> String {
  @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<package version=\"2.0\" unique-identifier=\"uid\">",
    "  <metadata><dc:title xmlns:dc=\"http://purl.org/dc/elements/1.1/\">T</dc:title></metadata>",
    "  <manifest/>", "  <spine/>", "  <guide>", "    <reference type=\"toc\" title=\"目录\" href=\"nav.xhtml\"/>",
    "    <reference type=\"cover\" title=\"封面\" href=\"cover.xhtml\"/>", "  </guide>",
    "</package>",
  ])
}

///|
/// 审查 P2：Repeatable Dublin Core 元素必须全保留，role scheme 不能误判。
test "可重复 Dublin Core 元素全保留，非法 role scheme 不覆盖作者" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"3.0\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", "    <dc:title>T</dc:title>",
    "    <dc:creator id=\"c1\">A</dc:creator>", "    <meta refines=\"#c1\" property=\"role\" scheme=\"http://example.org/other\">xyz</meta>",
    "    <meta refines=\"#c1\" property=\"role\" scheme=\"marc:relators\">ill</meta>",
    "    <dc:publisher>P1</dc:publisher><dc:publisher>P2</dc:publisher>", "    <dc:description>D1</dc:description><dc:description>D2</dc:description>",
    "    <dc:date>2026-01-01</dc:date><dc:date>2026-02-02</dc:date>", "    <dc:source>S1</dc:source><dc:source>S2</dc:source>",
    "    <dc:type>Text</dc:type><dc:coverage>World</dc:coverage>", "    <dc:relation>R</dc:relation><dc:format>application/xhtml+xml</dc:format>",
    "  </metadata>", "  <manifest/>", "  <spine/>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) => {
      assert_true(
        info.metadata.publishers.length() == 2,
        msg="两个 publisher",
      )
      assert_true(
        info.metadata.descriptions.length() == 2,
        msg="两个 description",
      )
      assert_true(info.metadata.dates.length() == 2, msg="两个 date")
      assert_true(info.metadata.sources.length() == 2, msg="两个 source")
      assert_true(info.metadata.types.length() == 1, msg="dc:type 有槽位")
      assert_true(
        info.metadata.coverages.length() == 1,
        msg="dc:coverage 有槽位",
      )
      assert_true(
        info.metadata.relations.length() == 1,
        msg="dc:relation 有槽位",
      )
      assert_true(
        info.metadata.formats.length() == 1,
        msg="dc:format 有槽位",
      )
      assert_true(
        info.metadata.creators[0].1 == "ill",
        msg="只采纳 MARC scheme 的 role：" + info.metadata.creators[0].1,
      )
    }
  }
}

///|
/// 审查 P2：EPUB2 `opf:file-as` 应写入 refinements，供宿主查询。
test "EPUB2 opf:file-as 保留在 refinements 中" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"2.0\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:opf=\"http://www.idpf.org/2007/opf\">",
    "    <dc:title>T</dc:title>", "    <dc:creator id=\"c1\" opf:file-as=\"DOE, John\">John Doe</dc:creator>",
    "  </metadata>", "  <manifest/>", "  <spine/>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) =>
      assert_true(
        @epub.refine(info.metadata, "c1", "file-as") == "DOE, John",
        msg="file-as 可查询",
      )
  }
}

///|
/// 创作者偏好虽可忽略，也应在元数据中可查询。
test "rendition:layout 与 rendition:flow 不再被丢弃" {
  let opf = @util.join_nl([
    "<?xml version=\"1.0\"?>", "<package version=\"3.0\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", "    <dc:title>T</dc:title>",
    "    <meta property=\"rendition:layout\">pre-paginated</meta>", "    <meta property=\"rendition:flow\">scrolled-continuous</meta>",
    "  </metadata>", "  <manifest/>", "  <spine/>", "</package>",
  ])
  match @epub.parse_opf("OEBPS/content.opf", opf, false) {
    Err(_) => panic()
    Ok(info) => {
      assert_true(
        info.metadata.rendition_layout == "pre-paginated",
        msg="layout",
      )
      assert_true(
        info.metadata.rendition_flow == "scrolled-continuous",
        msg="flow",
      )
    }
  }
}
