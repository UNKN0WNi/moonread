///|
/// XML 子集解析测试。覆盖 EPUB 三类输入：container.xml / OPF / nav.xhtml。
///
/// 刻意不用多行字符串字面量：跨工具链版本的转义与空白规则不稳定，
/// 用 `@util.join_nl` 拼行可以让断言完全可预测。
fn doc_ok(text : String) -> Bool {
  match @xml.parse_document(text) {
    Ok(_) => true
    Err(_) => false
  }
}

///|
fn doc_err_text(text : String) -> String {
  match @xml.parse_document(text) {
    Ok(_) => ""
    Err(e) => e
  }
}

///|
fn lenient_err_text(text : String) -> String {
  match @xml.parse_document_lenient(text) {
    Ok(_) => ""
    Err(e) => e
  }
}

///|
fn first_child_tag(text : String) -> String {
  match @xml.parse_document(text) {
    Ok(el) => el.tag
    Err(_) => "<失败>"
  }
}

///|
fn attr_of(text : String, name : String) -> String {
  match @xml.parse_document(text) {
    Ok(el) =>
      match @xml.get_attr(el, name) {
        Some(v) => v
        None => "<无>"
      }
    Err(_) => "<失败>"
  }
}

///|
fn opt_str_eq(r : String?, want : String) -> Bool {
  match r {
    Some(v) => v == want
    None => false
  }
}

///|
fn opt_none_str(r : String?) -> Bool {
  match r {
    Some(_) => false
    None => true
  }
}

///|
/// 取 `parent_tag` 下 `child_tag` 的数量，避免在测试体里使用 `?`。
fn count_children_of(
  root : @xml.Element,
  parent_tag : String,
  child_tag : String,
) -> Int32 {
  match @xml.find_child(root, parent_tag) {
    None => -1
    Some(p) => @xml.find_all_child(p, child_tag).length()
  }
}

///|
fn container_xml() -> String {
  @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">",
    "  <rootfiles>", "    <rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/>",
    "  </rootfiles>", "</container>",
  ])
}

///|
fn opf_xml() -> String {
  @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>",
    "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"uid\">",
    "  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
    "    <dc:identifier id=\"uid\">urn:uuid:1234</dc:identifier>",
    "    <dc:title>Spike Book</dc:title>",
    "    <dc:creator>MOONBIT</dc:creator>",
    "    <meta property=\"dcterms:modified\">2026-11-19T00:00:00Z</meta>",
    "  </metadata>",
    "  <manifest>",
    "    <item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
    "    <item id=\"ch1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/>",
    "    <item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>",
    "  </manifest>",
    "  <spine>",
    "    <itemref idref=\"nav\" linear=\"no\"/>",
    "    " + "<itemref idref=\"ch1\"/>",
    "  </spine>",
    "</package>",
  ])
}

///|
test "container.xml 解析" {
  match @xml.parse_document(container_xml()) {
    Err(_) => panic()
    Ok(root) => {
      assert_true(root.tag == "container", msg="根元素名")
      assert_true(
        opt_str_eq(@xml.get_attr(root, "version"), "1.0"),
        msg="version 属性",
      )
      match @xml.find_descendant(root, "rootfile") {
        None => panic()
        Some(rf) => {
          assert_true(
            opt_str_eq(@xml.get_attr(rf, "full-path"), "OEBPS/content.opf"),
            msg="full-path",
          )
          assert_true(
            opt_str_eq(
              @xml.get_attr(rf, "media-type"),
              "application/oebps-package+xml",
            ),
            msg="media-type",
          )
        }
      }
    }
  }
}

///|
test "OPF 解析与结构统计" {
  match @xml.parse_document(opf_xml()) {
    Err(_) => panic()
    Ok(root) => {
      assert_true(@xml.tag_is(root, "package"), msg="package 根元素")
      assert_true(
        opt_str_eq(@xml.get_attr(root, "unique-identifier"), "uid"),
        msg="unique-identifier",
      )
      match @xml.find_descendant(root, "title") {
        None => panic()
        Some(t) =>
          assert_true(@xml.text_content(t) == "Spike Book", msg="标题文本")
      }
      assert_true(
        count_children_of(root, "manifest", "item") == 3,
        msg="manifest 三项",
      )
      assert_true(
        count_children_of(root, "spine", "itemref") == 2,
        msg="spine 两项",
      )
      assert_true(
        count_children_of(root, "missing", "item") == -1,
        msg="缺失父元素返回 -1",
      )
    }
  }
}

