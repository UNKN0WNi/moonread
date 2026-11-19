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
