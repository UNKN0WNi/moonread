/// 漫画模式。
///
/// 首发只实现 **CBZ**（基于归档抽象，因此与 EPUB 共用 `Archive`）。
/// CBR / CB7 通过 `FormatHandler` 登记表接入：内核**不内置任何解压实现**，
/// 避免把 RAR/7z 的专利与许可问题带进 Apache-2.0 仓库（）。
///
/// RTL 与跨页对齐是「按什么顺序把页交给宿主」的语义问题，不是渲染问题，
/// 因此放在 L2，让 L4/L5 只消费结果。

///|
/// 一页图片。
#derive(Debug, Eq)
pub(all) struct ComicPage {
  /// 归档条目名（规范路径）。
  path : String
  /// 0 起的自然序页码。
  index : Int32
  /// 展示宽度提示（从扩展元数据或宿主传入；内核不做图像解码）。
  width_hint : Double
  height_hint : Double
}

///|
#derive(Debug, Eq)
pub(all) struct ComicBook {
  key : String
  pages : Array[ComicPage]
  /// 被忽略的非图片条目（例如 `metadata.json`、`.txt`），供告警。
  skipped : Array[String]
  warnings : Array[String]
}

///|
/// 解压格式登记项。`available` 表示当前构建里是否真的能解。
#derive(Debug, Eq)
pub(all) struct FormatHandler {
  extension : String
  /// `zip` / `rar` / `7z`
  family : String
  available : Bool
  note : String
}

///|
/// 首发格式支持矩阵（交付物「接口就绪，首发提供 CBZ + 一个 RAR 实现」）。
pub fn handlers() -> Array[FormatHandler] {
  [
    FormatHandler::{
      extension: "cbz",
      family: "zip",
      available: true,
      note: "基于 src/container + src/zipio（hustcer/fzip）",
    },
    FormatHandler::{
      extension: "zip",
      family: "zip",
      available: true,
      note: "同 CBZ",
    },
    FormatHandler::{
      extension: "cbr",
      family: "rar",
      available: false,
      note: "需要外部 RAR 解压实现。RAR 规范非开放许可，内核不内置解码器（）。",
    },
    FormatHandler::{
      extension: "cb7",
      family: "7z",
      available: false,
      note: "需要外部 7z 解压实现（LGPL 相关，交由宿主插件提供）。",
    },
    FormatHandler::{
      extension: "cbt",
      family: "tar",
      available: false,
      note: "tar 无压缩，实现成本低，列为后续项。",
    },
  ]
}

///|
pub fn handler_for(extension : String) -> FormatHandler? {
  let want = @util.ascii_lower(extension)
  let mut found : FormatHandler? = None
  for h in handlers() {
    if h.extension == want {
      found = Some(h)
      break
    }
  }
  found
}

///|
/// 从归档构造漫画书：筛出图片条目、按自然序排序、丢掉目录条目。
pub fn open(a : @container.Archive) -> ComicBook {
  let warnings : Array[String] = []
  let picked : Array[String] = []
  let skipped : Array[String] = []
  for n in @container.names(a) {
    if @util.ends_with(n, "/") {
      skipped.push(n)
    } else if @resource.is_page_image(n) {
      picked.push(n)
    } else {
      skipped.push(n)
    }
  }
  if picked.length() == 0 {
    warnings.push(
      "归档内没有任何可识别的页图（支持扩展名见 src/resource/media_type_of）",
    )
  }
  @container.sort_natural(picked)
  let pages : Array[ComicPage] = []
  let mut i = 0
  while i < picked.length() {
    pages.push(ComicPage::{
      path: picked[i],
      index: i,
      width_hint: 0.0,
      height_hint: 0.0,
    })
    i = i + 1
  }
  ComicBook::{ key: a.name, pages, skipped, warnings, }
}

///|
pub fn page_count(b : ComicBook) -> Int32 {
  b.pages.length()
}

///|
pub fn page_at(b : ComicBook, index : Int32) -> ComicPage? {
  if index < 0 || index >= b.pages.length() {
    None
  } else {
    Some(b.pages[index])
  }
}

// ---------------- 翻页方向与跨页 ----------------

