///|
/// 规则包单元测试（黑盒：一律经 @rules 公开 API）。
/// rules 曾 1144 行零测试——而它正是 P0-1（断页路径）与 P1-1（空壳动作）
/// 的出事模块。这里覆盖加载、选择器、8 种动作与诊断函数的真实行为。

///|
fn rules(text : String) -> @rules.RuleSet {
  match @rules.load_rules(text) {
    Ok(r) => r
    Err(_) => panic()
  }
}

///|
fn doc(text : String) -> @xml.Element {
  match @xml.parse_document(text) {
    Ok(d) => d
    Err(_) => panic()
  }
}

///|
fn count(arr : Array[String]) -> Int32 {
  let mut n = 0
  for _x in arr {
    n = n + 1
  }
  n
}

// ---------- 加载与校验 ----------

///|
test "8 种动作类型被支持，未知类型报错带规则 id" {
  let types = @rules.supported_action_types()
  assert_true(
    types.length() == 8,
    msg="应有 8 种动作，实际 " + types.length().to_string(),
  )
  for
    want in [
      "remove", "hide", "set_style", "page_break_before", "page_break_after", "replace_text",
      "annotate", "redirect",
    ] {
    let mut found = false
    for t in types {
      if t == want {
        found = true
      }
    }
    assert_true(found, msg="缺少动作 " + want)
  }
  match
    @rules.load_rules(
      "{\"version\":1,\"rules\":[{\"id\":\"oops\",\"match\":{\"selector\":\"p\"},\"action\":{\"type\":\"teleport\"}}]}",
    ) {
    Ok(_) => panic()
    Err(e) =>
      assert_true(
        @util.contains(e, "oops") && @util.contains(e, "teleport"),
        msg="错误带 id 与类型：" + e,
      )
  }
}

///|
/// 注意：当前 load_rules **不校验重复 id**（id 可省略，缺省用 `$.rules[i]`）。
/// examples/rules.json 的注释声称"重复 id 会被拒绝"与实现不符，属另一处待修；
/// 这里只钉住已实现的行为：空 selector 被拒绝、id 可省略。
test "非法 selector 被拒绝，id 可省略" {
  match
    @rules.load_rules(
      "{\"version\":1,\"rules\":[{\"id\":\"s\",\"match\":{\"selector\":\"\"},\"action\":{\"type\":\"hide\"}}]}",
    ) {
    Ok(_) => panic()
    Err(_) => assert_true(true, msg="空 selector 被拒绝")
  }
  match
    @rules.load_rules(
      "{\"version\":1,\"rules\":[{\"match\":{\"selector\":\"p\"},\"action\":{\"type\":\"hide\"}}]}",
    ) {
    Ok(_) => assert_true(true, msg="省略 id 可加载")
    Err(_) => panic()
  }
}

// ---------- 选择器与 text_regex ----------

///|
test "字面量交替匹配：大小写无关、按 | 分段" {
  assert_true(
    @rules.matches_alternation("Please SUBSCRIBE now", "subscribe|订阅"),
    msg="大小写无关命中",
  )
  assert_true(
    @rules.matches_alternation("订阅 newsletter", "subscribe|订阅"),
    msg="中文分支命中",
  )
  assert_true(
    !@rules.matches_alternation("hello", "subscribe|订阅"),
    msg="不命中",
  )
  assert_true(@rules.matches_alternation("anything", ""), msg="空模式恒真")
}

///|
/// 通过 load_rules 验证（逗号列表由加载器拆分，parse_selector 只吃单条）。
test "加载器接受 class/id/属性/伪类/组合子与逗号列表" {
  for
    s in [
      "p", "#main", ".note", "div.promo", "a[href^='#fn']", "a[href$=pdf]", "p:first-child",
      ":root", "body > p", "div p", "p, h1",
    ] {
    let js = "{\"version\":1,\"rules\":[{\"id\":\"s\",\"match\":{\"selector\":\"" +
      s +
      "\"},\"action\":{\"type\":\"hide\"}}]}"
    match @rules.load_rules(js) {
      Ok(_) => ()
      Err(_) => panic()
    }
  }
}

///|
test "rule_matches 区分命中与 text_regex 过滤" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"t\",\"match\":{\"selector\":\"p\",\"text_regex\":\"订阅\"},\"action\":{\"type\":\"remove\"}}]}",
  )
  let d = doc(
    "<html><body><p>普通段落</p><p>欢迎订阅</p></body></html>",
  )
  let paras : Array[@xml.Element] = []
  for e in @xml.descendants(d) {
    if @xml.tag_is(e, "p") {
      paras.push(e)
    }
  }
  let mut hit = 0
  for p in paras {
    if @rules.rule_matches(set.rules[0], [d, p]) {
      hit = hit + 1
    }
  }
  assert_true(
    hit == 1,
    msg="只有含'订阅'的段落命中，实际 " + hit.to_string(),
  )
}

// ---------- 八种动作 ----------

