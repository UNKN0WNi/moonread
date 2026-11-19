///|
/// 资源解析测试（「相对路径、URL 编码、base64 内嵌、远程资源策略」）。
fn ref_is_archive(base : String, href : String, want : String) -> Bool {
  match @resource.resolve(base, href) {
    InArchive(p) => p == want
    _ => false
  }
}

///|
fn ref_is_invalid(base : String, href : String) -> Bool {
  match @resource.resolve(base, href) {
    Invalid(_) => true
    _ => false
  }
}

///|
fn invalid_reason(base : String, href : String) -> String {
  match @resource.resolve(base, href) {
    Invalid(r) => r
    _ => ""
  }
}

///|
fn ref_is_remote(base : String, href : String, want_scheme : String) -> Bool {
  match @resource.resolve(base, href) {
    Remote(sc, _, _) => sc == want_scheme
    _ => false
  }
}

///|
test "OPF 同级与子目录相对引用" {
  assert_true(
    ref_is_archive("OEBPS/content.opf", "ch1.xhtml", "OEBPS/ch1.xhtml"),
    msg="同级",
  )
  assert_true(
    ref_is_archive("OEBPS/content.opf", "../cover.jpg", "cover.jpg"),
    msg="上跳到根",
  )
  assert_true(
    ref_is_archive("OEBPS/content.opf", "images/a.png", "OEBPS/images/a.png"),
    msg="子目录",
  )
  assert_true(
    ref_is_archive("OEBPS/text/ch1.xhtml", "../style.css", "OEBPS/style.css"),
    msg="章节内相对引用",
  )
  assert_true(
    ref_is_archive("OEBPS/content.opf", "/OEBPS/nav.xhtml", "OEBPS/nav.xhtml"),
    msg="根绝对引用去掉前导斜杠",
  )
}

///|
test "锚点与纯锚点" {
  assert_true(
    ref_is_archive("OEBPS/nav.xhtml", "ch1.xhtml#sec2", "OEBPS/ch1.xhtml"),
    msg="带锚点",
  )
  assert_true(
    ref_is_archive("OEBPS/ch1.xhtml", "#fn1", "OEBPS/ch1.xhtml"),
    msg="纯锚点指向自身",
  )
  assert_true(
    @resource.fragment("ch1.xhtml#sec_2") == "sec_2",
    msg="fragment 提取",
  )
  assert_true(@resource.fragment("ch1.xhtml") == "", msg="无锚点")
  assert_true(
    @resource.fragment("a#b#c") == "b#c",
    msg="多个井号取第一个之后的全部",
  )
}

///|
test "URL 编码" {
  assert_true(
    ref_is_archive(
      "OEBPS/content.opf", "my%20chapter.xhtml", "OEBPS/my chapter.xhtml",
    ),
    msg="空格编码",
  )
  assert_true(
    ref_is_archive(
      "OEBPS/content.opf", "%E4%B8%AD/ch.xhtml", "OEBPS/中/ch.xhtml",
    ),
    msg="中文编码",
  )
  assert_true(
    ref_is_invalid("OEBPS/a.opf", "bad%zz.xhtml"),
    msg="非法转义应 Invalid",
  )
  assert_true(
    @util.contains(
      invalid_reason("OEBPS/a.opf", "bad%zz.xhtml"),
      "百分号解码失败",
    ),
    msg="原因应说明解码失败",
  )
}

///|
test "不安全路径被拒绝" {
  assert_true(ref_is_invalid("OEBPS/a.opf", ""), msg="空引用")
  assert_true(ref_is_invalid("OEBPS/a.opf", "   "), msg="只有空白")
  assert_true(ref_is_invalid("OEBPS/a.opf", "win\\path.xhtml"), msg="反斜杠")
  assert_true(
    ref_is_archive("OEBPS/a.opf", "../../escape.xhtml", "escape.xhtml"),
    msg="越出根目录时截断在根，不报错（降级路径）",
  )
}

