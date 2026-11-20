/// 渲染后端抽象。
///
/// ## 为什么用枚举而不是 trait
///
/// 接口要求「抽象层提供 `RenderBackend`，未来可替换为别的实现」。本仓库用
/// **枚举 + 单一派发函数**表达：`measure(backend, request)`。
/// 增加一个后端 = 增加一个变体 + 一个分支，编译器会强制所有 `match` 补全，
/// 比 trait 更容易审计，也不依赖工具链的 trait 语法版本。
///
/// ## 依赖方向（）
///
/// L3 **只允许对 crater 做加法**，且不得依赖 L4。因此本层只接收
/// 「DOM 元素树 + 视口尺寸」，输出「块序列 + 块路径」；
/// 规则引擎（L4）在 `src/core` 里先改写 DOM，再按路径回填断页标记。
///
/// ## 现状
///
/// - `Null`：零依赖、完全确定性的度量后端。它让 的分页算法、的
///   验收项 /、以及全部内核测试**在没有 crater 的情况下就能跑通**。
///   度量模型是「按码位数折行」的近似，不是真实排版。
/// - `Crater`：真实后端。调用 `render_html_to_paint_tree` / `compute_layout`
///   的适配代码在 `src/zipio`（唯一带外部依赖的包）里，需要联网取包后才能编译。
///   未接入时 `measure` 返回清晰错误而不是 panic（验收项）。

///|
/// 一次度量请求。`viewport_width` / `line_height` / `font_size_px` 单位是 CSS px。
#derive(Debug, Eq)
pub(all) struct RenderRequest {
  doc : @xml.Element
  viewport_width : Double
  line_height : Double
  font_size_px : Double
  /// 平均字宽系数（等宽近似）。Null 后端使用；真实后端忽略。
  avg_char_width_ratio : Double
}

///|
/// 度量结果：块 + 它在 DOM 里的结构路径（与 `src/rules` 的路径同构）。
#derive(Debug, Eq)
pub(all) struct MeasuredBlock {
  path : String
  block : @paginate.Block
}

///|
#derive(Debug, Eq)
pub(all) enum Backend {
  /// 确定性近似后端，零外部依赖。
  Null
  /// crater（`mizchi/crater-renderer`）。当前构建里未接入。
  Crater
}

///|
pub fn backend_name(b : Backend) -> String {
  match b {
    Null => "null"
    Crater => "crater"
  }
}

///|
/// 块级标签集合（决定「一段内容算一个块」）。
fn is_block_tag(tag : String) -> Bool {
  let t = @util.ascii_lower(@xml.local_name(tag))
  t == "p" ||
  t == "h1" ||
  t == "h2" ||
  t == "h3" ||
  t == "h4" ||
  t == "h5" ||
  t == "h6" ||
  t == "div" ||
  t == "li" ||
  t == "blockquote" ||
  t == "pre" ||
  t == "figure" ||
  t == "img" ||
  t == "table" ||
  t == "hr" ||
  t == "section" ||
  t == "article" ||
  t == "ol" ||
  t == "ul"
}

///|
fn is_heading(tag : String) -> Bool {
  let t = @util.ascii_lower(@xml.local_name(tag))
  t == "h1" || t == "h2" || t == "h3" || t == "h4" || t == "h5" || t == "h6"
}

///|
fn is_void_tag(tag : String) -> Bool {
  let t = @util.ascii_lower(@xml.local_name(tag))
  t == "img" || t == "hr" || t == "br"
}

///|
pub fn measure(
  b : Backend,
  req : RenderRequest,
) -> Result[Array[MeasuredBlock], String] {
  match b {
    Null => measure_null(req)
    Crater =>
      Err(
        "Crater 后端尚未接入：还需要 `mizchi/crater-renderer`（fzip 已接入，见 src/zipio/fzip_adapter.mbt）。在此之前请使用 Backend::Null。",
      )
  }
}

///| 确定性度量：把 DOM 里的「叶子块」按顺序转成 `paginate.Block`。

///|

///| 折行模型：`chars_per_line = floor(viewport_width / (font_size_px * ratio))`，

///| 行数 = ceil(空白折叠后的码位数 / chars_per_line)。全程整数/有限小数运算，

