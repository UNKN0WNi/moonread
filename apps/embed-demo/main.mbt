///|
/// 可嵌入内核示例。
///
/// 这个程序演示宿主**只用内核 API** 能做完什么，不含任何 UI 框架：
///   打开书 -> 读元数据 -> 出目录 -> 分页 -> 逐页输出文本占位 -> 保存进度 -> 恢复
///
/// 输出是**确定性文本**，因此 `scripts/cross_target.sh` 可以拿它做
/// native / js / wasm-gc 三端逐字节比对。
fn main raise {
  println("=== MoonRead 可嵌入内核示例 ===")
  println(@core.kernel_info())
  println("")

  let archive = @epub.build(@epub.simple_spec())
  println(
    "[1] 内存构造 EPUB 归档：条目 " +
    @container.entry_count(archive).to_string(),
  )
  println(
    "    mimetype 首位 = " + bool_text(@container.mimetype_is_first(archive)),
  )

  let cfg = @config.default_config()
  let ruleset = match
    @rules.load_rules(
      "{\"version\":1,\"rules\":[" +
      "{\"id\":\"chapter-title-page\",\"match\":{\"selector\":\"body > h1:first-child\"}," +
      "\"action\":{\"type\":\"page_break_before\"}}," +
      "{\"id\":\"strip-ad\",\"match\":{\"selector\":\"div.promo\",\"text_regex\":\"subscribe|订阅\"}," +
      "\"action\":{\"type\":\"remove\"}}]}",
    ) {
    Ok(r) => r
    Err(_) => panic()
  }

  let book = match @core.open_book(archive, cfg, ruleset, @render.Null) {
    Ok(b) => b
    Err(_) => panic()
  }

  println("[2] " + @epub.describe(book.epub))
  println("")
  println("[3] 目录（来源 " + book.toc.source + "）")
  println(@toc.render_text(book.toc))

  let pages = match @core.render_chapter(book, 0) {
    Ok(cp) => cp
    Err(_) => panic()
  }
  let total = @paginate.page_count(pages.paginated)
  println("")
  println(
    "[4] 第一章「" +
    pages.title +
    "」：块 " +
    pages.blocks.length().to_string() +
    " 个 -> 页 " +
    total.to_string(),
  )

  let mut i = 0
  while i < total {
    let pg = pages.paginated.pages[i]
    println(
      "    第 " +
      (i + 1).to_string() +
      " 页 高度 " +
      pg.used.to_string() +
      " 片段 " +
      pg.fragments.length().to_string() +
      " 页脚 '" +
      pages.footers[i] +
      "'",
    )
    i = i + 1
  }

  println("")
  println(
    "[5] 不变式：" + invariant_line(pages, @config.to_page_policy(cfg)),
  )

  let reader = @core.new_reader(book)
  let progress = @core.progress_of(reader, pages, "2026-11-19T00:00:00Z")
  let text = @paginator.progress_to_json(progress)
  println("")
  println("[6] 进度 JSON：" + text)
  let back = match @paginator.progress_from_json(text) {
    Ok(p) => p
    Err(_) => panic()
  }
  assert_true(back == progress, msg="进度往返必须等价")
  println(
    "    往返一致 = true；可读形式：" + @paginator.describe(back),
  )

  println("")
  println(
    "[7] 规则命中统计：断页前 " +
    pages.effects.breaks_before.length().to_string() +
    " 处，移除 " +
    pages.effects.removed.length().to_string() +
    " 个元素",
  )
  for u in @rules.unfired_rules(ruleset, pages.effects) {
    println("    未命中规则：" + u)
  }

  println("")
  println("=== 示例结束 ===")
}

///|
fn bool_text(b : Bool) -> String {
  if b {
    "true"
  } else {
    "false"
  }
}

///|
fn invariant_line(
  cp : @core.ChapterPages,
  policy : @paginate.PagePolicy,
) -> String {
  let a = @paginate.invariant_no_content_loss(cp.blocks, cp.paginated)
  let b = @paginate.invariant_within_page_height(policy, cp.paginated)
  let c = @paginate.invariant_monotonic(cp.paginated)
  let d = @paginate.invariant_idempotent(cp.blocks, policy)
  "不丢内容=" +
  bool_text(a) +
  " 不越界=" +
  bool_text(b) +
  " 单调=" +
  bool_text(c) +
  " 幂等=" +
  bool_text(d)
}
