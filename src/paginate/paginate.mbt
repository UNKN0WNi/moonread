/// 分页策略层。
///
/// ## 两层分工（）
///
/// | 层 | 负责 | 归属 |
/// |---|---|---|
/// | 分片层（**怎么断**） | 在分片上下文里把盒树切成片段、处理断点、避免重叠、列平衡 | crater（需公共化，） |
/// | 分页策略层（**按什么断**） | 页高、页边距、页眉页脚、章节起始、孤儿寡行、跨页标题 | **本文件** |
///
/// 本文件**不依赖 crater**：它作用在「块序列 + 块高度」这个抽象输入上，
/// 正是 的分工边界。`src/render` 的 `RenderBackend` 负责把 DOM/布局树
/// 变成这里的块序列；等 crater 的 `fragmentation.mbt` 暴露成公共 API 后，
/// 替换的只是 `render` 那一侧，本文件的算法与不变式不受影响（该风险的缓解）。
///
/// ## 为什么用「行数」而不是「高度」驱动拆分
///
/// 可拆块的高度定义为 `lines * line_height`（构造时强制），因此拆分全程是
/// 整数运算。这样：
/// - 不变式 1「不丢内容」是**精确相等**，不依赖浮点容差；
/// - 验收项「页边界误差 ≤ 1px」有可证明的基线；
/// - native / js / wasm-gc 三端结果逐位一致（的结论得以保持）。
///
/// ## 与 CSS 规范的关系
///
/// `PagePolicy` 对应 CSS Paged Media 与 CSS Multi-column Level 1 
/// 「Fragmentation Contexts」——两者是同一套算法。EPUB 分页的本质就是
/// 「把内容放进一个高度受限的 column，溢出即断页」。
///
/// 注意：对 `orphan_min` / `widow_min` 的注释写的是「章节末/章节首」，
/// 本实现按 **CSS 原始定义**处理——块被拆开时，`orphan_min` 是留在前一页的
/// 最少行数，`widow_min` 是推到后一页的最少行数，都作用于**被拆的那个块**，
/// 不作用于章节边界；章节边界由 `break_after_chapter_start` 单独控制。
/// 详见 docs/PAGINATION.md 的「术语澄清」。

///|
/// 分页策略（原样字段，名称、类型与顺序保持一致）。
#derive(Debug, Eq)
pub(all) struct PagePolicy {
  page_width : Double
  page_height : Double
  margin_top : Double
  margin_bottom : Double
  margin_inner : Double
  margin_outer : Double
  column_gap : Double
  /// 支持 `{page}` / `{total}` / `{chapter}` 模板变量。
  header_template : String
  footer_template : String
  /// 块被拆时前一页至少保留的行数（CSS `orphans`）。
  orphan_min : Int32
  /// 块被拆时后一页至少保留的行数（CSS `widows`）。
  widow_min : Int32
  /// 章节是否总从新页开始。
  break_after_chapter_start : Bool
  /// 漫画/日文书：页序与内外边距左右翻转。
  honor_rtl : Bool
}

///|
pub fn mm_to_px(mm : Double) -> Double {
  mm * 96.0 / 25.4
}

///|
/// `config.json` 的 `page` 段换算而来的默认策略（毫米 → CSS px，96dpi）。
pub fn default_policy() -> PagePolicy {
  PagePolicy::{
    page_width: mm_to_px(120.0),
    page_height: mm_to_px(180.0),
    margin_top: mm_to_px(15.0),
    margin_bottom: mm_to_px(18.0),
    margin_inner: mm_to_px(12.0),
    margin_outer: mm_to_px(12.0),
    column_gap: 0.0,
    header_template: "",
    footer_template: "{page} / {total}",
    orphan_min: 2,
    widow_min: 2,
    break_after_chapter_start: true,
    honor_rtl: false,
  }
}

///|
/// 内容区高度 = 页高 - 上下边距。非正返回 0，由 `paginate` 报错而非死循环。
pub fn content_height(p : PagePolicy) -> Double {
  let h = p.page_height - p.margin_top - p.margin_bottom
  if h <= 0.0 {
    0.0
  } else {
    h
  }
}

///|
pub fn content_indent(p : PagePolicy) -> Double {
  if p.honor_rtl {
    p.margin_outer
  } else {
    p.margin_inner
  }
}