///|
test "命名空间前缀处理" {
  assert_true(@xml.local_name("dc:title") == "title", msg="local_name")
  assert_true(@xml.local_name("title") == "title", msg="无前缀")
  assert_true(@xml.local_name("xmlns:epub") == "epub", msg="xmlns 前缀")
  match @xml.parse_document("<a><dc:title>T</dc:title></a>") {
    Err(_) => panic()
    Ok(root) =>
      match @xml.find_child(root, "title") {
        None => panic()
        Some(t) =>
          assert_true(@xml.text_content(t) == "T", msg="按 local name 命中")
      }
  }
}

///|
test "实体解码" {
  match @xml.parse_document("<p>&lt;tag&gt; &amp; A &#65; &#x4e2d;</p>") {
    Err(_) => panic()
    Ok(root) =>
      assert_true(
        @xml.text_content(root) == "<tag> & A A 中",
        msg="文本实体：" + @xml.text_content(root),
      )
  }
  assert_true(
    !doc_ok("<p>&unknown;</p>"),
    msg="严格模式应拒绝未声明实体",
  )
  assert_true(
    match @xml.parse_document_lenient("<p>&unknown;</p>") {
      Ok(el) => @xml.text_content(el) == "&unknown;"
      Err(_) => false
    },
    msg="lenient 模式按字面保留",
  )
  assert_true(
    match @xml.parse_document_lenient("<p>&nbsp;x</p>") {
      Ok(el) => @xml.text_content(el) == "\u{a0}x"
      Err(_) => false
    },
    msg="lenient 支持 nbsp",
  )
  assert_true(
    doc_err_text("<p>&#xZZ;</p>").length() > 0,
    msg="非法数字实体应报错",
  )
  assert_true(
    doc_err_text("<p>&#x;").length() > 0,
    msg="空数字实体应报错",
  )
  assert_true(
    doc_err_text("<p>&#xD800;</p>").length() > 0,
    msg="代理区码位应报错",
  )
  assert_true(doc_err_text("<p>&amp").length() > 0, msg="实体缺少分号")
}

///|
test "注释 / CDATA / 处理指令 / 前言" {
  match
    @xml.parse_document("<a><!-- 说明 --><b>1</b><![CDATA[ x < y ]]></a>") {
    Err(_) => panic()
    Ok(root) => {
      assert_true(
        @xml.child_elements(root).length() == 1,
        msg="注释不入树",
      )
      assert_true(
        @xml.text_content(root) == "1 x < y ",
        msg="CDATA 原样保留：" + @xml.text_content(root),
      )
    }
  }
  assert_true(
    doc_ok("<?xml version=\"1.0\"?><a/>"),
    msg="前言 + 自闭合根",
  )
  assert_true(doc_ok("<!DOCTYPE html><a><br/></a>"), msg="DOCTYPE 前言")
  assert_true(
    doc_ok("<!DOCTYPE html [ <!ENTITY x \"y\"> ]><a/>"),
    msg="DOCTYPE 内部子集",
  )
  assert_true(
    doc_ok("<?xml version=\"1.0\"?><!-- c --><a/>"),
    msg="PI + 注释混合前言",
  )
  assert_true(
    doc_err_text("<a><!-- 未闭合").length() > 0,
    msg="未闭合注释应报错",
  )
  assert_true(
    doc_err_text("<a><![CDATA[ 未闭合</a>").length() > 0,
    msg="未闭合 CDATA 应报错",
  )
}

///|
test "lenient 模式容忍 HTML 空元素与大小写" {
  assert_true(
    match
      @xml.parse_document_lenient("<body><p>a<br>b<img src=\"x\"></p></body>") {
      Ok(_) => true
      Err(_) => false
    },
    msg="无斜杠空元素",
  )
  assert_true(
    match @xml.parse_document_lenient("<A><b>x</B></A>") {
      Ok(_) => true
      Err(_) => false
    },
    msg="结束标签大小写不一致",
  )
  assert_true(
    lenient_err_text("<A><b>x</c></A>").length() > 0,
    msg="真正不匹配的结束标签仍应报错",
  )
  assert_true(
    match @xml.parse_document_lenient("<body><p>a<br>b</p></body>") {
      Ok(root) => @xml.descendants(root).length() == 2
      Err(_) => false
    },
    msg="空元素应成为子节点",
  )
  assert_true(
    match @xml.parse_document_lenient("<input disabled>") {
      Ok(root) => opt_str_eq(@xml.get_attr(root, "disabled"), "disabled")
      Err(_) => false
    },
    msg="无值属性按同名空值处理",
  )
}

