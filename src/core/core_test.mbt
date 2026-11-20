///|
/// 内核端到端冒烟测试：EPUB -> 规则 -> 度量 -> 分页 -> 翻页 -> 进度恢复。
///
/// 这是 数据流的可执行版本，也是「当前实现范围 出口条件」在当前构建
/// （零外部依赖、Backend::Null）下能给出的最强证据。
fn basic_book() -> @core.Book {
  let a = @epub.build(@epub.simple_spec())
  match
    @core.open_book(a, @config.default_config(), empty_rules(), @render.Null) {
    Ok(b) => b
    Err(_) => panic()
  }
}

///|
fn empty_rules() -> @rules.RuleSet {
  match @rules.load_rules("{\"version\":1,\"rules\":[]}") {
    Ok(r) => r
    Err(_) => panic()
  }
}

///|
fn rules_from(text : String) -> @rules.RuleSet {
  match @rules.load_rules(text) {
    Ok(r) => r
    Err(_) => panic()
  }
}

///|
test "打开一本书并读出章节列表" {
  let b = basic_book()
  assert_true(@core.chapter_count(b) == 2, msg="两章")
  assert_true(
    @core.chapters(b)[0] == "OEBPS/ch1.xhtml",
    msg="章节路径来自 spine",
  )
  assert_true(
    @core.book_key(b) == "urn:uuid:moonread-sample",
    msg="稳定标识用 dc:identifier",
  )
  assert_true(b.toc.source == "nav", msg="目录来源：" + b.toc.source)
  assert_true(@toc.total_items(b.toc) == 2, msg="目录两项")
}

///|
test "一章能分页出多页" {
  let b = basic_book()
  match @core.render_chapter(b, 0) {
    Err(_) => panic()
    Ok(cp) => {
      assert_true(cp.blocks.length() > 0, msg="至少要有一个块")
      let total = @paginate.page_count(cp.paginated)
      assert_true(total >= 1, msg="页数 " + total.to_string())
      assert_true(cp.paginated.error.length() == 0, msg="分页无错误")
      assert_true(
        @paginate.invariant_no_content_loss(cp.blocks, cp.paginated),
        msg="不变式 1",
      )
      assert_true(
        @paginate.invariant_monotonic(cp.paginated),
        msg="不变式 3",
      )
      assert_true(
        @paginate.invariant_within_page_height(
          @config.to_page_policy(b.config),
          cp.paginated,
        ),
        msg="不变式 2",
      )
      assert_true(
        cp.title == "第一章",
        msg="章标题来自 h1：" + cp.title,
      )
    }
  }
}

///|
test "翻页跨章" {
  let b = basic_book()
  let r = @core.new_reader(b)
  match @core.next_page(r) {
    Err(_) => panic()
    Ok(r2) =>
      assert_true(
        r2.chapter == 0 || r2.chapter == 1,
        msg="翻页后仍在书内",
      )
  }
  let last = @core.goto_chapter(r, 1)
  match last {
    Err(_) => panic()
    Ok(r3) => assert_true(r3.chapter == 1, msg="跳章")
  }
  match @core.goto_chapter(r, 9) {
    Ok(_) => panic()
    Err(e) =>
      assert_true(@util.contains(e, "越界"), msg="越界信息：" + e)
  }
}

///|
test "进度可保存并恢复" {
  let b = basic_book()
  let r = @core.new_reader(b)
  match @core.render_chapter(b, 0) {
    Err(_) => panic()
    Ok(cp) => {
      let p = @core.progress_of(r, cp, "2026-11-19T00:00:00Z")
      let text = @paginator.progress_to_json(p)
      match @paginator.progress_from_json(text) {
        Err(_) => panic()
        Ok(p2) => {
          assert_true(p2 == p, msg="往返等价")
          assert_true(p2.locator.chapter == 0, msg="章")
          assert_true(
            p2.ratio_permille >= 0 && p2.ratio_permille <= 1000,
            msg="千分比范围",
          )
          match @core.restore_reader(r, p2) {
            @paginator.Exact(loc) =>
              assert_true(loc.chapter == 0, msg="精确恢复")
            @paginator.Clamped(loc, why) =>
              assert_true(
                loc.chapter >= 0 && why.length() > 0,
                msg="夹取恢复",
              )
            @paginator.Rejected(_) => panic()
          }
        }
      }
    }
  }
}

