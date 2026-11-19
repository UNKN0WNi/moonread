///|
/// 分页算法测试（四条不变式 +  交付项）。
///
/// 这些断言是 `moon prove` 目标的前置运行时版本（：证明需要外部求解器，
/// 因此运行时断言必须先把四条不变式钉住，见已知风险 的缓解）。
fn page_limit(height_mm : Double) -> @paginate.PagePolicy {
  let p = @paginate.default_policy()
  @paginate.PagePolicy::{
    page_width: p.page_width,
    page_height: height_mm,
    margin_top: 0.0,
    margin_bottom: 0.0,
    margin_inner: 0.0,
    margin_outer: 0.0,
    column_gap: 0.0,
    header_template: "",
    footer_template: "",
    orphan_min: p.orphan_min,
    widow_min: p.widow_min,
    break_after_chapter_start: p.break_after_chapter_start,
    honor_rtl: false,
  }
}

///|
fn no_break_policy() -> @paginate.PagePolicy {
  let p = page_limit(10.0)
  @paginate.PagePolicy::{
    page_width: p.page_width,
    page_height: p.page_height,
    margin_top: p.margin_top,
    margin_bottom: p.margin_bottom,
    margin_inner: p.margin_inner,
    margin_outer: p.margin_outer,
    column_gap: p.column_gap,
    header_template: p.header_template,
    footer_template: p.footer_template,
    orphan_min: 0,
    widow_min: 0,
    break_after_chapter_start: false,
    honor_rtl: false,
  }
}

///|
fn all_pass(
  name : String,
  blocks : Array[@paginate.Block],
  policy : @paginate.PagePolicy,
) -> Unit raise {
  let failures = @paginate.check_all_invariants(blocks, policy)
  assert_true(failures.length() == 0, msg=name)
}

///|
test "参考实现：分页不丢内容" {
  let heights = [10.0, 20.0, 30.0, 40.0]
  let pages = @paginate.paginate_heights(heights, 35.0)
  assert_true(
    @paginate.approx_eq(
      @paginate.sum_block_heights_list(pages),
      @paginate.sum_block_heights_list(heights),
    ),
    msg="分页丢内容",
  )
  assert_true(
    pages.length() == 3,
    msg="应切成 3 页：" + pages.length().to_string(),
  )
  assert_true(@paginate.approx_eq(pages[0], 30.0), msg="第一页 10+20")
  assert_true(@paginate.approx_eq(pages[1], 30.0), msg="第二页 30")
  assert_true(
    @paginate.approx_eq(pages[2], 40.0),
    msg="第三页 40（单块超限独占）",
  )
}

///|
test "参考实现的边界" {
  assert_true(
    @paginate.paginate_heights([], 35.0).length() == 0,
    msg="空输入零页",
  )
  assert_true(
    @paginate.paginate_heights([5.0], 0.0).length() == 1,
    msg="limit<=0 时整块一页",
  )
  assert_true(
    @paginate.approx_eq(@paginate.paginate_heights([5.0], 0.0)[0], 5.0),
    msg="总量不变",
  )
  assert_true(
    @paginate.paginate_heights([-1.0, 5.0], 10.0).length() == 1,
    msg="负高度跳过",
  )
}

///|
test "不变式 1：可拆块跨页不丢内容" {
  let blocks = [@paginate.text_block("a", 100, 1.0)]
  let p = page_limit(30.0)
  let r = @paginate.paginate(blocks, p)
  assert_true(r.error.length() == 0, msg="不应报错：" + r.error)
  assert_true(
    @paginate.approx_eq(@paginate.sum_fragment_heights(r), 100.0),
    msg="100 行必须都在",
  )
  assert_true(
    @paginate.page_count(r) == 4,
    msg="100 行 / 每页 30 => 4 页：" + @paginate.page_count(r).to_string(),
  )
  all_pass("可拆块", blocks, p)
}

///|
test "不变式 2：不越界" {
  let blocks = [
    @paginate.text_block("a", 40, 1.0),
    @paginate.text_block("b", 40, 1.0),
  ]
  let p = page_limit(25.0)
  let r = @paginate.paginate(blocks, p)
  for pg in r.pages {
    assert_true(
      pg.used <= 25.0 + 0.000001,
      msg="页 " + pg.index.to_string() + " 溢出",
    )
  }
  all_pass("两块", blocks, p)
}

///|
test "不变式 3：片段序号严格单调" {
  let blocks = [
    @paginate.text_block("a", 10, 1.0),
    @paginate.image_block("img", 50.0),
    @paginate.text_block("b", 70, 1.0),
  ]
  let r = @paginate.paginate(blocks, page_limit(20.0))
  let mut last = -1
  let mut ok = true
  for pg in r.pages {
    for f in pg.fragments {
      if f.seq <= last {
        ok = false
      }
      last = f.seq
    }
  }
  assert_true(ok, msg="seq 必须严格递增")
  assert_true(@paginate.invariant_monotonic(r), msg="不变式 3 函数版本")
}