///|
test "严格模式拒绝脏输入并给出偏移" {
  assert_true(!doc_ok("<a><b></a>"), msg="标签不匹配")
  assert_true(!doc_ok("<a><b>"), msg="未闭合")
  assert_true(!doc_ok("<a>x</a><b/>"), msg="多个根元素")
  assert_true(!doc_ok(""), msg="空文档")
  assert_true(!doc_ok("   "), msg="只有空白")
  assert_true(!doc_ok("<a attr=no-quote/>"), msg="属性值未加引号")
  assert_true(!doc_ok("<a><b></c></b></a>"), msg="结束标签不匹配")
  assert_true(!doc_ok("<a b=\"1\""), msg="根标签未闭合")
  assert_true(!doc_ok("<>"), msg="空标签名")
  assert_true(
    @util.contains(doc_err_text("<a><b></c></b></a>"), "不匹配"),
    msg="错误信息应说明不匹配",
  )
  assert_true(
    doc_err_text("<a><b></c></b></a>").length() > 0,
    msg="错误信息非空",
  )
}

///|
test "合法深层嵌套通过，超 512 层才拒绝" {
  let mut ok = ""
  let mut j = 0
  while j < 120 {
    ok = ok + "<a>"
    j = j + 1
  }
  let mut m = 0
  while m < 120 {
    ok = ok + "</a>"
    m = m + 1
  }
  assert_true(doc_ok(ok), msg="120 层是合法 XML，必须接受")
  let mut deep = ""
  let mut i = 0
  while i < 600 {
    deep = deep + "<a>"
    i = i + 1
  }
  let mut k = 0
  while k < 600 {
    deep = deep + "</a>"
    k = k + 1
  }
  assert_true(!doc_ok(deep), msg="600 层构造输入应被拒绝")
}

///|
test "访问器行为" {
  match
    @xml.parse_document(
      "<r><c id=\"1\">t1</c><c id=\"2\"><g id=\"3\">t2</g></c></r>",
    ) {
    Err(_) => panic()
    Ok(root) => {
      assert_true(
        @xml.find_all_child(root, "c").length() == 2,
        msg="find_all_child",
      )
      assert_true(
        @xml.descendants(root).length() == 3,
        msg="descendants 数量",
      )
      assert_true(
        @xml.count_elements(root) == 4,
        msg="count_elements 含自身",
      )
      match @xml.find_by_id(root, "3") {
        None => panic()
        Some(g) => {
          assert_true(g.tag == "g", msg="find_by_id 命中标签")
          assert_true(
            @xml.text_content(g) == "t2",
            msg="find_by_id 命中内容",
          )
        }
      }
      match @xml.find_by_id(root, "9") {
        None => ()
        Some(_) => panic()
      }
      assert_true(opt_none_str(@xml.attr_ci(root, "ID")), msg="根元素无 id")
      assert_true(
        @xml.child_text(root) == "",
        msg="根元素直接文本为空",
      )
    }
  }
  match @xml.parse_document("<r ID=\"x\" href=\"y\"/>") {
    Err(_) => panic()
    Ok(root) => {
      assert_true(
        opt_str_eq(@xml.attr_ci(root, "id"), "x"),
        msg="attr_ci 大小写无关",
      )
      assert_true(
        opt_str_eq(@xml.get_attr(root, "ID"), "x"),
        msg="get_attr 精确匹配",
      )
      assert_true(
        opt_none_str(@xml.get_attr(root, "id")),
        msg="get_attr 大小写敏感",
      )
    }
  }
}

///|
test "片段解析入口" {
  match @xml.parse_fragment("<p>hi</p><p>there</p>", @xml.lenient_options()) {
    Err(_) => panic()
    Ok(root) => {
      assert_true(
        root.tag == "moonread-fragment",
        msg="片段包裹在合成根下",
      )
      assert_true(@xml.child_elements(root).length() == 2, msg="两个 p")
    }
  }
}