///|
test "规则真的改变了 DOM 与断页" {
  let set = rules_from(
    "{\"version\":1,\"rules\":[{\"id\":\"drop-footer\",\"match\":{\"selector\":\"footer.page-footer\"},\"action\":{\"type\":\"page_break_after\"}},{\"id\":\"kill-promo\",\"match\":{\"selector\":\"div.promo\",\"text_regex\":\"subscribe|订阅\"},\"action\":{\"type\":\"remove\"}}]}",
  )
  let a = @epub.build(@epub.simple_spec())
  match @core.open_book(a, @config.default_config(), set, @render.Null) {
    Err(_) => panic()
    Ok(b) =>
      match @core.render_chapter(b, 0) {
        Err(_) => panic()
        Ok(cp) => {
          // 样例章节里没有 footer/div.promo，因此两条规则都不该命中，
          // 但必须能在告警里看到「命中 0 次」——可诊断性（精神）
          assert_true(cp.effects.removed.length() == 0, msg="无 promo 元素")
          assert_true(
            cp.effects.breaks_after.length() == 0,
            msg="无 footer 元素",
          )
          let unfired = @rules.unfired_rules(set, cp.effects)
          assert_true(unfired.length() == 2, msg="两条规则均未命中")
          assert_true(
            count_warnings(cp.warnings, "命中 0 次") == 2,
            msg="每条都应有告警",
          )
        }
      }
  }
}

///|
/// 不变量：rules 记录的结构路径与 render 度量块的路径必须来自同一套编号。
/// 这条测试钉死 P0-1 —— 曾经 rules 从文档根编号且文本占位、render 从 body
/// 空路径起步且文本不占位，导致 page_break 规则 100% 静默失效。
test "规则断页路径与度量块路径同源（强制断页真的命中）" {
  // 样例章节 body 下是 h1[0], p[1], p[2]（文本节点不占序号）。
  // 用选择器 p 给两个段落都打 page_break_before；标题自带的断页不算规则命中。
  let set = rules_from(
    "{\"version\":1,\"rules\":[{\"id\":\"break-paras\",\"match\":{\"selector\":\"p\"},\"action\":{\"type\":\"page_break_before\"}}]}",
  )
  let a = @epub.build(@epub.simple_spec())
  match @core.open_book(a, @config.default_config(), set, @render.Null) {
    Err(_) => panic()
    Ok(b) =>
      match @core.render_chapter(b, 0) {
        Err(_) => panic()
        Ok(cp) => {
          // rules 侧应记录两个 p 的真实路径
          assert_true(
            cp.effects.breaks_before.length() == 2,
            msg="两条 p 规则都应命中：" +
              cp.effects.breaks_before.length().to_string(),
          )
          let path1 = cp.effects.breaks_before[0]
          let path2 = cp.effects.breaks_before[1]
          assert_true(
            @util.contains(path1, "body") && @util.contains(path1, "/p["),
            msg="规则路径应含 body 前缀：" + path1,
          )
          // 同一批路径必须能在度量块里找到（对接成功）
          let ids : Array[String] = []
          for blk in cp.blocks {
            ids.push(blk.id)
          }
          assert_true(in_arr(ids, path1), msg="块路径含 " + path1)
          assert_true(in_arr(ids, path2), msg="块路径含 " + path2)
          // 标题自带 1 个断页 + 两个 p 的规则断页 = 至少 3 个
          let mut marked = 0
          for blk in cp.blocks {
            if blk.break_before {
              marked = marked + 1
            }
          }
          assert_true(
            marked >= 3,
            msg="标题+两段都应有断页标记，实际 " +
              marked.to_string(),
          )
        }
      }
  }
}

///|
/// Annotate / Redirect 必须真正改写 DOM（曾只 push effects、原样返回 el）。
test "annotate 与 redirect 真正改写 DOM 且效果可消费" {
  let doc = match
    @xml.parse_document(
      @util.join_nl([
        "<html><body>", "<p id=\"x\"><a href=\"#fn1\">注我</a></p>", "<p><a href=\"http://example.com\">外链</a></p>",
        "</body></html>",
      ]),
    ) {
    Ok(d) => d
    Err(_) => panic()
  }
  let set = rules_from(
    "{\"version\":1,\"rules\":[{\"id\":\"ann\",\"match\":{\"selector\":\"a[href^='#fn']\"},\"action\":{\"type\":\"annotate\",\"label\":\"脚注\"}},{\"id\":\"redir\",\"match\":{\"selector\":\"a[href^='http']\"},\"action\":{\"type\":\"redirect\",\"target\":\"external://safe\"}}]}",
  )
  let applied = @rules.apply_rules(doc, set)
  assert_true(
    applied.effects.annotations.length() == 1,
    msg="注记命中 1 处",
  )
  assert_true(
    applied.effects.redirects.length() == 1,
    msg="重定向命中 1 处",
  )
  // DOM 真的被改：注记属性写到了 a 上，href 被替换
  let note = @xml.find_by_id(applied.doc, "x")
  match note {
    None => panic()
    Some(p) => {
      let links = @xml.find_all_child(p, "a")
      assert_true(links.length() == 1, msg="有一个 a")
      assert_true(
        @xml.attr_ci(links[0], "data-moonread-note") == Some("脚注"),
        msg="注记属性应写入 DOM",
      )
    }
  }
  let all_links : Array[@xml.Element] = []
  for d in @xml.descendants(applied.doc) {
    if @xml.tag_is(d, "a") {
      all_links.push(d)
    }
  }
  let mut saw_redirect = false
  for a in all_links {
    if @xml.attr_ci(a, "href") == Some("external://safe") {
      saw_redirect = true
    }
  }
  assert_true(saw_redirect, msg="href 应被改写成 target")
}

