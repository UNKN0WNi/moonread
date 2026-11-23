///|
/// 目录树。
///
/// `src/epub` 给出的是**原始** `NavPoint` 树（L2 不能依赖 L4，见 ）。
/// 本包负责加上 UI 需要的派生信息：层级、扁平序号、当前位置定位、
/// 以及「没有 nav 也没有 NCX」时按 spine 合成目录的降级路径。
#derive(Debug, Eq)
pub(all) struct TocItem {
  label : String
  /// 归档内规范路径；空串表示这一项只是分组容器。
  path : String
  fragment : String
  /// 0 起。
  level : Int32
  /// 深度优先展开后的序号。
  ordinal : Int32
  children : Array[TocItem]
  /// EPUB3 nav 的 `span` 分组标题（无跳转目标）。
  is_group : Bool
  /// HTML hidden 布尔属性（仅供机器处理的分支）。
  hidden : Bool
}

///|
#derive(Debug, Eq)
pub(all) struct Toc {
  items : Array[TocItem]
  /// `nav` / `ncx` / `spine-fallback` / `empty`
  source : String
  warnings : Array[String]
}

///|
fn flatten(
  points : Array[@epub.NavPoint],
  level : Int32,
  counter : Array[Int32],
) -> Array[TocItem] {
  let out : Array[TocItem] = []
  for p in points {
    let ord = counter[0]
    counter[0] = ord + 1
    out.push(TocItem::{
      label: p.label,
      path: p.path,
      fragment: p.fragment,
      level,
      ordinal: ord,
      children: flatten(p.children, level + 1, counter),
      is_group: p.is_group,
      hidden: p.hidden,
    })
  }
  out
}

///|
pub fn depth_first(items : Array[TocItem]) -> Array[TocItem] {
  let out : Array[TocItem] = []
  for it in items {
    out.push(it)
    for d in depth_first(it.children) {
      out.push(d)
    }
  }
  out
}

///|
pub fn total_items(t : Toc) -> Int32 {
  depth_first(t.items).length()
}

///|
/// 从 EPUB 解析结果构造目录：nav 优先，回退 NCX，再回退 spine 合成。
pub fn from_book(b : @epub.EpubBook) -> Toc {
  let warnings : Array[String] = []
  if b.nav_toc.length() > 0 {
    let counter : Array[Int32] = [0]
    Toc::{ items: flatten(b.nav_toc, 0, counter), source: "nav", warnings, }
  } else if b.ncx_toc.length() > 0 {
    let counter : Array[Int32] = [0]
    Toc::{ items: flatten(b.ncx_toc, 0, counter), source: "ncx", warnings, }
  } else {
    warnings.push("无 nav 也无 NCX，按 spine 合成一级目录")
    Toc::{ items: from_spine(b), source: "spine-fallback", warnings, }
  }
}

///|
/// 降级目录：每个章节一项，标签用文件名。
pub fn from_spine(b : @epub.EpubBook) -> Array[TocItem] {
  let out : Array[TocItem] = []
  let mut ord = 0
  for p in @epub.chapter_paths(b) {
    out.push(TocItem::{
      label: @util.path_basename(p),
      path: p,
      fragment: "",
      level: 0,
      ordinal: ord,
      children: [],
      is_group: false,
      hidden: false,
    })
    ord = ord + 1
  }
  out
}

///|
/// 目录项指向的章节序号（在 `chapter_paths` 里的下标）；找不到返回 -1。
pub fn chapter_index_of(t : Toc, b : @epub.EpubBook, ordinal : Int32) -> Int32 {
  let flat = depth_first(t.items)
  let mut target = ""
  let mut found = false
  for it in flat {
    if it.ordinal == ordinal {
      target = it.path
      found = true
    }
  }
  if !found || target.length() == 0 {
    return -1
  }
  let mut idx = 0
  let paths = @epub.chapter_paths(b)
  while idx < paths.length() {
    if paths[idx] == target {
      return idx
    }
    idx = idx + 1
  }
  1
}

///|
/// 当前阅读位置对应的目录项：取「路径等于当前章节且层级最深」的那一项。
pub fn current_item(t : Toc, chapter_path : String) -> TocItem? {
  let mut best : TocItem? = None
  for it in depth_first(t.items) {
    if it.path == chapter_path {
      match best {
        None => best = Some(it)
        Some(cur) => if it.level > cur.level { best = Some(it) }
      }
    }
  }
  best
}

///|
/// 缩进文本形式的目录，供 `moon run` 与嵌入示例打印。
pub fn render_text(t : Toc) -> String {
  let lines : Array[String] = []
  for it in depth_first(t.items) {
    let mut indent = ""
    let mut i = 0
    while i < it.level {
      indent = indent + "  "
      i = i + 1
    }
    let frag = if it.fragment.length() > 0 { "#" + it.fragment } else { "" }
    lines.push(indent + it.label + " -> " + it.path + frag)
  }
  if lines.length() == 0 {
    lines.push("<空目录>")
  }
  @util.join_nl(lines)
}
