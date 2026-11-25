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
/// - `Null`：**确定性测试替身**，不是生产排版后端。零依赖、完全确定，它让
///   分页算法、验收项与全部内核测试在没有 crater 的情况下就能跑通。度量模型
///   是「按显示宽度折行」的近似（汉字记 2、其它记 1，见 `display_width`），
///   图片/表格/figure 高度用经验常量。**不要用它计算真实书的精确页数**——
///   生产排版应走 `Crater`；Null 的价值是让语义与不变量可测、可复现。
/// - `Crater`：真实后端，**尚未接入**。`src/zipio` 只提供 ZIP 解压适配
///   （`hustcer/fzip`），与排版渲染无关；crater 适配代码目前不存在。
///   接入清单见 `docs/RENDER-BACKEND.md`。未接入时 `measure` 返回清晰错误
///   而不是 panic。

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
        "Crater 后端尚未接入：需要 html5-mbt + css + crater-renderer（清单见 docs/RENDER-BACKEND.md）。src/zipio 只有 ZIP 解压，与排版无关。在此之前请使用 Backend::Null。",
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
  collect_leaf_blocks(body, body_path, out, chars_per_line, req.line_height, 0)
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
  list_depth : Int32,
) -> Unit {
  let has_block_child = contains_block_child(el)
  if is_block_tag(el.tag) && !has_block_child {
    out.push(measure_one(el, my_path, chars_per_line, line_height))
    return
  }
  let mut idx = 0
  let mut text_idx = 0
  let mut pending = ""
  for c in el.children {
    match c {
      @xml.EText(t) =>
        // 块容器里「块子节点之前/之后」的裸文本同样可见（HTML5 混合内容）。
        // 旧实现要求 !is_block_tag(el.tag)，会让 div 中的裸文本彻底没有度量块。
        if @util.trim(t).length() > 0 {
          pending = pending + t
        }
      @xml.EElement(child) => {
        flush_text(pending, my_path, text_idx, out, chars_per_line, line_height)
        if @util.trim(pending).length() > 0 {
          text_idx = text_idx + 1
        }
        pending = ""
        let cp = @xml.child_path(my_path, child.tag, idx)
        idx = idx + 1
        if is_list_tag(child.tag) {
          collect_list(child, cp, out, chars_per_line, line_height, list_depth)
        } else {
          collect_leaf_blocks(
            child, cp, out, chars_per_line, line_height, list_depth,
          )
        }
      }
    }
  }
  flush_text(pending, my_path, text_idx, out, chars_per_line, line_height)
}

