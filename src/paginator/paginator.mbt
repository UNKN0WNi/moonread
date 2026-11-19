///|
/// 页码 / 进度 / 定位。
///
/// 全部字段都是整数或字符串，**没有浮点**：进度用千分比（permille）而不是
/// 0.x 小数。这样持久化文本在三端逐字节一致（），也不会出现
/// 「重启后进度差 1e-17 页」这类无法复现的问题。
#derive(Debug, Eq)
pub(all) struct Locator {
  /// 章节在 `chapter_paths` 里的下标，0 起。
  chapter : Int32
  /// 页在章内的下标，0 起。
  page : Int32
  /// 该章的总页数（写入当时的快照，章内容变化时用于判断失效）。
  total_pages : Int32
  /// 页内首个片段的块路径（`src/render` 的结构路径），用于精确恢复。
  anchor : String
}

///|
pub fn locator(chapter : Int32, page : Int32, total_pages : Int32) -> Locator {
  Locator::{ chapter, page, total_pages, anchor: "", }
}

///|
pub fn locator_at(
  chapter : Int32,
  page : Int32,
  total_pages : Int32,
  anchor : String,
) -> Locator {
  Locator::{ chapter, page, total_pages, anchor, }
}

///|
#derive(Debug, Eq)
pub(all) struct Progress {
  /// 书的稳定标识（EPUB 用 dc:identifier，CBZ 用文件名 + 条目数）。
  book_key : String
  locator : Locator
  /// 全书千分比进度，0..1000。
  ratio_permille : Int32
  /// 章节总数快照。
  total_chapters : Int32
  /// ISO-8601 文本，由宿主传入（内核不读时钟，保证可复现与三端一致）。
  updated : String
}

///| 非负整数除法。用减法实现，避免依赖 `/`（MoonBit 的 `/` 是浮点除）

///| 或 `//`（不同工具链版本支持不一致）。这里操作数都是 0..1000 量级，

///|
/// 减法循环最多一千次，成本可忽略，换来的是三端逐位一致（）。
pub fn idiv(a : Int32, b : Int32) -> Int32 {
  if b <= 0 {
    return 0
  }
  let mut q = 0
  let mut rest = a
  while rest >= b {
    rest = rest - b
    q = q + 1
  }
  q
}

///|
/// 全书进度千分比。`chapter` 与 `page` 按比例分摊到各章（等章权重）。
pub fn permille(
  chapter : Int32,
  page : Int32,
  pages_in_chapter : Int32,
  total_chapters : Int32,
) -> Int32 {
  if total_chapters <= 0 || pages_in_chapter <= 0 {
    return 0
  }
  let mut ch = chapter
  if ch < 0 {
    ch = 0
  }
  if ch >= total_chapters {
    ch = total_chapters - 1
  }
  let mut pg = page
  if pg < 0 {
    pg = 0
  }
  if pg >= pages_in_chapter {
    pg = pages_in_chapter - 1
  }
  let base = idiv(ch * 1000, total_chapters)
  let span = idiv(1000, total_chapters)
  let within = idiv(span * pg, pages_in_chapter)
  let v = base + within
  if v > 1000 {
    1000
  } else if v < 0 {
    0
  } else {
    v
  }
}

///|
pub fn make_progress(
  book_key : String,
  chapter : Int32,
  page : Int32,
  pages_in_chapter : Int32,
  total_chapters : Int32,
  updated : String,
) -> Progress {
  Progress::{
    book_key,
    locator: locator(chapter, page, pages_in_chapter),
    ratio_permille: permille(chapter, page, pages_in_chapter, total_chapters),
    total_chapters,
    updated,
  }
}

// ---------------- JSON 持久化 ----------------

///|
pub fn progress_to_json(p : Progress) -> String {
  let parts : Array[String] = []
  parts.push("\"book_key\":" + @jsonio.encode_string_literal(p.book_key))
  parts.push("\"chapter\":" + p.locator.chapter.to_string())
  parts.push("\"page\":" + p.locator.page.to_string())
  parts.push("\"total_pages\":" + p.locator.total_pages.to_string())
  parts.push("\"anchor\":" + @jsonio.encode_string_literal(p.locator.anchor))
  parts.push("\"ratio_permille\":" + p.ratio_permille.to_string())
  parts.push("\"total_chapters\":" + p.total_chapters.to_string())
  parts.push("\"updated\":" + @jsonio.encode_string_literal(p.updated))
  let mut obj = "{"
  let mut i = 0
  while i < parts.length() {
    if i > 0 {
      obj = obj + ","
    }
    obj = obj + parts[i]
    i = i + 1
  }
  obj + "}"
}

