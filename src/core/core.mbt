/// `moonread-core`：可嵌入内核门面。
///
/// 本文件是 数据流的**唯一编排点**：
///
/// ```text
/// Archive -> epub.open -> EpubBook
///                         -> toc.from_book
/// 章节 XHTML -> xml.parse -> rules.apply_rules -> render.measure
///                                                  -> paginate.paginate
///                                                  -> 页眉页脚 / 定位
/// ```
///
/// 依赖方向自查（）：core 依赖 L2 + L3 + L4，**不被它们依赖**；
/// 本包不 import 任何 UI 框架，因此可以整体编成单个 wasm 供宿主嵌入。

///|
/// 打开后的书本。不可变：所有翻页操作返回新的 `Reader`。
#derive(Debug, Eq)
pub(all) struct Book {
  epub : @epub.EpubBook
  toc : @toc.Toc
  config : @config.Config
  rules : @rules.RuleSet
  backend : @render.Backend
}

///|
/// 一章的分页结果。
#derive(Debug, Eq)
pub(all) struct ChapterPages {
  chapter_index : Int32
  chapter_path : String
  title : String
  /// 规则改写后的 DOM，供渲染层继续消费。
  doc : @xml.Element
  blocks : Array[@paginate.Block]
  paginated : @paginate.Paginated
  headers : Array[String]
  footers : Array[String]
  effects : @rules.RuleEffects
  warnings : Array[String]
}

///|
pub fn open_book(
  a : @container.Archive,
  cfg : @config.Config,
  rules : @rules.RuleSet,
  backend : @render.Backend,
) -> Result[Book, String] {
  match @epub.open(a) {
    Err(e) => Err("打开失败：" + e)
    Ok(epub) => {
      let policy = @config.to_page_policy(cfg)
      if @paginate.content_height(policy) <= 0.0 {
        return Err(
          "配置换算出的内容区高度非正，请检查 page 段",
        )
      }
      Ok(Book::{ epub, toc: @toc.from_book(epub), config: cfg, rules, backend, })
    }
  }
}

///|
pub fn chapters(b : Book) -> Array[String] {
  @epub.chapter_paths(b.epub)
}

///|
pub fn chapter_count(b : Book) -> Int32 {
  @epub.chapter_paths(b.epub).length()
}

///|
/// 章节标题：优先用目录里指向该章的第一项，其次用 `<h1>`，最后用文件名。
pub fn chapter_title(b : Book, index : Int32) -> String {
  let paths = chapters(b)
  if index < 0 || index >= paths.length() {
    return ""
  }
  let path = paths[index]
  let mut from_toc = ""
  for it in @toc.depth_first(b.toc.items) {
    if it.path == path && from_toc.length() == 0 {
      from_toc = it.label
    }
  }
  if from_toc.length() > 0 {
    return from_toc
  }
  match render_chapter(b, index) {
    Err(_) => @util.path_basename(path)
    Ok(parsed) =>
      match @xml.find_descendant(parsed.doc, "h1") {
        None => @util.path_basename(path)
        Some(h) => {
          let t = @util.trim(@xml.text_content(h))
          if t.length() > 0 {
            t
          } else {
            @util.path_basename(path)
          }
        }
      }
  }
}