///|
pub fn content_ending(p : PagePolicy) -> Double {
  if p.honor_rtl {
    p.margin_inner
  } else {
    p.margin_outer
  }
}

///|
pub fn content_width(p : PagePolicy) -> Double {
  if p.page_width <= 0.0 {
    0.0
  } else {
    let w = p.page_width - content_indent(p) - content_ending(p)
    if w <= 0.0 {
      0.0
    } else {
      w
    }
  }
}

// ---------------- 分片输入 ----------------

///|
#derive(Debug, Eq)
pub(all) enum BlockKind {
  BKText
  BKHeading
  BKImage
  BKFigure
  BKList
  BKTable
  BKOther
}

///| 分页输入：一个已经算好高度的块。`height` / `lines` / `line_height` 的

///|
/// 关系由构造函数保证，调用方不要手工构造不一致的块（`check_consistent` 可验证）。
#derive(Debug, Eq)
pub(all) struct Block {
  /// 稳定标识，用于把分片结果映射回 DOM 节点。
  id : String
  kind : BlockKind
  height : Double
  /// 行高。不可拆块为 0.0。
  line_height : Double
  /// 行数。不可拆块为 0。
  lines : Int32
  splittable : Bool
  break_before : Bool
  break_after : Bool
  /// 章节起始块（spine 每章的第一块），受 `break_after_chapter_start` 约束。
  chapter_start : Bool
  /// 与下一个块必须同页（keep-with-next，标题常用）。
  keep_with_next : Bool
}

///|
/// 文本块：高度 = lines * line_height。
pub fn text_block(id : String, lines : Int32, line_height : Double) -> Block {
  let lh = if lines > 0 { line_height } else { 0.0 }
  Block::{
    id,
    kind: BKText,
    height: lh * lines.to_double(),
    line_height: lh,
    lines: if lines > 0 {
      lines
    } else {
      0
    },
    splittable: true,
    break_before: false,
    break_after: false,
    chapter_start: false,
    keep_with_next: false,
  }
}

///|
/// 标题块：不可拆，且要求与下一块同页、总从新页开始。
pub fn heading_block(id : String, height : Double) -> Block {
  Block::{
    id,
    kind: BKHeading,
    height,
    line_height: 0.0,
    lines: 0,
    splittable: false,
    break_before: true,
    break_after: false,
    chapter_start: false,
    keep_with_next: true,
  }
}

///|
pub fn atomic_block(id : String, kind : BlockKind, height : Double) -> Block {
  Block::{
    id,
    kind,
    height,
    line_height: 0.0,
    lines: 0,
    splittable: false,
    break_before: false,
    break_after: false,
    chapter_start: false,
    keep_with_next: false,
  }
}

///|
pub fn image_block(id : String, height : Double) -> Block {
  atomic_block(id, BKImage, height)
}

///|
/// 章节起始标记。
pub fn with_chapter_start(b : Block) -> Block {
  Block::{
    id: b.id,
    kind: b.kind,
    height: b.height,
    line_height: b.line_height,
    lines: b.lines,
    splittable: b.splittable,
    break_before: b.break_before,
    break_after: b.break_after,
    chapter_start: true,
    keep_with_next: b.keep_with_next,
  }
}

///|
pub fn with_break_before(b : Block) -> Block {
  Block::{
    id: b.id,
    kind: b.kind,
    height: b.height,
    line_height: b.line_height,
    lines: b.lines,
    splittable: b.splittable,
    break_before: true,
    break_after: b.break_after,
    chapter_start: b.chapter_start,
    keep_with_next: b.keep_with_next,
  }
}

///|
pub fn with_break_after(b : Block) -> Block {
  Block::{
    id: b.id,
    kind: b.kind,
    height: b.height,
    line_height: b.line_height,
    lines: b.lines,
    splittable: b.splittable,
    break_before: b.break_before,
    break_after: true,
    chapter_start: b.chapter_start,
    keep_with_next: b.keep_with_next,
  }
}