///|
test "远程资源与 urn" {
  assert_true(
    ref_is_remote("OEBPS/a.opf", "https://example.com/x.png", "https"),
    msg="https",
  )
  assert_true(
    ref_is_remote("OEBPS/a.opf", "http://example.com", "http"),
    msg="http",
  )
  assert_true(ref_is_remote("OEBPS/a.opf", "urn:uuid:1", "urn"), msg="urn")
  match @resource.resolve("OEBPS/a.opf", "https://example.com/x.png") {
    Remote(_, _, allowed) =>
      assert_true(!allowed, msg="默认策略不允许远程")
    _ => panic()
  }
  match
    @resource.resolve_with(
      "OEBPS/a.opf",
      "https://example.com/x.png",
      @resource.allow_all_policy(),
    ) {
    Remote(_, _, allowed) =>
      assert_true(allowed, msg="显式放开后应允许")
    _ => panic()
  }
  assert_true(
    match @resource.resolve_path("OEBPS/a.opf", "https://e.com/x") {
      Err(_) => true
      Ok(_) => false
    },
    msg="resolve_path 拒绝远程",
  )
}

///|
test "data: 内嵌" {
  match @resource.resolve("OEBPS/a.opf", "data:image/png;base64,iVBORw0KGgo=") {
    Inline(mt, data, b64) => {
      assert_true(mt == "image/png", msg="媒体类型")
      assert_true(b64, msg="base64 标记")
      assert_true(data == "iVBORw0KGgo=", msg="载荷原样保留")
    }
    _ => panic()
  }
  match @resource.resolve("OEBPS/a.opf", "data:text/css,p%7Bmargin%3A0%7D") {
    Inline(mt, data, b64) => {
      assert_true(mt == "text/css", msg="css 媒体类型")
      assert_true(!b64, msg="非 base64")
      assert_true(data == "p{margin:0}", msg="百分号解码：" + data)
    }
    _ => panic()
  }
  assert_true(
    ref_is_invalid("OEBPS/a.opf", "data:text/plain"),
    msg="缺少逗号",
  )
}

///|
test "媒体类型推断" {
  assert_true(
    @resource.media_type_of("a/b/c.XHTML") == "application/xhtml+xml",
    msg="大小写无关",
  )
  assert_true(@resource.media_type_of("cover.JPG") == "image/jpeg", msg="jpg")
  assert_true(@resource.media_type_of("cover.jpeg") == "image/jpeg", msg="jpeg")
  assert_true(@resource.media_type_of("style.css") == "text/css", msg="css")
  assert_true(
    @resource.media_type_of("content.opf") == "application/oebps-package+xml",
    msg="opf",
  )
  assert_true(
    @resource.media_type_of("toc.ncx") == "application/x-dtbncx+xml",
    msg="ncx",
  )
  assert_true(
    @resource.media_type_of("font.woff2") == "font/woff2",
    msg="woff2",
  )
  assert_true(
    @resource.media_type_of("nope") == "application/octet-stream",
    msg="未知",
  )
  assert_true(
    @resource.is_markup_media("text/HTML"),
    msg="markup 大小写无关",
  )
  assert_true(@resource.is_image_media("image/svg+xml"), msg="svg 是图片")
  assert_true(@resource.is_font_media("font/otf"), msg="otf 是字体")
  assert_true(@resource.is_page_image("p01.png"), msg="页图判定")
  assert_true(!@resource.is_page_image("p01.txt"), msg="文本非页图")
}

///|
test "properties 多值" {
  assert_true(@resource.has_property("nav mathml", "nav"), msg="空格分隔")
  assert_true(
    @resource.has_property("scripted\tsvg", "svg"),
    msg="制表分隔",
  )
  assert_true(!@resource.has_property("nav", "svg"), msg="否定")
  assert_true(!@resource.has_property("", "nav"), msg="空串")
}