///|
/// 一次「翻页」移动多少页：单页模式 1，双页模式 2。
#derive(Debug, Eq)
pub(all) enum ViewMode {
  Single
  /// 双页（跨页图会被当作一个整体，见 `spreads`）。
  Double
}

///|
/// 一个「展示单元」：1 或 2 页。双页模式下，宽图（跨页图）单独占一个单元。
#derive(Debug, Eq)
pub(all) struct Spread {
  /// 展示单元序号，0 起。
  index : Int32
  /// 页下标（单页时长度 1）。顺序即**阅读顺序**（RTL 时右页在前）。
  pages : Array[Int32]
  /// 是否为跨页大图独占的单元。
  is_single_full : Bool
}

///|
#derive(Debug, Eq)
pub(all) struct SpreadPolicy {
  mode : ViewMode
  rtl : Bool
  /// 宽大于此比例（width/height）的页视为跨页图。
  wide_ratio_threshold : Double
  /// 首页（封面）是否单独成单元，双页模式下常见做法。
  cover_alone : Bool
}

///|
pub fn default_spread_policy() -> SpreadPolicy {
  SpreadPolicy::{
    mode: Double,
    rtl: true,
    wide_ratio_threshold: 1.4,
    cover_alone: true,
  }
}

///|
fn is_wide(p : ComicPage, threshold : Double) -> Bool {
  p.width_hint > 0.0 &&
  p.height_hint > 0.0 &&
  p.width_hint / p.height_hint >= threshold
}

///| 把页序列切成展示单元。

///|

///| 规则（按顺序判定）：

///| 1. `Single` 模式：每页一个单元。

///| 2. `cover_alone` 且第一页存在：封面单独成单元。

///| 3. 跨页大图（`is_wide`）单独成单元，并吞掉紧随其后的那一页吗？

///|    **不吞**——跨页图本身已经是完整画面，多喂一页会造成内容重复。

///| 4. 其余两两配对。

///|
/// 5. `rtl` 时，配对内部顺序为「右页在前、左页在后」。
pub fn spreads(b : ComicBook, policy : SpreadPolicy) -> Array[Spread] {
  let out : Array[Spread] = []
  let n = b.pages.length()
  if n == 0 {
    return out
  }
  match policy.mode {
    Single => {
      let mut i = 0
      while i < n {
        out.push(Spread::{
          index: out.length(),
          pages: [i],
          is_single_full: false,
        })
        i = i + 1
      }
      out
    }
    Double => {
      let mut i = 0
      if policy.cover_alone {
        out.push(Spread::{ index: 0, pages: [0], is_single_full: false, })
        i = 1
      }
      while i < n {
        let p = b.pages[i]
        if is_wide(p, policy.wide_ratio_threshold) {
          out.push(Spread::{
            index: out.length(),
            pages: [i],
            is_single_full: true,
          })
          i = i + 1
        } else if i + 1 < n &&
          !is_wide(b.pages[i + 1], policy.wide_ratio_threshold) {
          let pair = if policy.rtl { [i + 1, i] } else { [i, i + 1] }
          out.push(Spread::{
            index: out.length(),
            pages: pair,
            is_single_full: false,
          })
          i = i + 2
        } else {
          out.push(Spread::{
            index: out.length(),
            pages: [i],
            is_single_full: false,
          })
          i = i + 1
        }
      }
      out
    }
  }
}

///|
/// 下一页 / 上一页（按展示单元）。返回越界信息而不是 panic。
pub fn advance(
  total : Int32,
  current : Int32,
  step : Int32,
) -> Result[Int32, String] {
  if total <= 0 {
    return Err("没有可翻的页")
  }
  let next = current + step
  if next < 0 {
    Err(
      "已经在第一页之前（共 " +
      total.to_string() +
      " 个展示单元）",
    )
  } else if next >= total {
    Err(
      "已经在最后一页之后（共 " +
      total.to_string() +
      " 个展示单元）",
    )
  } else {
    Ok(next)
  }
}

///|
/// RTL 时把「左键」映射为前进、「右键」映射为后退。
pub fn rtl_key_mapping(rtl : Bool) -> (String, String) {
  if rtl {
    ("ArrowLeft", "ArrowRight")
  } else {
    ("ArrowRight", "ArrowLeft")
  }
}