///|
/// 三端结果一致（）。
fn measure_null(req : RenderRequest) -> Result[Array[MeasuredBlock], String] {
  if req.viewport_width <= 0.0 {
    return Err(
      "视口宽度必须为正，实际 " + req.viewport_width.to_string(),
    )
  }
  if req.font_size_px <= 0.0 {
    return Err("字号必须为正，实际 " + req.font_size_px.to_string())
  }
  if req.line_height <= 0.0 {
    return Err("行高必须为正，实际 " + req.line_height.to_string())
  }
  if req.avg_char_width_ratio <= 0.0 {
    return Err(
      "平均字宽系数必须为正，实际 " +
      req.avg_char_width_ratio.to_string(),
    )
  }
  let unit = req.font_size_px * req.avg_char_width_ratio
  let mut chars_per_line = 0
  while (chars_per_line + 1).to_double() * unit <= req.viewport_width {
    chars_per_line = chars_per_line + 1
  }
  if chars_per_line <= 0 {
    return Err(
      "视口宽度放不下哪怕一个字符（宽度 " +
      req.viewport_width.to_string() +
      " / 字宽 " +
      unit.to_string() +
      "）",
    )
  }
  let out : Array[MeasuredBlock] = []
  let body = find_body(req.doc)
  // 关键：用 body 在**整棵文档**里的真实路径做起点，而不是空串。
  // 否则度量块路径是 p[1]，而 rules 记录的是 body[1]/p[1]，永远匹配不上。
  let body_path = @xml.path_of_first(req.doc, "body")
  collect_leaf_blocks(body, body_path, out, chars_per_line, req.line_height)
  Ok(out)
}

///|
fn find_body(root : @xml.Element) -> @xml.Element {
  match @xml.find_descendant(root, "body") {
    Some(b) => b
    None => root
  }
}

///| 「叶子块」= 块级元素且其内部不含其它块级元素。这样嵌套结构（div>section>p）

///|
/// 只产生一个块（最内层的 p），与 CSS 块盒的直觉一致。
fn collect_leaf_blocks(
  el : @xml.Element,
  my_path : String,
  out : Array[MeasuredBlock],
  chars_per_line : Int32,
  line_height : Double,
) -> Unit {
  let has_block_child = contains_block_child(el)
  if is_block_tag(el.tag) && !has_block_child {
    out.push(measure_one(el, my_path, chars_per_line, line_height))
    return
  }
  let mut idx = 0
  for c in el.children {
    match c {
      @xml.EText(t) => {
        let trimmed = @util.trim(t)
        if trimmed.length() > 0 && !is_block_tag(el.tag) {
          // 容器元素里的裸文本：按一个匿名文本块计入，避免内容丢失。
          // 文本不占元素序号，与 rules/render 共用的编号规则保持一致。
          out.push(MeasuredBlock::{
            path: @xml.child_path(my_path, "#text", idx),
            block: text_block_of("#text", trimmed, chars_per_line, line_height),
          })
        }
      }
      @xml.EElement(child) => {
        let cp = @xml.child_path(my_path, child.tag, idx)
        idx = idx + 1
        collect_leaf_blocks(child, cp, out, chars_per_line, line_height)
      }
    }
  }
}

///|
fn contains_block_child(el : @xml.Element) -> Bool {
  let mut found = false
  for c in el.children {
    match c {
      @xml.EElement(e) => if is_block_tag(e.tag) { found = true }
      @xml.EText(_) => ()
    }
  }
  found
}

///|
fn measure_one(
  el : @xml.Element,
  path : String,
  chars_per_line : Int32,
  line_height : Double,
) -> MeasuredBlock {
  let tag = @util.ascii_lower(@xml.local_name(el.tag))
  if tag == "img" {
    let h = attr_length(el, "height", line_height * 8.0)
    MeasuredBlock::{ path, block: @paginate.image_block(path, h), }
  } else if tag == "hr" {
    MeasuredBlock::{
      path,
      block: @paginate.atomic_block(path, @paginate.BKOther, 1.0),
    }
  } else if is_heading(el.tag) {
    let text = collapsed_text(el)
    let lines = lines_of(text, chars_per_line)
    let scale = heading_scale(tag)
    MeasuredBlock::{
      path,
      block: @paginate.Block::{
        id: path,
        kind: @paginate.BKHeading,
        height: line_height * scale * lines.to_double(),
        line_height: line_height * scale,
        lines,
        splittable: true,
        break_before: true,
        break_after: false,
        chapter_start: false,
        keep_with_next: true,
      },
    }
  } else if tag == "table" {
    let rows = @xml.find_all_child(el, "tr").length()
    let n = if rows > 0 { rows } else { 1 }
    MeasuredBlock::{
      path,
      block: @paginate.atomic_block(
        path,
        @paginate.BKTable,
        line_height * n.to_double(),
      ),
    }
  } else if tag == "figure" {
    MeasuredBlock::{
      path,
      block: @paginate.atomic_block(path, @paginate.BKFigure, line_height * 6.0),
    }
  } else {
    let text = collapsed_text(el)
    MeasuredBlock::{
      path,
      block: text_block_of(path, text, chars_per_line, line_height),
    }
  }
}