///|
test "不变式 4：幂等且不改输入" {
  let blocks = [
    @paginate.text_block("a", 33, 2.0),
    @paginate.text_block("b", 17, 2.0),
  ]
  let p = page_limit(50.0)
  let total_before = @paginate.sum_block_heights(blocks)
  let r1 = @paginate.paginate(@paginate.copy_blocks(blocks), p)
  let r2 = @paginate.paginate(@paginate.copy_blocks(blocks), p)
  assert_true(r1 == r2, msg="两次结果必须完全相同")
  assert_true(
    @paginate.approx_eq(@paginate.sum_block_heights(blocks), total_before),
    msg="输入未被修改",
  )
  assert_true(
    @paginate.invariant_idempotent(blocks, p),
    msg="不变式 4 函数版本",
  )
}

///|
test "孤儿约束：本页至少留 orphan_min 行" {
  let p = page_limit(10.0)
  let blocks = [@paginate.text_block("a", 12, 1.0)]
  let r = @paginate.paginate(blocks, p)
  // 12 行、每页 10 行：若允许拆成 10+2，则第二页只有 2 行 >= widow_min(2)，
  // 且第一页 10 行 >= orphan_min(2) —— 应当允许拆
  assert_true(@paginate.page_count(r) == 2, msg="应拆成两页")
  assert_true(
    @paginate.approx_eq(r.pages[0].used, 10.0),
    msg="第一页 10 行",
  )
  assert_true(@paginate.approx_eq(r.pages[1].used, 2.0), msg="第二页 2 行")
  all_pass("孤儿", blocks, p)
}

///|
test "寡妇约束：下一页至少留 widow_min 行" {
  let p = page_limit(10.0)
  // 11 行、每页 10 行：拆成 10+1 会让下一页只有 1 行 < widow_min(2)，
  // 因此应回退为 9+2
  let blocks = [@paginate.text_block("a", 11, 1.0)]
  let r = @paginate.paginate(blocks, p)
  assert_true(@paginate.page_count(r) == 2, msg="仍两页")
  assert_true(
    @paginate.approx_eq(r.pages[0].used, 9.0),
    msg="第一页 9 行，实际 " + r.pages[0].used.to_string(),
  )
  assert_true(@paginate.approx_eq(r.pages[1].used, 2.0), msg="第二页 2 行")
  all_pass("寡妇", blocks, p)
}

///|
test "widow/orphan 取 0 时按最紧拆分" {
  let p = no_break_policy()
  let blocks = [@paginate.text_block("a", 21, 1.0)]
  let r = @paginate.paginate(blocks, p)
  assert_true(@paginate.page_count(r) == 3, msg="21 行 / 10 每页 => 3 页")
  assert_true(@paginate.approx_eq(r.pages[0].used, 10.0), msg="满页")
  assert_true(@paginate.approx_eq(r.pages[2].used, 1.0), msg="末页 1 行")
  all_pass("无 widow/orphan", blocks, p)
}

///|
test "章节起始强制新页" {
  let p = page_limit(100.0)
  let blocks = [
    @paginate.text_block("a", 10, 1.0),
    @paginate.with_chapter_start(@paginate.text_block("b", 10, 1.0)),
  ]
  let r = @paginate.paginate(blocks, p)
  assert_true(@paginate.page_count(r) == 2, msg="章节起始另起一页")
  assert_true(
    r.pages[1].fragments[0].block_id == "b",
    msg="第二页首块是 b",
  )
  all_pass("章节起始", blocks, p)
}

///|
test "break_after_chapter_start=false 时章节不强制新页" {
  let base = page_limit(100.0)
  let p = @paginate.PagePolicy::{
    page_width: base.page_width,
    page_height: base.page_height,
    margin_top: base.margin_top,
    margin_bottom: base.margin_bottom,
    margin_inner: base.margin_inner,
    margin_outer: base.margin_outer,
    column_gap: base.column_gap,
    header_template: base.header_template,
    footer_template: base.footer_template,
    orphan_min: 0,
    widow_min: 0,
    break_after_chapter_start: false,
    honor_rtl: false,
  }
  let blocks = [
    @paginate.text_block("a", 10, 1.0),
    @paginate.with_chapter_start(@paginate.text_block("b", 10, 1.0)),
  ]
  let r = @paginate.paginate(blocks, p)
  assert_true(@paginate.page_count(r) == 1, msg="同页连续")
  all_pass("连续章节", blocks, p)
}