///|
/// 完整管线：读章 -> 解析 -> 规则 -> 度量 -> 分页 -> 页眉页脚。
pub fn render_chapter(b : Book, index : Int32) -> Result[ChapterPages, String] {
  let paths = chapters(b)
  if index < 0 || index >= paths.length() {
    return Err(
      "章节序号 " +
      index.to_string() +
      " 越界（共 " +
      paths.length().to_string() +
      " 章）",
    )
  }
  let path = paths[index]
  let warnings : Array[String] = []
  let text = match @container.read(b.epub.archive, path) {
    Err(e) => return Err("章节读取失败：" + e)
    Ok(t) => t
  }
  let raw_doc = match @xml.parse_document_lenient(text) {
    Err(e) => {
      warnings.push("章节 XML 解析失败，按片段宽松重试：" + e)
      match @xml.parse_fragment(text, @xml.lenient_options()) {
        Err(e2) => return Err("章节无法解析：" + e2)
        Ok(frag) => frag
      }
    }
    Ok(d) => d
  }
  let applied = @rules.apply_rules(raw_doc, b.rules)
  let policy = @config.to_page_policy(b.config)
  let req = @render.RenderRequest::{
    doc: applied.doc,
    viewport_width: @paginate.content_width(policy),
    line_height: @config.line_height_px(b.config),
    font_size_px: @config.pt_to_px(b.config.typography.font_size_pt),
    avg_char_width_ratio: 0.5,
  }
  let measured = match @render.measure(b.backend, req) {
    Err(e) => return Err("度量失败：" + e)
    Ok(m) => m
  }
  let blocks = @render.apply_break_marks(
    measured,
    applied.effects.breaks_before,
    applied.effects.breaks_after,
  )
  let marked = mark_chapter_start(blocks)
  let result = @paginate.paginate(marked, policy)
  if result.error.length() > 0 {
    return Err("分页失败：" + result.error)
  }
  let title = chapter_title_of(raw_doc)
  let footers = @paginate.page_footers(policy, result, title)
  let headers = @paginate.page_headers(policy, result, title)
  for u in @rules.unfired_rules(b.rules, applied.effects) {
    warnings.push("规则 '" + u + "' 在本章命中 0 次")
  }
  // 消费 annotate/redirect 的效果：这两个动作已真正改写 DOM，
  // 这里把命中结果暴露到 warnings，宿主与诊断脚本才能看到（曾是全仓零消费）。
  for ann in applied.effects.annotations {
    warnings.push("注记 " + ann.0 + " => " + ann.1)
  }
  for red in applied.effects.redirects {
    warnings.push("重定向 " + red.0 + ": " + red.1 + " => " + red.2)
  }
  if !@paginate.invariant_no_pagination_loss(marked, result) {
    warnings.push(
      "不变式 no_pagination_loss（分页高度守恒）未通过——这是缺陷，请附带本书与配置上报",
    )
  }
  if !@render.invariant_visible_text_preserved(applied.doc, measured) {
    warnings.push(
      "不变式 visible_text_preserved（正文可见字符不丢失）未通过——这是缺陷，请附带本书与配置上报",
    )
  }
  for id in @paginate.oversized_unbreakable_blocks(marked, policy) {
    warnings.push(
      "块 '" +
      id +
      "' 是不可拆块且高度超过整页内容区，已独占一页但仍会溢出；请缩短标题或调大页面",
    )
  }
  if !@paginate.invariant_monotonic(result) {
    warnings.push(
      "不变式 3（单调）未通过——这是缺陷，请附带本书与配置上报",
    )
  }
  Ok(ChapterPages::{
    chapter_index: index,
    chapter_path: path,
    title,
    doc: applied.doc,
    blocks: marked,
    paginated: result,
    headers,
    footers,
    effects: applied.effects,
    warnings,
  })
}

///|
fn chapter_title_of(doc : @xml.Element) -> String {
  match @xml.find_descendant(doc, "h1") {
    None => ""
    Some(h) => @util.trim(@xml.text_content(h))
  }
}

///|
/// 每章第一块标记为章节起始，让 `break_after_chapter_start` 生效。
fn mark_chapter_start(
  blocks : Array[@paginate.Block],
) -> Array[@paginate.Block] {
  let out : Array[@paginate.Block] = []
  let mut first = true
  for b in blocks {
    if first {
      out.push(@paginate.with_chapter_start(b))
      first = false
    } else {
      out.push(b)
    }
  }
  out
}

// ---------------- Reader：可变的阅读会话 ----------------

///| 阅读会话状态。全部字段不可变语义：每次翻页返回新值（便于宿主做

///|
/// 时间旅行调试与撤销，也让 不变式 4「幂等」在会话层同样成立）。
#derive(Debug, Eq)
pub(all) struct Reader {
  book : Book
  chapter : Int32
  page : Int32
}

///|
pub fn new_reader(b : Book) -> Reader {
  Reader::{ book: b, chapter: 0, page: 0, }
}

///|
pub fn reader_chapter_count(r : Reader) -> Int32 {
  chapter_count(r.book)
}

///|
/// 当前章的页数（会触发一次完整分页，宿主应缓存 `render_chapter` 结果）。
pub fn pages_in_chapter(r : Reader, index : Int32) -> Result[Int32, String] {
  match render_chapter(r.book, index) {
    Err(e) => return Err(e)
    Ok(cp) => Ok(@paginate.page_count(cp.paginated))
  }
}