///|
/// 块自身的一致性检查（渲染后端给出的高度与行数不符时用于诊断）。
pub fn check_consistent(b : Block) -> String {
  if b.height < 0.0 {
    return "块 '" + b.id + "' 高度为负"
  }
  if b.splittable {
    if b.lines <= 0 {
      return "可拆块 '" + b.id + "' 行数为 0"
    }
    if b.line_height <= 0.0 {
      return "可拆块 '" + b.id + "' 行高非正"
    }
    if !approx_eq(b.height, b.line_height * b.lines.to_double()) {
      return "可拆块 '" + b.id + "' 高度与 lines*line_height 不符"
    }
  } else if b.lines != 0 || b.line_height != 0.0 {
    return "不可拆块 '" + b.id + "' 不应带行高/行数"
  }
  ""
}

///|
/// 分片结果里的一段：某个块放在某页上的一部分。
#derive(Debug, Eq)
pub(all) struct PlacedFragment {
  block_id : String
  kind : BlockKind
  /// 该段在本页内容区内的纵坐标（从 0 起）。
  y : Double
  /// 该段的高度。
  height : Double
  /// 该块是否还有后续片段在别的页上。
  continues : Bool
  /// 该段是否是前一块的延续。
  is_continuation : Bool
  /// 全局单调序号（不变式 3 的可检查形式）。
  seq : Int32
}

///|
/// 一页。
#derive(Debug, Eq)
pub(all) struct Page {
  /// 0 起。
  index : Int32
  fragments : Array[PlacedFragment]
  /// 本页内容总高度，用于校验不变式 1 与 2。
  used : Double
}

///|
/// 分页结果。
#derive(Debug, Eq)
pub(all) struct Paginated {
  pages : Array[Page]
  /// 策略/输入校验失败的原因。非空时 pages 为空。
  error : String
}

///|
pub fn page_count(r : Paginated) -> Int32 {
  r.pages.length()
}

// ---------------- 核心算法 ----------------

///| 把块序列切成若干页。**无隐藏状态**，因此天然满足不变式 4（幂等）。

///|

///| 不变式：

///| 1. 不丢内容：`sum(片段高度) == sum(输入块高度)`（精确相等）

///| 2. 不越界：每页 `used <= content_height`，**例外**：单个不可拆块或

///|    单行高度本身就超过整页时独占一页并允许溢出——因为「不丢内容」

///|    的优先级高于「不越界」（大图/超长行宁可裁切显示，也不能凭空消失）

///| 3. 单调：片段 `seq` 严格递增