///|
test "规则产生的强制断页：page_break_before / after" {
  let p = page_limit(100.0)
  let blocks = [
    @paginate.with_break_after(@paginate.text_block("a", 5, 1.0)),
    @paginate.text_block("b", 5, 1.0),
    @paginate.with_break_before(@paginate.text_block("c", 5, 1.0)),
    @paginate.text_block("d", 5, 1.0),
  ]
  let r = @paginate.paginate(blocks, p)
  assert_true(
    @paginate.page_count(r) == 3,
    msg="a | b c? —— 实际 " + @paginate.page_count(r).to_string(),
  )
  assert_true(r.pages[0].fragments.length() == 1, msg="第一页只有 a")
  assert_true(r.pages[1].fragments[0].block_id == "b", msg="b 起第二页")
  assert_true(r.pages[2].fragments[0].block_id == "c", msg="c 强制第三页")
  all_pass("强制断页", blocks, p)
}

///|
test "不可拆块：整块推页，超大块独占一页并允许溢出" {
  let p = page_limit(50.0)
  let blocks = [
    @paginate.text_block("a", 10, 1.0),
    @paginate.image_block("big", 120.0),
    @paginate.text_block("b", 10, 1.0),
  ]
  let r = @paginate.paginate(blocks, p)
  assert_true(@paginate.page_count(r) == 3, msg="a | big | b")
  assert_true(@paginate.approx_eq(r.pages[1].used, 120.0), msg="大图独占")
  assert_true(
    @paginate.approx_eq(@paginate.sum_fragment_heights(r), 140.0),
    msg="不丢内容",
  )
  // 不变式 2 的例外：单块超过整页时不判越界
  assert_true(
    @paginate.invariant_within_page_height(p, r),
    msg="单块独占页属于例外",
  )
  assert_true(
    @paginate.invariant_no_content_loss(blocks, r),
    msg="不变式 1 仍成立",
  )
  assert_true(@paginate.invariant_monotonic(r), msg="不变式 3 仍成立")
}

///|
test "keep-with-next：标题不与正文分离" {
  let p = page_limit(20.0)
  let blocks = [
    @paginate.text_block("body1", 15, 1.0),
    @paginate.heading_block("h", 5.0),
    @paginate.text_block("body2", 15, 1.0),
  ]
  let r = @paginate.paginate(blocks, p)
  let mut heading_alone_at_bottom = false
  for pg in r.pages {
    let fs = pg.fragments
    if fs.length() > 0 &&
      fs[fs.length() - 1].block_id == "h" &&
      pg.used >= 20.0 - 0.000001 {
      heading_alone_at_bottom = true
    }
  }
  assert_true(!heading_alone_at_bottom, msg="标题不得成为页尾孤块")
  all_pass("keep-with-next", blocks, p)
}

///|
test "输入校验：内容区高度非正" {
  let p = page_limit(0.0)
  let r = @paginate.paginate([@paginate.text_block("a", 5, 1.0)], p)
  assert_true(r.error.length() > 0, msg="应给出错误")
  assert_true(@paginate.page_count(r) == 0, msg="不产出页")
  let failures = @paginate.check_all_invariants(
    [@paginate.text_block("a", 5, 1.0)],
    p,
  )
  assert_true(failures.length() == 1, msg="报告一条输入非法")
  assert_true(
    @util.contains(failures[0], "内容区高度非正"),
    msg="原因可读",
  )
}

///|
test "输入校验：块高度为负 / 可拆块行高非正" {
  let p = page_limit(50.0)
  let bad1 = @paginate.atomic_block("x", BKOther, -3.0)
  assert_true(@paginate.check_consistent(bad1).length() > 0, msg="负高度")
  let bad2 = @paginate.Block::{
    id: "y",
    kind: BKText,
    height: 10.0,
    line_height: 0.0,
    lines: 5,
    splittable: true,
    break_before: false,
    break_after: false,
    chapter_start: false,
    keep_with_next: false,
  }
  assert_true(
    @util.contains(@paginate.check_consistent(bad2), "行高非正"),
    msg="可拆块行高非正",
  )
  let r = @paginate.paginate([bad2], p)
  assert_true(r.error.length() > 0, msg="paginate 拒绝不一致的块")
}

///|
test "floor_lines 向下取整" {
  assert_true(@paginate.floor_lines(10.0, 3.0) == 3, msg="10/3=3")
  assert_true(@paginate.floor_lines(9.0, 3.0) == 3, msg="整除")
  assert_true(@paginate.floor_lines(2.9, 3.0) == 0, msg="不足一行")
  assert_true(@paginate.floor_lines(10.0, 0.0) == 0, msg="行高非正")
  assert_true(@paginate.floor_lines(-1.0, 3.0) == 0, msg="负余量")
}

