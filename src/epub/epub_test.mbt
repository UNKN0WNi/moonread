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
      let g = @epub.parse_guide(root, warnings)
      assert_true(g.length() == 2, msg="两条 guide reference")
      assert_true(g[0].typ == "toc", msg="type")
      assert_true(
        g[0].path == "nav.xhtml",
        msg="href 原样保留，由上层解析",
      )
    }
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