///|
test "辅助函数与属性内实体" {
  assert_true(
    first_child_tag("<opf:package a=\"1\"/>") == "opf:package",
    msg="前缀保留在 tag",
  )
  assert_true(attr_of("<a href=\"x\"/>", "href") == "x", msg="attr_of")
  assert_true(attr_of("<a/>", "href") == "<无>", msg="缺失属性")
  assert_true(doc_ok("<a b=\"&quot;\"/>"), msg="属性内实体")
  assert_true(
    doc_err_text("<a b=\"x<y\"/>").length() > 0,
    msg="属性值内裸尖括号应报错",
  )
  assert_true(
    doc_err_text("<a b=\"unclosed/>").length() > 0,
    msg="属性引号未闭合应报错",
  )
}

///|
/// EPUB 3.3「XML conformance」：内部 DTD 实体是合法输入，必须按语义展开。
test "DOCTYPE 内部实体：标题与属性按语义展开" {
  let xml = @util.join_nl([
    "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<!DOCTYPE package [", "  <!ENTITY booktitle \"月亮与六便士\">",
    "  <!ENTITY author \"毛姆\">", "  <!ENTITY lang \"zh\">", "]>", "<package xmlns:dc=\"http://purl.org/dc/elements/1.1/\">",
    "  <dc:title xml:lang=\"&lang;\">&booktitle;</dc:title>", "  <dc:creator>&author;</dc:creator>",
    "</package>",
  ])
  match @xml.parse_document(xml) {
    Err(_) => panic()
    Ok(root) => {
      match @xml.find_child(root, "title") {
        None => panic()
        Some(t) => {
          assert_true(
            @xml.text_content(t) == "月亮与六便士",
            msg="内部实体标题展开：" + @xml.text_content(t),
          )
          assert_true(
            @xml.attr_or_empty(t, "lang") == "zh",
            msg="属性值中的内部实体展开：" +
              @xml.attr_or_empty(t, "lang"),
          )
        }
      }
      match @xml.find_child(root, "creator") {
        None => panic()
        Some(c) =>
          assert_true(
            @xml.text_content(c) == "毛姆",
            msg="内部实体作者展开",
          )
      }
    }
  }
}

///|
/// 内部实体值可再含实体引用，按 XML 规则递归展开。
test "DOCTYPE 内部实体：嵌套引用递归展开" {
  let xml = @util.join_nl([
    "<!DOCTYPE a [", "  <!ENTITY who \"世界\">", "  <!ENTITY greeting \"你好，&who;！\">",
    "]>", "<a><p>&greeting;</p></a>",
  ])
  match @xml.parse_document(xml) {
    Err(_) => panic()
    Ok(root) =>
      assert_true(
        @xml.text_content(root) == "你好，世界！",
        msg="嵌套展开：" + @xml.text_content(root),
      )
  }
}

///|
/// 规范 MUST NOT：internal DTD subset 不得含 external entity declaration。
test "DOCTYPE 外部实体：按 EPUB 规范拒绝" {
  let sys = @util.join_nl([
    "<!DOCTYPE a [", "  <!ENTITY xxe SYSTEM \"file:///etc/passwd\">", "]>", "<a>&xxe;</a>",
  ])
  let pub_ext = @util.join_nl([
    "<!DOCTYPE a [", "  <!ENTITY xxe PUBLIC \"-//EVIL//DTD\" \"http://evil.example/x.dtd\">",
    "]>", "<a>&xxe;</a>",
  ])
  assert_true(
    doc_err_text(sys).contains("禁止外部实体声明"),
    msg="SYSTEM 外部实体应报错：" + doc_err_text(sys),
  )
  assert_true(
    doc_err_text(pub_ext).contains("禁止外部实体声明"),
    msg="PUBLIC 外部实体应报错：" + doc_err_text(pub_ext),
  )
  assert_true(
    lenient_err_text(sys).contains("禁止外部实体声明"),
    msg="lenient 模式也不放宽 XXE 禁令",
  )
}