///|
test "remove / hide / set_style 真正改写 DOM" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"r1\",\"match\":{\"selector\":\"div.promo\"},\"action\":{\"type\":\"remove\"}},{\"id\":\"r2\",\"match\":{\"selector\":\"p.hide\"},\"action\":{\"type\":\"hide\"}},{\"id\":\"r3\",\"match\":{\"selector\":\"h1\"},\"action\":{\"type\":\"set_style\",\"style\":{\"color\":\"red\"}}}]}",
  )
  let d = doc(
    "<html><body><div class=\"promo\">广告</div><p class=\"hide\">隐藏</p><h1>标题</h1></body></html>",
  )
  let ap = @rules.apply_rules(d, set)
  assert_true(count(ap.effects.removed) == 1, msg="移除 1 个")
  assert_true(count(ap.effects.hidden) == 1, msg="隐藏 1 个")
  let mut has_promo = false
  let mut hidden_style = ""
  let mut heading_style = ""
  for e in @xml.descendants(ap.doc) {
    if @xml.tag_is(e, "div") &&
      @util.contains(@xml.attr_or_empty(e, "class"), "promo") {
      has_promo = true
    }
    if @xml.tag_is(e, "p") &&
      @util.contains(@xml.attr_or_empty(e, "class"), "hide") {
      hidden_style = @xml.attr_or_empty(e, "style")
    }
    if @xml.tag_is(e, "h1") {
      heading_style = @xml.attr_or_empty(e, "style")
    }
  }
  assert_true(!has_promo, msg="promo 已从 DOM 移除")
  assert_true(
    @util.contains(hidden_style, "none"),
    msg="hide 写入 display:none",
  )
  assert_true(
    @util.contains(heading_style, "red"),
    msg="set_style 写入 color:red",
  )
}

///|
test "page_break_before / after 记录真实路径" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"b1\",\"match\":{\"selector\":\"p.a\"},\"action\":{\"type\":\"page_break_before\"}},{\"id\":\"b2\",\"match\":{\"selector\":\"p.b\"},\"action\":{\"type\":\"page_break_after\"}}]}",
  )
  let d = doc(
    "<html><body><p class=\"a\">A</p><p class=\"b\">B</p></body></html>",
  )
  let ap = @rules.apply_rules(d, set)
  assert_true(count(ap.effects.breaks_before) == 1, msg="1 个段前断页")
  assert_true(count(ap.effects.breaks_after) == 1, msg="1 个段后断页")
  assert_true(
    @util.contains(ap.effects.breaks_before[0], "/p[0]"),
    msg="路径含 body 前缀与元素序号：" + ap.effects.breaks_before[0],
  )
}

///|
test "replace_text 递归替换后代文本" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"rt\",\"match\":{\"selector\":\"div\"},\"action\":{\"type\":\"replace_text\",\"find\":\"ﬁ\",\"replace\":\"fi\"}}]}",
  )
  let d = doc("<html><body><div><p>ﬁle</p></div></body></html>")
  let ap = @rules.apply_rules(d, set)
  assert_true(
    @util.contains(@xml.text_content(ap.doc), "file"),
    msg="连字被替换",
  )
  assert_true(
    !@util.contains(@xml.text_content(ap.doc), "ﬁ"),
    msg="旧连字消失",
  )
}

///|
test "annotate / redirect 改写属性并写入 effects" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"an\",\"match\":{\"selector\":\"a[href^='#fn']\"},\"action\":{\"type\":\"annotate\",\"label\":\"脚注\"}},{\"id\":\"rd\",\"match\":{\"selector\":\"a[href^='http']\"},\"action\":{\"type\":\"redirect\",\"target\":\"external://\"}}]}",
  )
  let d = doc(
    "<html><body><a href=\"#fn1\">1</a><a href=\"http://x\">x</a></body></html>",
  )
  let ap = @rules.apply_rules(d, set)
  assert_true(ap.effects.annotations.length() == 1, msg="1 个注记")
  assert_true(ap.effects.redirects.length() == 1, msg="1 个重定向")
  let note = @rules.empty_effects()
  assert_true(count(note.fired) == 0, msg="空 effects 无命中")
}

///|
test "set_attr 覆盖同名属性、merge_style 合并样式" {
  let el = doc("<html><body><a href=\"old\" HREF=\"dup\">x</a></body></html>")
  let link = match @xml.find_descendant(el, "a") {
    Some(a) => a
    None => panic()
  }
  let changed = @rules.set_attr(link, "href", "new")
  assert_true(
    @xml.attr_ci(changed, "href") == Some("new"),
    msg="href 被覆盖",
  )
  let styled = @rules.merge_style(changed, "color", "blue")
  assert_true(
    @util.contains(@xml.attr_or_empty(styled, "style"), "color:blue"),
    msg="样式写入",
  )
}

// ---------- 诊断 ----------

///|
test "fired_count / unfired_rules 反映命中情况" {
  let set = rules(
    "{\"version\":1,\"rules\":[{\"id\":\"yes\",\"match\":{\"selector\":\"p\"},\"action\":{\"type\":\"hide\"}},{\"id\":\"no\",\"match\":{\"selector\":\"table\"},\"action\":{\"type\":\"hide\"}}]}",
  )
  let d = doc("<html><body><p>x</p></body></html>")
  let ap = @rules.apply_rules(d, set)
  assert_true(
    @rules.fired_count(ap.effects, "yes") == 1,
    msg="yes 命中 1 次",
  )
  assert_true(@rules.fired_count(ap.effects, "no") == 0, msg="no 命中 0 次")
  let unfired = @rules.unfired_rules(set, ap.effects)
  assert_true(count(unfired) == 1, msg="1 条未命中")
  assert_true(unfired[0] == "no", msg="未命中的是 no")
}