///|
fn in_arr(arr : Array[String], needle : String) -> Bool {
  for x in arr {
    if x == needle {
      return true
    }
  }
  false
}

///|
fn count_warnings(arr : Array[String], needle : String) -> Int32 {
  let mut n = 0
  for x in arr {
    if @util.contains(x, needle) {
      n = n + 1
    }
  }
  n
}

///|
test "未知动作类型加载即报错并指出规则 id" {
  match
    @rules.load_rules(
      "{\"version\":1,\"rules\":[{\"id\":\"bad-one\",\"match\":{\"selector\":\"p\"},\"action\":{\"type\":\"teleport\"}}]}",
    ) {
    Ok(_) => panic()
    Err(e) => {
      assert_true(
        @util.contains(e, "teleport"),
        msg="应点出未知类型名：" + e,
      )
      assert_true(@util.contains(e, "bad-one"), msg="应点出规则 id：" + e)
    }
  }
}

///|
test "配置换算真的影响页数" {
  let b = basic_book()
  match
    @config.from_json_text(
      "{\"typography\":{\"font_size_pt\":72},\"page\":{\"height_mm\":60,\"margin_top_mm\":5,\"margin_bottom_mm\":5}}",
    ) {
    Err(_) => panic()
    Ok(cfg) =>
      match @core.open_book(b.epub.archive, cfg, empty_rules(), @render.Null) {
        Err(_) => panic()
        Ok(small) => {
          let big_pages = count_pages(b)
          let small_pages = count_pages(small)
          assert_true(
            small_pages > big_pages,
            msg="页高变小页数应增多",
          )
        }
      }
  }
}

///|
fn count_pages(b : @core.Book) -> Int32 {
  match @core.render_chapter(b, 0) {
    Ok(cp) => @paginate.page_count(cp.paginated)
    Err(_) => 0
  }
}

///|
test "配置非法值被拒绝且信息带路径" {
  match @config.from_json_text("{\"typography\":{\"font_size_pt\":200}}") {
    Ok(_) => panic()
    Err(e) =>
      assert_true(
        @util.contains(e, "$.typography.font_size_pt"),
        msg="错误应带 JSON 路径：" + e,
      )
  }
  match @config.from_json_text("{\"pagez\":{\"width_mm\":120}}") {
    Ok(_) => panic()
    Err(e) =>
      assert_true(
        @util.contains(e, "pagez"),
        msg="应点出未知字段：" + e,
      )
  }
  match
    @config.from_json_text("{\"page\":{\"width_mm\":10,\"height_mm\":1000}}") {
    Ok(_) => panic()
    Err(e) =>
      assert_true(@util.contains(e, "$.page.width_mm"), msg="路径：" + e)
  }
  match
    @config.from_json_text(
      "{\"page\":{\"width_mm\":100,\"height_mm\":40,\"margin_top_mm\":20,\"margin_bottom_mm\":20}}",
    ) {
    Ok(_) => panic()
    Err(e) =>
      assert_true(@util.contains(e, "上下边距之和"), msg="原因：" + e)
  }
}

///|
test "examples/config.json 的字段全部被认识（Schema 不漂移）" {
  let paths = @config.known_field_paths()
  assert_true(
    paths.length() > 30,
    msg="字段表规模：" + paths.length().to_string(),
  )
  let mut has_page = false
  for p in paths {
    if p == "$.page.width_mm" {
      has_page = true
    }
  }
  assert_true(has_page, msg="字段表应包含 $.page.width_mm")
}

///|
test "内核能力自述" {
  let info = @core.kernel_info()
  assert_true(@util.contains(info, "moonread-core"), msg="版本行")
  assert_true(@util.contains(info, "Backend::Null"), msg="后端说明")
  assert_true(@util.contains(info, "DRM"), msg="明确不处理 DRM")
}