///|
/// 参数实体与循环引用都要在解析阶段挡住，不 panic。
test "DOCTYPE 参数实体与循环引用被拒绝" {
  let param = @util.join_nl([
    "<!DOCTYPE a [", "  <!ENTITY % ext SYSTEM \"http://evil.example/x.dtd\">", "]>",
    "<a/>",
  ])
  let cyclic = @util.join_nl([
    "<!DOCTYPE a [", "  <!ENTITY loop \"&loop;\">", "]>", "<a>&loop;</a>",
  ])
  assert_true(
    doc_err_text(param).contains("禁止参数实体声明"),
    msg="参数实体应报错",
  )
  // 自引用实体在替换时按深度上限拒绝，不死循环、不 panic
  assert_true(
    doc_err_text(cyclic).length() > 0,
    msg="循环实体应被拒绝：" + doc_err_text(cyclic),
  )
}

///|
/// 外部标识符的 DOCTYPE（EPUB 规范允许）不应被误判为外部实体。
test "DOCTYPE 外部标识符仍可解析" {
  let xml = @util.join_nl([
    "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\"", "  \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">",
    "<html><body><p>ok</p></body></html>",
  ])
  assert_true(
    doc_ok(xml),
    msg="外部标识符 DOCTYPE 合法：" + doc_err_text(xml),
  )
}

///|
/// XML 1.0 §4.4.5：内部实体在正文中的替换文本要作为标记重新解析。
/// expat 对同一输入解析成功并产生 <b> 元素；旧实现误拒为非法输入。
test "正文中的内部实体替换文本作为标记重新解析" {
  let xml = @util.join_nl([
    "<!DOCTYPE doc [", "  <!ENTITY frag \"<b>粗体</b>文字\">", "]>", "<doc>前&frag;后</doc>",
  ])
  match @xml.parse_document(xml) {
    Err(_) => panic()
    Ok(root) => {
      let kids = @xml.child_elements(root)
      assert_true(kids.length() == 1, msg="b 元素应被解析出来")
      assert_true(kids[0].tag == "b", msg="标签：" + kids[0].tag)
      assert_true(
        @xml.text_content(kids[0]) == "粗体",
        msg="实体内标记文本：" + @xml.text_content(kids[0]),
      )
      assert_true(
        @xml.text_content(root) == "前粗体文字后",
        msg="全文：" + @xml.text_content(root),
      )
    }
  }
}

///|
/// 同一个实体用于属性值时仍必须拒绝（WFC: No < in Attribute Values）。
test "属性值内引用含标记的内部实体仍被拒绝" {
  let xml = @util.join_nl([
    "<!DOCTYPE doc [", "  <!ENTITY frag \"<b>x</b>\">", "]>", "<doc title=\"&frag;\"/>",
  ])
  assert_true(doc_err_text(xml).length() > 0, msg="属性值不得出现 '<'")
}

///|
/// XML WFC: No Duplicate Attributes 与 §2.2 Char production。
test "重复属性与 &#x0; 被拒绝" {
  assert_true(
    doc_err_text("<p id=\"a\" id=\"b\"/>").length() > 0,
    msg="重复属性",
  )
  assert_true(doc_err_text("<p v=\"&#x0;\"/>").length() > 0, msg="非法码位")
  assert_true(doc_ok("<p v=\"&#x9;\"/>"), msg="制表符引用合法")
}

///|
/// XML §3.3.3：属性值中的字面换行/制表归一化为空格。
test "属性值空白按 XML 规则归一化" {
  let xml = "<p a=\"x\ny\tz\"/>"
  match @xml.parse_document(xml) {
    Err(_) => panic()
    Ok(root) =>
      assert_true(
        @xml.attr_or_empty(root, "a") == "x y z",
        msg="归一化结果：" + @xml.attr_or_empty(root, "a"),
      )
  }
}

///|
/// `xml:id` 不应被当成普通 `id` 被 find_by_id 命中。
test "find_by_id 不混用 xml:id 与 id" {
  let xml = "<r><a xml:id=\"same\"/><b id=\"same\"/></r>"
  match @xml.parse_document(xml) {
    Err(_) => panic()
    Ok(root) =>
      match @xml.find_by_id(root, "same") {
        None => panic()
        Some(el) =>
          assert_true(el.tag == "b", msg="只命中无前缀的 id：" + el.tag)
      }
  }
}