///|
pub fn progress_from_json(text : String) -> Result[Progress, String] {
  match @jsonio.parse(text) {
    Err(e) => Err("进度文件不是合法 JSON：" + e)
    Ok(root) =>
      match
        @jsonio.reject_unknown_fields(
          root,
          [
            "book_key", "chapter", "page", "total_pages", "anchor", "ratio_permille",
            "total_chapters", "updated",
          ],
          "$",
        ) {
        Err(e) => return Err(e)
        Ok(_) => {
          let book_key = match @jsonio.require_str(root, "book_key", "$") {
            Ok(__try_v_1) => __try_v_1
            Err(__try_e_1) => return Err(__try_e_1)
          }
          let chapter = match @jsonio.require_int(root, "chapter", "$") {
            Ok(__try_v_2) => __try_v_2
            Err(__try_e_2) => return Err(__try_e_2)
          }
          let page = match @jsonio.require_int(root, "page", "$") {
            Ok(__try_v_3) => __try_v_3
            Err(__try_e_3) => return Err(__try_e_3)
          }
          let total_pages = match
            @jsonio.require_int(root, "total_pages", "$") {
            Ok(__try_v_4) => __try_v_4
            Err(__try_e_4) => return Err(__try_e_4)
          }
          let anchor = match @jsonio.require_str(root, "anchor", "$") {
            Ok(__try_v_5) => __try_v_5
            Err(__try_e_5) => return Err(__try_e_5)
          }
          let ratio = match @jsonio.require_int(root, "ratio_permille", "$") {
            Ok(__try_v_6) => __try_v_6
            Err(__try_e_6) => return Err(__try_e_6)
          }
          let total_chapters = match
            @jsonio.require_int(root, "total_chapters", "$") {
            Ok(__try_v_7) => __try_v_7
            Err(__try_e_7) => return Err(__try_e_7)
          }
          let updated = match @jsonio.require_str(root, "updated", "$") {
            Ok(__try_v_8) => __try_v_8
            Err(__try_e_8) => return Err(__try_e_8)
          }
          if chapter < 0 || page < 0 || total_pages < 0 || total_chapters < 0 {
            return Err("进度含负数下标")
          }
          if ratio < 0 || ratio > 1000 {
            return Err(
              "ratio_permille 必须在 0..1000，实际 " + ratio.to_string(),
            )
          }
          Ok(Progress::{
            book_key,
            locator: locator_at(chapter, page, total_pages, anchor),
            ratio_permille: ratio,
            total_chapters,
            updated,
          })
        }
      }
  }
}

///|
/// 恢复校验：章数或该章页数变了，说明内容/策略已变，位置需要重新夹取。
#derive(Debug, Eq)
pub(all) enum Restore {
  Exact(Locator)
  Clamped(Locator, String)
  Rejected(String)
}

///|
pub fn restore(
  p : Progress,
  total_chapters : Int32,
  pages_of : (Int32) -> Int32,
) -> Restore {
  let loc = p.locator
  if total_chapters <= 0 {
    return Rejected("本书没有可定位的章节")
  }
  if loc.chapter >= total_chapters {
    let fixed = locator(total_chapters - 1, 0, 1)
    return Clamped(
      fixed,
      "章序号 " +
      loc.chapter.to_string() +
      " 超出当前 " +
      total_chapters.to_string() +
      " 章",
    )
  }
  let pages = pages_of(loc.chapter)
  if pages <= 0 {
    return Clamped(locator(loc.chapter, 0, 1), "该章当前没有页面")
  }
  if loc.page >= pages {
    return Clamped(
      locator(loc.chapter, pages - 1, pages),
      "页序号 " +
      loc.page.to_string() +
      " 超出该章当前 " +
      pages.to_string() +
      " 页",
    )
  }
  Exact(locator_at(loc.chapter, loc.page, pages, loc.anchor))
}

///|
/// 人类可读位置：`第 3 章 第 12 页 · 3.5%`。
pub fn describe(p : Progress) -> String {
  "第 " +
  p.locator.chapter.to_string() +
  " 章 第 " +
  p.locator.page.to_string() +
  " 页 · " +
  permille_text(p.ratio_permille)
}

///| 千分比 -> 一位小数的百分数文本。

///| 用减法等价于整除，避免依赖 `/` 在整数上的语义（MoonBit 的 `/` 是浮点除，

///|
/// 整除写作 `//`，不同版本对 `//` 的支持不一，这里干脆不用）。
pub fn permille_text(v : Int32) -> String {
  let clamped = if v < 0 { 0 } else if v > 1000 { 1000 } else { v }
  let mut whole = 0
  let mut rest = clamped
  while rest >= 10 {
    whole = whole + 1
    rest = rest - 10
  }
  whole.to_string() + "." + rest.to_string() + "%"
}