///|
test "页眉页脚模板变量" {
  let p = page_limit(30.0)
  let blocks = [@paginate.text_block("a", 100, 1.0)]
  let r = @paginate.paginate(blocks, p)
  let footers = @paginate.page_footers(
    @paginate.PagePolicy::{
      page_width: p.page_width,
      page_height: p.page_height,
      margin_top: p.margin_top,
      margin_bottom: p.margin_bottom,
      margin_inner: p.margin_inner,
      margin_outer: p.margin_outer,
      column_gap: p.column_gap,
      header_template: "{chapter}",
      footer_template: "{page} / {total}",
      orphan_min: p.orphan_min,
      widow_min: p.widow_min,
      break_after_chapter_start: p.break_after_chapter_start,
      honor_rtl: p.honor_rtl,
    },
    r,
    "第一章",
  )
  assert_true(footers.length() == 4, msg="四页")
  assert_true(footers[0] == "1 / 4", msg="首页页脚：" + footers[0])
  assert_true(footers[3] == "4 / 4", msg="末页页脚：" + footers[3])
  let hs = @paginate.page_headers(
    @paginate.PagePolicy::{
      page_width: p.page_width,
      page_height: p.page_height,
      margin_top: p.margin_top,
      margin_bottom: p.margin_bottom,
      margin_inner: p.margin_inner,
      margin_outer: p.margin_outer,
      column_gap: p.column_gap,
      header_template: "{chapter}",
      footer_template: "",
      orphan_min: p.orphan_min,
      widow_min: p.widow_min,
      break_after_chapter_start: p.break_after_chapter_start,
      honor_rtl: p.honor_rtl,
    },
    r,
    "第一章",
  )
  assert_true(hs[0] == "第一章", msg="章名页眉")
  assert_true(
    @paginate.render_label("第 {page} 页 未知 {var}", 2, 10, "X") ==
    "第 3 页 未知 {var}",
    msg="未识别变量原样保留",
  )
}

///|
test "RTL 影响内外边距" {
  let ltr = @paginate.default_policy()
  assert_true(
    @paginate.approx_eq(@paginate.content_indent(ltr), ltr.margin_inner),
    msg="LTR 缩进=inner",
  )
  let p = @paginate.PagePolicy::{
    page_width: ltr.page_width,
    page_height: ltr.page_height,
    margin_top: ltr.margin_top,
    margin_bottom: ltr.margin_bottom,
    margin_inner: ltr.margin_inner,
    margin_outer: ltr.margin_outer,
    column_gap: ltr.column_gap,
    header_template: ltr.header_template,
    footer_template: ltr.footer_template,
    orphan_min: ltr.orphan_min,
    widow_min: ltr.widow_min,
    break_after_chapter_start: ltr.break_after_chapter_start,
    honor_rtl: true,
  }
  assert_true(
    @paginate.approx_eq(@paginate.content_indent(p), p.margin_outer),
    msg="RTL 缩进=outer",
  )
  assert_true(
    @paginate.approx_eq(
      @paginate.content_width(p),
      @paginate.content_width(ltr),
    ),
    msg="总宽不变",
  )
}

///|
test "默认策略换算与 配置一致" {
  let p = @paginate.default_policy()
  assert_true(
    @paginate.approx_eq(p.page_width, @paginate.mm_to_px(120.0)),
    msg="120mm 页宽",
  )
  assert_true(
    @paginate.approx_eq(p.page_height, @paginate.mm_to_px(180.0)),
    msg="180mm 页高",
  )
  assert_true(
    @paginate.approx_eq(@paginate.content_height(p), @paginate.mm_to_px(147.0)),
    msg="180-15-18=147mm",
  )
  assert_true(@paginate.content_width(p) > 0.0, msg="内容宽度为正")
}

///|
test "大量块的组合仍然全绿" {
  let blocks : Array[@paginate.Block] = []
  let mut i = 0
  while i < 60 {
    blocks.push(
      @paginate.text_block(
        "t" + i.to_string(),
        i % 7 + 1,
        1.0 + (i % 3).to_double(),
      ),
    )
    if i % 11 == 0 {
      blocks.push(
        @paginate.image_block("img" + i.to_string(), 30.0 + (i % 5).to_double()),
      )
    }
    if i % 17 == 0 {
      blocks.push(@paginate.heading_block("h" + i.to_string(), 8.0))
    }
    i = i + 1
  }
  let p = @paginate.default_policy()
  all_pass("60+ 块组合", blocks, p)
  let r = @paginate.paginate(@paginate.copy_blocks(blocks), p)
  assert_true(
    @paginate.page_count(r) >= 2,
    msg="应产生多页：" + @paginate.page_count(r).to_string(),
  )
}