///|
pub fn goto_chapter(r : Reader, index : Int32) -> Result[Reader, String] {
  let n = chapter_count(r.book)
  if n == 0 {
    return Err("本书没有可阅读的章节")
  }
  if index < 0 || index >= n {
    return Err(
      "章节序号 " +
      index.to_string() +
      " 越界（共 " +
      n.to_string() +
      " 章）",
    )
  }
  Ok(Reader::{ book: r.book, chapter: index, page: 0, })
}

///|
/// 前进/后退一页，跨章自动滚动。
pub fn step(r : Reader, delta : Int32) -> Result[Reader, String] {
  let n = chapter_count(r.book)
  if n == 0 {
    return Err("本书没有可阅读的章节")
  }
  let mut ch = r.chapter
  let mut pg = r.page + delta
  let mut attempt = 0
  while attempt < 4096 {
    attempt = attempt + 1
    if pg < 0 {
      if ch == 0 {
        return Err("已在书首")
      }
      ch = ch - 1
      match pages_in_chapter(r, ch) {
        Err(e) => return Err(e)
        Ok(total) => {
          if total == 0 {
            continue
          }
          pg = total - 1
        }
      }
    } else {
      match pages_in_chapter(r, ch) {
        Err(e) => return Err(e)
        Ok(total) => {
          if pg < total {
            return Ok(Reader::{ book: r.book, chapter: ch, page: pg, })
          }
          if ch + 1 >= n {
            return Err("已在书尾")
          }
          ch = ch + 1
          pg = 0
        }
      }
    }
  }
  Err("翻页循环保护被触发（超过 4096 次尝试）")
}

///|
pub fn next_page(r : Reader) -> Result[Reader, String] {
  step(r, 1)
}

///|
pub fn prev_page(r : Reader) -> Result[Reader, String] {
  step(r, -1)
}

///|
/// 当前页的可见内容标识（块 id 列表），供宿主决定画什么。
pub fn block_ids_on_page(
  cp : ChapterPages,
  page_index : Int32,
) -> Array[String] {
  let out : Array[String] = []
  if cp.paginated.error.length() > 0 {
    return out
  }
  if page_index < 0 || page_index >= cp.paginated.pages.length() {
    return out
  }
  for f in cp.paginated.pages[page_index].fragments {
    out.push(f.block_id)
  }
  out
}

///|
/// 当前页。越界时返回清晰错误而不是 panic。
pub fn current_page(
  r : Reader,
  cp : ChapterPages,
) -> Result[@paginate.Page, String] {
  let total = cp.paginated.pages.length()
  if total == 0 {
    return Err("本章没有产出任何页")
  }
  if r.page < 0 || r.page >= total {
    return Err(
      "页序号 " +
      r.page.to_string() +
      " 越界（本章共 " +
      total.to_string() +
      " 页）",
    )
  }
  Ok(cp.paginated.pages[r.page])
}

///|
/// 当前位置 -> 定位符 + 进度。
pub fn progress_of(
  r : Reader,
  cp : ChapterPages,
  updated : String,
) -> @paginator.Progress {
  @paginator.make_progress(
    book_key(r.book),
    r.chapter,
    r.page,
    cp.paginated.pages.length(),
    chapter_count(r.book),
    updated,
  )
}

///|
/// 书的稳定标识：EPUB 用第一个 dc:identifier，退化用 OPF 路径。
pub fn book_key(b : Book) -> String {
  let ids = b.epub.metadata.identifiers
  if ids.length() > 0 {
    ids[0].1
  } else {
    b.epub.opf_path
  }
}

///|
/// 恢复进度。内容变化时按 `paginator.restore` 的规则夹取。
pub fn restore_reader(
  r : Reader,
  p : @paginator.Progress,
) -> @paginator.Restore {
  @paginator.restore(p, chapter_count(r.book), fn(index : Int32) -> Int32 {
    match render_chapter(r.book, index) {
      Ok(cp) => @paginate.page_count(cp.paginated)
      Err(_) => 0
    }
  })
}

///|
/// 内核版本与能力矩阵，供宿主在启动时做一次能力协商。
pub fn kernel_info() -> String {
  @util.join_nl([
    "moonread-core 0.1.0", "后端：Backend::Null（确定性度量）/ Backend::Crater（需外部依赖）",
    "容器：EPUB2 spine+NCX / EPUB3 全量 / CBZ", "不处理：DRM 解密、PDF、音视频",
  ])
}