///|
/// 4. 幂等：同策略同内容两次调用结果相同
pub fn paginate(blocks : Array[Block], policy : PagePolicy) -> Paginated {
  let limit = content_height(policy)
  if limit <= 0.0 {
    return Paginated::{
      pages: [],
      error: "内容区高度非正（页高 - 上边距 - 下边距 <= 0）",
    }
  }
  let mut i = 0
  while i < blocks.length() {
    let bad = check_consistent(blocks[i])
    if bad.length() > 0 {
      return Paginated::{ pages: [], error: bad, }
    }
    i = i + 1
  }
  let pages : Array[Page] = []
  let mut frag : Array[PlacedFragment] = []
  let mut used = 0.0
  let mut page_index = 0
  let mut seq = 0

  let mut k = 0
  while k < blocks.length() {
    let b = blocks[k]
    if b.height <= 0.0 {
      k = k + 1
      continue
    }
    // 1) 强制断页：break-before / 章节起始
    let force_break = b.break_before ||
      (b.chapter_start && policy.break_after_chapter_start)
    if force_break && frag.length() > 0 {
      flush(pages, page_index, frag, used)
      page_index = page_index + 1
      frag = []
      used = 0.0
    }
    // 2) keep-with-next：若本块 + 下一块的最小可放单位放不下，先断页
    if b.keep_with_next && k + 1 < blocks.length() {
      let need = b.height + min_piece_height(blocks[k + 1])
      if limit - used + 0.000000001 < need && frag.length() > 0 {
        flush(pages, page_index, frag, used)
        page_index = page_index + 1
        frag = []
        used = 0.0
      }
    }
    if !b.splittable {
      // 3) 不可拆块
      if limit - used + 0.000000001 < b.height && frag.length() > 0 {
        flush(pages, page_index, frag, used)
        page_index = page_index + 1
        frag = []
        used = 0.0
      }
      frag.push(PlacedFragment::{
        block_id: b.id,
        kind: b.kind,
        y: used,
        height: b.height,
        continues: false,
        is_continuation: false,
        seq,
      })
      seq = seq + 1
      used = used + b.height
      if b.break_after {
        flush(pages, page_index, frag, used)
        page_index = page_index + 1
        frag = []
        used = 0.0
      }
      k = k + 1
      continue
    }
    // 4) 可拆块：按行推进
    let mut rem = b.lines
    let mut is_first_piece = true
    while rem > 0 {
      let free = limit - used
      let fit = floor_lines(free, b.line_height)
      // 先按「剩余行」封顶：整块放得下时不拆，也就没有 orphan/widow 可言
      let cap = if fit < rem { fit } else { rem }
      let will_split = cap < rem
      let mut take = cap
      if will_split {
        // orphan：本页至少留 orphan_min 行（除非整块本来就不多）
        if take > 0 && take < policy.orphan_min && rem > policy.orphan_min {
          take = 0
        }
        // widow：下一页至少留 widow_min 行
        if take > 0 && rem - take < policy.widow_min && rem > policy.widow_min {
          let t = rem - policy.widow_min
          take = if t > 0 { t } else { 0 }
        }
      }
      if take <= 0 {
        if frag.length() > 0 {
          flush(pages, page_index, frag, used)
          page_index = page_index + 1
          frag = []
          used = 0.0
          continue
        }
        // 空页也放不下整整一行：强制放一行，允许溢出（见不变式 2 的例外）
        take = 1
      }
      let h = take.to_double() * b.line_height
      frag.push(PlacedFragment::{
        block_id: b.id,
        kind: b.kind,
        y: used,
        height: h,
        continues: rem - take > 0,
        is_continuation: !is_first_piece,
        seq,
      })
      seq = seq + 1
      used = used + h
      rem = rem - take
      is_first_piece = false
      if rem > 0 {
        flush(pages, page_index, frag, used)
        page_index = page_index + 1
        frag = []
        used = 0.0
      }
    }
    if b.break_after {
      flush(pages, page_index, frag, used)
      page_index = page_index + 1
      frag = []
      used = 0.0
    }
    k = k + 1
  }
  if frag.length() > 0 {
    flush(pages, page_index, frag, used)
  }
  Paginated::{ pages, error: "", }
}

///|
fn flush(
  pages : Array[Page],
  index : Int32,
  fragments : Array[PlacedFragment],
  used : Double,
) -> Unit {
  pages.push(Page::{ index, fragments, used, })
}

///|
/// 一个块至少需要占用的空间：不可拆块是整块高度，可拆块是一行。
fn min_piece_height(b : Block) -> Double {
  if b.height <= 0.0 {
    0.0
  } else if b.splittable {
    b.line_height
  } else {
    b.height
  }
}

///| `v` 里能放下多少个 `unit`（向下取整）。用循环而不是浮点取整，

///|
/// 避免 `@math` 依赖与三端 `floor` 实现差异；页数级别的数量级下开销可忽略。
pub fn floor_lines(v : Double, unit : Double) -> Int32 {
  if unit <= 0.0 || v < 0.0 {
    return 0
  }
  let mut n = 0
  while (n + 1).to_double() * unit <= v + 0.000000001 {
    n = n + 1
  }
  n
}

// ---------------- 不变式检查（） ----------------

///|
/// 不变式 1：分页不丢内容。
pub fn invariant_no_content_loss(
  blocks : Array[Block],
  result : Paginated,
) -> Bool {
  approx_eq(sum_block_heights(blocks), sum_fragment_heights(result))
}

///|
/// 不变式 2：每页内容高度不越界；单块/单行独占页的溢出按例外放行。
pub fn invariant_within_page_height(
  policy : PagePolicy,
  result : Paginated,
) -> Bool {
  let limit = content_height(policy)
  let mut ok = true
  for pg in result.pages {
    if pg.used < 0.0 {
      ok = false
    }
    if pg.fragments.length() > 1 && pg.used > limit + 0.000001 {
      ok = false
    }
    for f in pg.fragments {
      if f.height < 0.0 || f.y < 0.0 || f.y > limit + 0.000001 {
        ok = false
      }
    }
  }
  ok
}

///|
/// 不变式 3：片段序号严格单调递增。
pub fn invariant_monotonic(result : Paginated) -> Bool {
  let mut last = -1
  let mut ok = true
  for pg in result.pages {
    for f in pg.fragments {
      if f.seq <= last {
        ok = false
      }
      last = f.seq
    }
  }
  ok
}