///|
fn flush_text(
  raw : String,
  parent_path : String,
  text_idx : Int32,
  out : Array[MeasuredBlock],
  chars_per_line : Int32,
  line_height : Double,
) -> Unit {
  let trimmed = @util.trim(raw)
  if trimmed.length() > 0 {
    let path = @xml.child_path(parent_path, "#text", text_idx)
    out.push(MeasuredBlock::{
      path,
      block: @paginate.with_text(
        text_block_of(path, trimmed, chars_per_line, line_height),
        trimmed,
      ),
    })
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
fn is_list_tag(tag : String) -> Bool {
  let t = @util.ascii_lower(@xml.local_name(tag))
  t == "ol" || t == "ul"
}

///|
/// 列表项自身文字，不含嵌套列表（嵌套项会各自成块）。
fn list_item_text(li : @xml.Element) -> String {
  let mut raw = ""
  for c in li.children {
    match c {
      @xml.EText(t) => raw = raw + t
      @xml.EElement(child) =>
        if !is_list_tag(child.tag) {
          raw = raw + text_of(child)
        }
    }
  }
  normalize_ws(raw, false)
}

///|
/// `ol` / `ul` 产出带层级与序号的 BKList 块，不再压平成普通文本块。
fn collect_list(
  el : @xml.Element,
  my_path : String,
  out : Array[MeasuredBlock],
  chars_per_line : Int32,
  line_height : Double,
  depth : Int32,
) -> Unit {
  let ordered = @util.ascii_lower(@xml.local_name(el.tag)) == "ol"
  let mut idx = 0
  let mut item = 1
  for c in el.children {
    match c {
      @xml.EElement(li) =>
        if @util.ascii_lower(@xml.local_name(li.tag)) == "li" {
          let cp = @xml.child_path(my_path, li.tag, idx)
          idx = idx + 1
          let text = list_item_text(li)
          let lines = lines_of(text, chars_per_line)
          let block = @paginate.with_text(
            @paginate.list_block(
              cp, text, lines, line_height, ordered, depth, item,
            ),
            text,
          )
          out.push(MeasuredBlock::{ path: cp, block, })
          collect_nested_lists(
            li,
            cp,
            out,
            chars_per_line,
            line_height,
            depth + 1,
          )
          item = item + 1
        } else {
          let cp = @xml.child_path(my_path, li.tag, idx)
          idx = idx + 1
          collect_leaf_blocks(
            li,
            cp,
            out,
            chars_per_line,
            line_height,
            depth + 1,
          )
        }
      @xml.EText(_) => ()
    }
  }
}

///|
fn collect_nested_lists(
  li : @xml.Element,
  my_path : String,
  out : Array[MeasuredBlock],
  chars_per_line : Int32,
  line_height : Double,
  depth : Int32,
) -> Unit {
  let mut idx = 0
  for c in li.children {
    match c {
      @xml.EElement(child) => {
        let cp = @xml.child_path(my_path, child.tag, idx)
        idx = idx + 1
        if is_list_tag(child.tag) {
          collect_list(child, cp, out, chars_per_line, line_height, depth)
        }
      }
      @xml.EText(_) => ()
    }
  }
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
      block: @paginate.with_text(
        @paginate.heading_block(path, line_height * scale * lines.to_double()),
        text,
      ),
    }
  } else if tag == "table" {
    // 表格由渲染后端整体绘制，但单元格文字必须进入块模型，
    // 否则内容层不变式无法发现表格文字丢失。
    let rows = @xml.find_all_child(el, "tr")
    let n = if rows.length() > 0 { rows.length() } else { 1 }
    let text = collapsed_text(el)
    MeasuredBlock::{
      path,
      block: @paginate.with_text(
        @paginate.atomic_block(
          path,
          @paginate.BKTable,
          line_height * n.to_double(),
        ),
        text,
      ),
    }
  } else if tag == "figure" {
    MeasuredBlock::{
      path,
      block: @paginate.with_text(
        @paginate.atomic_block(path, @paginate.BKFigure, line_height * 6.0),
        collapsed_text(el),
      ),
    }
  } else if tag == "pre" {
    let text = preserved_text(el)
    MeasuredBlock::{
      path,
      block: @paginate.with_text(
        text_block_of(path, text, chars_per_line, line_height),
        text,
      ),
    }
  } else {
    let text = collapsed_text(el)
    MeasuredBlock::{
      path,
      block: @paginate.with_text(
        text_block_of(path, text, chars_per_line, line_height),
        text,
      ),
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
/// 递归提取可见文本：`<br>` 贡献换行，`<pre>` 子树保留原始空白。
fn text_of(el : @xml.Element) -> String {
  let mut out = ""
  for c in el.children {
    match c {
      @xml.EText(t) => out = out + t
      @xml.EElement(child) => {
        let tag = @util.ascii_lower(@xml.local_name(child.tag))
        if tag == "br" {
          out = out + "\n"
        } else if tag == "pre" {
          out = out + raw_text(child)
        } else {
          out = out + text_of(child)
        }
      }
    }
  }
  out
}

///|
/// 完全不折叠的递归文本（`<pre>` 用）。
fn raw_text(el : @xml.Element) -> String {
  let mut out = ""
  for c in el.children {
    match c {
      @xml.EText(t) => out = out + t
      @xml.EElement(child) =>
        if @util.ascii_lower(@xml.local_name(child.tag)) == "br" {
          out = out + "\n"
        } else {
          out = out + raw_text(child)
        }
    }
  }
  out
}

///|
/// HTML 空白折叠：连续空白折叠为一个空格，首尾空白丢弃；`<br>` 保留换行。
pub fn collapsed_text(el : @xml.Element) -> String {
  normalize_ws(text_of(el), false)
}

///|
/// `<pre>` 的空白保留路径。
pub fn preserved_text(el : @xml.Element) -> String {
  normalize_ws(raw_text(el), true)
}

///|
fn normalize_ws(raw : String, preserve : Bool) -> String {
  let cs = @util.to_chars(raw)
  let out : Array[Char] = []
  let mut pending_space = false
  let mut started = false
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if c == '\n' {
      out.push('\n')
      pending_space = false
      started = true
    } else if !preserve && @util.is_xml_space(c) {
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
/// 字符的**显示宽度**，单位是「半个汉字宽的 ASCII 字符」：
/// ASCII 与拉丁记 1，CJK / 全角记 2。`avg_char_width_ratio=0.5` 时，
/// `chars_per_line` 表示一行能放多少个 ASCII 单位，因此汉字必须记 2，
/// 否则一段 3000 字的中文会被算成一半的行数、页数低估约 2 倍。
///
/// 这是 Backend::Null 的确定性近似（不是真实字体度量）；覆盖常见 CJK 区间，
/// 组合音标与 emoji 按 1 处理，保持四端完全一致。
pub fn display_width(c : Char) -> Int32 {
  let cp = @util.char_to_int(c)
  // 韩文字母 / CJK 部首符号注音 / 韩文音节 / CJK 兼容表意 /
  // 竖排标点 / CJK 兼容形式 / 全角 ASCII / 全角符号 / emoji / CJK 扩展 B..F
  let wide = (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0xa4cf && cp != 0x303f) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe10 && cp <= 0xfe19) ||
    (cp >= 0xfe30 && cp <= 0xfe6f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1f64f) ||
    (cp >= 0x20000 && cp <= 0x3fffd)
  if wide {
    2
  } else {
    1
  }
}

///|
/// 行数：至少 1 行（空文本也占一行，与 CSS 对空段落的行为一致）。
/// 按显示宽度折行（汉字记 2），而不是按码位个数——见 `display_width`。
pub fn lines_of(text : String, chars_per_line : Int32) -> Int32 {
  if chars_per_line <= 0 {
    return 1
  }
  let cs = @util.to_chars(text)
  if cs.length() == 0 {
    1
  } else {
    let mut lines = 1
    let mut used = 0
    for c in cs {
      if c == '\n' {
        // `<br>` 与 `<pre>` 的显式换行：结束当前行，另起一行。
        lines = lines + 1
        used = 0
      } else {
        let w = display_width(c)
        if used + w > chars_per_line {
          lines = lines + 1
          used = 0
        }
        used = used + w
      }
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

///|
fn char_count(s : String, c : Char) -> Int32 {
  let mut n = 0
  for x in s {
    if x == c {
      n = n + 1
    }
  }
  n
}

///|
/// 内容层不变式：源文档可见字符必须都能在度量块的 text 中找到同数量副本。
/// 这补足了旧 `invariant_no_content_loss` 只校验分页高度、看不见
/// DOM→度量块阶段文本丢失的盲区。
pub fn invariant_visible_text_preserved(
  doc : @xml.Element,
  blocks : Array[MeasuredBlock],
) -> Bool {
  let source = normalize_ws(text_of(find_body(doc)), false)
  let mut measured = ""
  for b in blocks {
    measured = measured + b.block.text
  }
  for c in source {
    if !@util.is_xml_space(c) && c != '\n' {
      if char_count(measured, c) < char_count(source, c) {
        return false
      }
    }
  }
  true
}