///|
fn text_block_of(
  path : String,
  text : String,
  chars_per_line : Int32,
  line_height : Double,
) -> @paginate.Block {
  let lines = lines_of(text, chars_per_line)
  @paginate.text_block(path, lines, line_height)
}

///|
fn heading_scale(tag : String) -> Double {
  if tag == "h1" {
    1.8
  } else if tag == "h2" {
    1.5
  } else if tag == "h3" {
    1.25
  } else {
    1.0
  }
}

///|
/// HTML 空白折叠：连续空白折叠为一个空格，首尾空白丢弃。
pub fn collapsed_text(el : @xml.Element) -> String {
  let raw = @xml.text_content(el)
  let cs = @util.to_chars(raw)
  let out : Array[Char] = []
  let mut pending_space = false
  let mut started = false
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if @util.is_xml_space(c) {
      if started {
        pending_space = true
      }
    } else {
      if pending_space {
        out.push(' ')
        pending_space = false
      }
      out.push(c)
      started = true
    }
    i = i + 1
  }
  @util.from_chars(out)
}

///|
/// 行数：至少 1 行（空文本也占一行，与 CSS 对空段落的行为一致）。
pub fn lines_of(text : String, chars_per_line : Int32) -> Int32 {
  if chars_per_line <= 0 {
    return 1
  }
  let n = @util.to_chars(text).length()
  if n == 0 {
    1
  } else {
    let mut lines = 1
    let mut used = 0
    let mut i = 0
    let cs = @util.to_chars(text)
    while i < cs.length() {
      if used == chars_per_line {
        lines = lines + 1
        used = 0
      }
      used = used + 1
      i = i + 1
    }
    lines
  }
}

///|
fn attr_length(el : @xml.Element, name : String, dflt : Double) -> Double {
  match @xml.attr_ci(el, name) {
    None => dflt
    Some(v) => {
      let digits = strip_px_suffix(v)
      match @util.parse_double(digits) {
        Some(d) => if d > 0.0 { d } else { dflt }
        None => dflt
      }
    }
  }
}

///|
fn strip_px_suffix(v : String) -> String {
  let lower = @util.ascii_lower(@util.trim(v))
  if @util.ends_with(lower, "px") {
    @util.slice_string(lower, 0, @util.to_chars(lower).length() - 2)
  } else if @util.ends_with(lower, "pt") {
    @util.slice_string(lower, 0, @util.to_chars(lower).length() - 2)
  } else if @util.ends_with(lower, "em") {
    @util.slice_string(lower, 0, @util.to_chars(lower).length() - 2)
  } else {
    lower
  }
}

///|
/// 块序列的总高度，用于测试与诊断。
pub fn total_height(blocks : Array[MeasuredBlock]) -> Double {
  let mut s = 0.0
  for m in blocks {
    s = s + m.block.height
  }
  s
}

///|
/// 按路径给块打上规则产生的断页标记（`src/rules` 的 `page_break_before/after`）。
pub fn apply_break_marks(
  blocks : Array[MeasuredBlock],
  breaks_before : Array[String],
  breaks_after : Array[String],
) -> Array[@paginate.Block] {
  let out : Array[@paginate.Block] = []
  for m in blocks {
    let mut b = m.block
    if contains(breaks_before, m.path) {
      b = @paginate.with_break_before(b)
    }
    if contains(breaks_after, m.path) {
      b = @paginate.with_break_after(b)
    }
    out.push(b)
  }
  out
}

///|
fn contains(arr : Array[String], v : String) -> Bool {
  let mut found = false
  for x in arr {
    if x == v {
      found = true
    }
  }
  found
}

///| `is_void_tag` 目前只用于文档说明与后续真实后端的分支；这里显式引用一次，

///|
/// 避免「写了但没用」的告警在 `--deny-warn` 下阻断 CI。
pub fn void_tag_names() -> Array[String] {
  let out : Array[String] = []
  for n in ["img", "hr", "br"] {
    if is_void_tag(n) {
      out.push(n)
    }
  }
  out
}