///|
/// 不变式 4：幂等（无隐藏状态）。
pub fn invariant_idempotent(blocks : Array[Block], policy : PagePolicy) -> Bool {
  let a = paginate(copy_blocks(blocks), policy)
  let b = paginate(copy_blocks(blocks), policy)
  a == b
}

///|
/// 四条不变式一起跑，返回未通过者的名字（空数组表示全绿）。
pub fn check_all_invariants(
  blocks : Array[Block],
  policy : PagePolicy,
) -> Array[String] {
  let out : Array[String] = []
  let r = paginate(copy_blocks(blocks), policy)
  if r.error.length() > 0 {
    out.push("输入非法：" + r.error)
    return out
  }
  if !invariant_no_content_loss(blocks, r) {
    out.push("不变式1 不丢内容")
  }
  if !invariant_within_page_height(policy, r) {
    out.push("不变式2 不越界")
  }
  if !invariant_monotonic(r) {
    out.push("不变式3 单调")
  }
  if !invariant_idempotent(blocks, policy) {
    out.push("不变式4 幂等")
  }
  out
}

///|
pub fn copy_blocks(blocks : Array[Block]) -> Array[Block] {
  let out : Array[Block] = []
  for b in blocks {
    out.push(b)
  }
  out
}

///|
pub fn sum_block_heights(blocks : Array[Block]) -> Double {
  let mut s = 0.0
  for b in blocks {
    s = s + b.height
  }
  s
}

///|
pub fn sum_fragment_heights(result : Paginated) -> Double {
  let mut s = 0.0
  for pg in result.pages {
    for f in pg.fragments {
      s = s + f.height
    }
  }
  s
}

///|
pub fn approx_eq(a : Double, b : Double) -> Bool {
  let d = a - b
  let ad = if d < 0.0 { 0.0 - d } else { d }
  ad <= 0.000001
}

///| 的参考实现：只按高度切分，用于把「不丢内容」这条不变式

///|
/// 与 spike 的断言（`paginate([10,20,30,40], 35)`）逐字对齐。
pub fn paginate_heights(
  heights : Array[Double],
  limit : Double,
) -> Array[Double] {
  let pages : Array[Double] = []
  if limit <= 0.0 {
    pages.push(sum_block_heights_list(heights))
    return pages
  }
  let mut used = 0.0
  for h in heights {
    if h < 0.0 {
      continue
    }
    if h > limit {
      if used > 0.0 {
        pages.push(used)
        used = 0.0
      }
      pages.push(h)
    } else if used + h > limit + 0.000000001 {
      pages.push(used)
      used = h
    } else {
      used = used + h
    }
  }
  if used > 0.0 {
    pages.push(used)
  }
  pages
}

///|
pub fn sum_block_heights_list(heights : Array[Double]) -> Double {
  let mut s = 0.0
  for h in heights {
    s = s + h
  }
  s
}

// ---------------- 页眉页脚（交付物） ----------------

///| 模板变量替换：`{page}`（1 起）、`{total}`、`{chapter}`。

///|
/// 未识别的 `{...}` 原样保留，便于发现拼写错误而不是静默吞掉。
pub fn render_label(
  template : String,
  page_index : Int32,
  total : Int32,
  chapter : String,
) -> String {
  let one = (page_index + 1).to_string()
  let a = @util.replace_all(template, "{page}", one)
  let b = @util.replace_all(a, "{total}", total.to_string())
  @util.replace_all(b, "{chapter}", chapter)
}

///|
/// 每页的页脚文本。
pub fn page_footers(
  policy : PagePolicy,
  result : Paginated,
  chapter : String,
) -> Array[String] {
  let out : Array[String] = []
  let total = result.pages.length()
  for pg in result.pages {
    out.push(render_label(policy.footer_template, pg.index, total, chapter))
  }
  out
}

///|
/// 每页的页眉文本。
pub fn page_headers(
  policy : PagePolicy,
  result : Paginated,
  chapter : String,
) -> Array[String] {
  let out : Array[String] = []
  let total = result.pages.length()
  for pg in result.pages {
    out.push(render_label(policy.header_template, pg.index, total, chapter))
  }
  out
}
