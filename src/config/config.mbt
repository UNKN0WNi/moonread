///|
/// 严格 JSON 配置。
///
/// 规则：
/// - 格式只有 JSON，**不接受 YAML/TOML**；
/// - 语义只依赖数组顺序，对象键序无关；
/// - 未知字段**报错**（`@jsonio.reject_unknown_fields`），不静默忽略；
/// - 每个字段都有类型与范围校验，错误信息带 JSON 路径（`$.page.width_mm`）；
/// - `schema/config.schema.json` 与本文件由同一份字段表约束，
///   `tools/validate_json.py` 在 CI 里做双向校验（）。
#derive(Debug, Eq)
pub(all) struct Theme {
  /// `paper` / `night` / `custom`
  mode : String
  background : String
  foreground : String
  accent : String
}

///|
#derive(Debug, Eq)
pub(all) struct Typography {
  font_family : String
  font_size_pt : Double
  line_height : Double
  paragraph_spacing_em : Double
  justify : Bool
  hyphenate : Bool
}

///|
#derive(Debug, Eq)
pub(all) struct PageGeom {
  width_mm : Double
  height_mm : Double
  margin_top_mm : Double
  margin_bottom_mm : Double
  margin_inner_mm : Double
  margin_outer_mm : Double
  column_gap_mm : Double
  /// `ltr` / `rtl`
  direction : String
}

///|
#derive(Debug, Eq)
pub(all) struct Behavior {
  /// `paginated` / `scrolled`
  default_mode : String
  scroll_line_height_ratio : Double
  restore_position_on_open : Bool
  prefetch_pages : Int32
  /// `none` / `slide` / `fade`
  animation : String
}

///|
#derive(Debug, Eq)
pub(all) struct Storage {
  data_dir : String
  /// 目前只支持 `json`
  progress_format : String
  progress_every_pages : Int32
}

///|
#derive(Debug, Eq)
pub(all) struct Config {
  version : Int32
  theme : Theme
  typography : Typography
  page : PageGeom
  behavior : Behavior
  storage : Storage
}

///|
pub fn default_config() -> Config {
  Config::{
    version: 1,
    theme: Theme::{
      mode: "paper",
      background: "#f5f2e8",
      foreground: "#2b2b2b",
      accent: "#8b3a2f",
    },
    typography: Typography::{
      font_family: "serif",
      font_size_pt: 12.0,
      line_height: 1.6,
      paragraph_spacing_em: 0.8,
      justify: true,
      hyphenate: false,
    },
    page: PageGeom::{
      width_mm: 120.0,
      height_mm: 180.0,
      margin_top_mm: 15.0,
      margin_bottom_mm: 18.0,
      margin_inner_mm: 12.0,
      margin_outer_mm: 12.0,
      column_gap_mm: 0.0,
      direction: "ltr",
    },
    behavior: Behavior::{
      default_mode: "paginated",
      scroll_line_height_ratio: 1.0,
      restore_position_on_open: true,
      prefetch_pages: 2,
      animation: "none",
    },
    storage: Storage::{
      data_dir: "~/.local/share/moonread",
      progress_format: "json",
      progress_every_pages: 1,
    },
  }
}

// ---------------- 字段表（与 schema 同源） ----------------

///|
let top_fields : ReadOnlyArray[String] = [
  "$schema", "version", "theme", "typography", "page", "behavior", "storage",
]

///|
let theme_fields : ReadOnlyArray[String] = [
  "mode", "background", "foreground", "accent",
]

///|
let typography_fields : ReadOnlyArray[String] = [
  "font_family", "font_size_pt", "line_height", "paragraph_spacing_em", "justify",
  "hyphenate",
]

///|
let page_fields : ReadOnlyArray[String] = [
  "width_mm", "height_mm", "margin_top_mm", "margin_bottom_mm", "margin_inner_mm",
  "margin_outer_mm", "column_gap_mm", "direction",
]

///|
let behavior_fields : ReadOnlyArray[String] = [
  "default_mode", "scroll_line_height_ratio", "restore_position_on_open", "prefetch_pages",
  "animation",
]

///|
let storage_fields : ReadOnlyArray[String] = [
  "data_dir", "progress_format", "progress_every_pages",
]

///|
/// 本实现认识的全部字段路径，供 `tools/validate_json.py` 与 schema 对齐检查。
pub fn known_field_paths() -> Array[String] {
  let out : Array[String] = []
  for f in top_fields {
    out.push("$." + f)
  }
  for f in theme_fields {
    out.push("$.theme." + f)
  }
  for f in typography_fields {
    out.push("$.typography." + f)
  }
  for f in page_fields {
    out.push("$.page." + f)
  }
  for f in behavior_fields {
    out.push("$.behavior." + f)
  }
  for f in storage_fields {
    out.push("$.storage." + f)
  }
  out
}

// ---------------- 加载 ----------------

///|
/// 解析并校验配置。任何一步失败都返回带路径的中文错误。
pub fn from_json_text(text : String) -> Result[Config, String] {
  match @jsonio.parse(text) {
    Err(e) => Err("配置不是合法 JSON：" + e)
    Ok(root) => from_json(root)
  }
}

///|
pub fn from_json(root : @jsonio.Json) -> Result[Config, String] {
  match @jsonio.reject_unknown_fields(root, top_fields, "$") {
    Err(e) => return Err(e)
    Ok(_) => {
      let version = match @jsonio.obj_get(root, "version") {
        None => 1
        Some(v) =>
          match @jsonio.as_int(v) {
            Some(1) => 1
            Some(n) =>
              return Err("$.version 只支持 1，实际是 " + n.to_string())
            None => return Err("$.version 必须是整数")
          }
      }
      let theme = match @jsonio.obj_get(root, "theme") {
        None => default_config().theme
        Some(v) =>
          match parse_theme(v, "$.theme") {
            Err(e) => return Err(e)
            Ok(t) => t
          }
      }
      let typo = match @jsonio.obj_get(root, "typography") {
        None => default_config().typography
        Some(v) =>
          match parse_typography(v, "$.typography") {
            Err(e) => return Err(e)
            Ok(t) => t
          }
      }
      let page = match @jsonio.obj_get(root, "page") {
        None => default_config().page
        Some(v) =>
          match parse_page(v, "$.page") {
            Err(e) => return Err(e)
            Ok(p) => p
          }
      }
      let behavior = match @jsonio.obj_get(root, "behavior") {
        None => default_config().behavior
        Some(v) =>
          match parse_behavior(v, "$.behavior") {
            Err(e) => return Err(e)
            Ok(b) => b
          }
      }
      let storage = match @jsonio.obj_get(root, "storage") {
        None => default_config().storage
        Some(v) =>
          match parse_storage(v, "$.storage") {
            Err(e) => return Err(e)
            Ok(s) => s
          }
      }
      Ok(Config::{ version, theme, typography: typo, page, behavior, storage, })
    }
  }
}

///|
fn require_str_in(
  obj : @jsonio.Json,
  key : String,
  path : String,
  allowed : Array[String],
  dflt : String,
) -> Result[String, String] {
  match @jsonio.obj_get(obj, key) {
    None => Ok(dflt)
    Some(v) =>
      match @jsonio.as_str(v) {
        None => Err(path + "." + key + " 必须是字符串")
        Some(s) => {
          let mut hit = false
          for a in allowed {
            if a == s {
              hit = true
            }
          }
          if hit {
            Ok(s)
          } else {
            Err(
              path +
              "." +
              key +
              " 只允许 " +
              @util.join_nl(allowed) +
              "，实际 '" +
              s +
              "'",
            )
          }
        }
      }
  }
}

///|
fn require_num(
  obj : @jsonio.Json,
  key : String,
  path : String,
  dflt : Double,
  lo : Double,
  hi : Double,
) -> Result[Double, String] {
  match @jsonio.obj_get(obj, key) {
    None => Ok(dflt)
    Some(v) =>
      match @jsonio.as_double(v) {
        None => Err(path + "." + key + " 必须是数值")
        Some(d) =>
          if d < lo || d > hi {
            Err(
              path +
              "." +
              key +
              " 超出范围 [" +
              lo.to_string() +
              ", " +
              hi.to_string() +
              "]，实际 " +
              d.to_string(),
            )
          } else {
            Ok(d)
          }
      }
  }
}

///|
fn require_bool(
  obj : @jsonio.Json,
  key : String,
  path : String,
  dflt : Bool,
) -> Result[Bool, String] {
  match @jsonio.obj_get(obj, key) {
    None => Ok(dflt)
    Some(v) =>
      match @jsonio.as_bool(v) {
        Some(b) => Ok(b)
        None => Err(path + "." + key + " 必须是布尔")
      }
  }
}

///|
fn require_int_in(
  obj : @jsonio.Json,
  key : String,
  path : String,
  dflt : Int32,
  lo : Int32,
  hi : Int32,
) -> Result[Int32, String] {
  match @jsonio.obj_get(obj, key) {
    None => Ok(dflt)
    Some(v) =>
      match @jsonio.as_int(v) {
        None => Err(path + "." + key + " 必须是整数")
        Some(n) =>
          if n < lo || n > hi {
            Err(
              path +
              "." +
              key +
              " 超出范围 [" +
              lo.to_string() +
              ", " +
              hi.to_string() +
              "]",
            )
          } else {
            Ok(n)
          }
      }
  }
}

///|
fn require_color(
  obj : @jsonio.Json,
  key : String,
  path : String,
  dflt : String,
) -> Result[String, String] {
  match @jsonio.obj_get(obj, key) {
    None => Ok(dflt)
    Some(v) =>
      match @jsonio.as_str(v) {
        None => Err(path + "." + key + " 必须是颜色字符串")
        Some(s) =>
          if is_hex_color(s) {
            Ok(s)
          } else {
            Err(
              path +
              "." +
              key +
              " 必须是 #rgb 或 #rrggbb 形式，实际 '" +
              s +
              "'",
            )
          }
      }
  }
}

///|
/// `#rgb` / `#rrggbb`。不用正则，逐字符判定，三端行为一致。
pub fn is_hex_color(s : String) -> Bool {
  let cs = @util.to_chars(s)
  let n = cs.length()
  if n != 4 && n != 7 {
    return false
  }
  if cs[0] != '#' {
    return false
  }
  let mut i = 1
  while i < n {
    match @util.hex_digit_value(cs[i]) {
      Some(_) => ()
      None => return false
    }
    i = i + 1
  }
  true
}

///|
fn parse_theme(v : @jsonio.Json, path : String) -> Result[Theme, String] {
  match @jsonio.reject_unknown_fields(v, theme_fields, path) {
    Err(e) => return Err(e)
    Ok(_) => {
      let mode = match
        require_str_in(v, "mode", path, ["paper", "night", "custom"], "paper") {
        Ok(__try_v_1) => __try_v_1
        Err(__try_e_1) => return Err(__try_e_1)
      }
      Ok(Theme::{
        mode,
        background: match require_color(v, "background", path, "#f5f2e8") {
          Ok(__try_v_2) => __try_v_2
          Err(__try_e_2) => return Err(__try_e_2)
        },
        foreground: match require_color(v, "foreground", path, "#2b2b2b") {
          Ok(__try_v_3) => __try_v_3
          Err(__try_e_3) => return Err(__try_e_3)
        },
        accent: match require_color(v, "accent", path, "#8b3a2f") {
          Ok(__try_v_4) => __try_v_4
          Err(__try_e_4) => return Err(__try_e_4)
        },
      })
    }
  }
}

///|
fn parse_typography(
  v : @jsonio.Json,
  path : String,
) -> Result[Typography, String] {
  match @jsonio.reject_unknown_fields(v, typography_fields, path) {
    Err(e) => return Err(e)
    Ok(_) => {
      let ff = match @jsonio.obj_get(v, "font_family") {
        None => "serif"
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => s
            None => return Err(path + ".font_family 必须是字符串")
          }
      }
      Ok(Typography::{
        font_family: ff,
        font_size_pt: match
          require_num(v, "font_size_pt", path, 12.0, 6.0, 72.0) {
          Ok(__try_v_5) => __try_v_5
          Err(__try_e_5) => return Err(__try_e_5)
        },
        line_height: match require_num(v, "line_height", path, 1.6, 1.0, 4.0) {
          Ok(__try_v_6) => __try_v_6
          Err(__try_e_6) => return Err(__try_e_6)
        },
        paragraph_spacing_em: match
          require_num(v, "paragraph_spacing_em", path, 0.8, 0.0, 5.0) {
          Ok(__try_v_7) => __try_v_7
          Err(__try_e_7) => return Err(__try_e_7)
        },
        justify: match require_bool(v, "justify", path, true) {
          Ok(__try_v_8) => __try_v_8
          Err(__try_e_8) => return Err(__try_e_8)
        },
        hyphenate: match require_bool(v, "hyphenate", path, false) {
          Ok(__try_v_9) => __try_v_9
          Err(__try_e_9) => return Err(__try_e_9)
        },
      })
    }
  }
}

///|
fn parse_page(v : @jsonio.Json, path : String) -> Result[PageGeom, String] {
  match @jsonio.reject_unknown_fields(v, page_fields, path) {
    Err(e) => return Err(e)
    Ok(_) => {
      let dir = match
        require_str_in(v, "direction", path, ["ltr", "rtl"], "ltr") {
        Ok(__try_v_10) => __try_v_10
        Err(__try_e_10) => return Err(__try_e_10)
      }
      let w = match require_num(v, "width_mm", path, 120.0, 40.0, 1000.0) {
        Ok(__try_v_11) => __try_v_11
        Err(__try_e_11) => return Err(__try_e_11)
      }
      let h = match require_num(v, "height_mm", path, 180.0, 40.0, 1000.0) {
        Ok(__try_v_12) => __try_v_12
        Err(__try_e_12) => return Err(__try_e_12)
      }
      let mt = match require_num(v, "margin_top_mm", path, 15.0, 0.0, 200.0) {
        Ok(__try_v_13) => __try_v_13
        Err(__try_e_13) => return Err(__try_e_13)
      }
      let mb = match
        require_num(v, "margin_bottom_mm", path, 18.0, 0.0, 200.0) {
        Ok(__try_v_14) => __try_v_14
        Err(__try_e_14) => return Err(__try_e_14)
      }
      let mi = match require_num(v, "margin_inner_mm", path, 12.0, 0.0, 200.0) {
        Ok(__try_v_15) => __try_v_15
        Err(__try_e_15) => return Err(__try_e_15)
      }
      let mo = match require_num(v, "margin_outer_mm", path, 12.0, 0.0, 200.0) {
        Ok(__try_v_16) => __try_v_16
        Err(__try_e_16) => return Err(__try_e_16)
      }
      let gap = match require_num(v, "column_gap_mm", path, 0.0, 0.0, 200.0) {
        Ok(__try_v_17) => __try_v_17
        Err(__try_e_17) => return Err(__try_e_17)
      }
      if mt + mb >= h {
        return Err(
          path +
          "：上下边距之和 " +
          (mt + mb).to_string() +
          " 不小于页高 " +
          h.to_string(),
        )
      }
      if mi + mo >= w {
        return Err(
          path +
          "：内外边距之和 " +
          (mi + mo).to_string() +
          " 不小于页宽 " +
          w.to_string(),
        )
      }
      Ok(PageGeom::{
        width_mm: w,
        height_mm: h,
        margin_top_mm: mt,
        margin_bottom_mm: mb,
        margin_inner_mm: mi,
        margin_outer_mm: mo,
        column_gap_mm: gap,
        direction: dir,
      })
    }
  }
}

///|
fn parse_behavior(v : @jsonio.Json, path : String) -> Result[Behavior, String] {
  match @jsonio.reject_unknown_fields(v, behavior_fields, path) {
    Err(e) => return Err(e)
    Ok(_) => {
      let mode = match
        require_str_in(
          v,
          "default_mode",
          path,
          ["paginated", "scrolled"],
          "paginated",
        ) {
        Ok(__try_v_18) => __try_v_18
        Err(__try_e_18) => return Err(__try_e_18)
      }
      let anim = match
        require_str_in(v, "animation", path, ["none", "slide", "fade"], "none") {
        Ok(__try_v_19) => __try_v_19
        Err(__try_e_19) => return Err(__try_e_19)
      }
      Ok(Behavior::{
        default_mode: mode,
        scroll_line_height_ratio: match
          require_num(v, "scroll_line_height_ratio", path, 1.0, 0.1, 10.0) {
          Ok(__try_v_20) => __try_v_20
          Err(__try_e_20) => return Err(__try_e_20)
        },
        restore_position_on_open: match
          require_bool(v, "restore_position_on_open", path, true) {
          Ok(__try_v_21) => __try_v_21
          Err(__try_e_21) => return Err(__try_e_21)
        },
        prefetch_pages: match
          require_int_in(v, "prefetch_pages", path, 2, 0, 32) {
          Ok(__try_v_22) => __try_v_22
          Err(__try_e_22) => return Err(__try_e_22)
        },
        animation: anim,
      })
    }
  }
}

///|
fn parse_storage(v : @jsonio.Json, path : String) -> Result[Storage, String] {
  match @jsonio.reject_unknown_fields(v, storage_fields, path) {
    Err(e) => return Err(e)
    Ok(_) => {
      let fmt = match
        require_str_in(v, "progress_format", path, ["json"], "json") {
        Ok(__try_v_23) => __try_v_23
        Err(__try_e_23) => return Err(__try_e_23)
      }
      let dir = match @jsonio.obj_get(v, "data_dir") {
        None => "~/.local/share/moonread"
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => s
            None => return Err(path + ".data_dir 必须是字符串")
          }
      }
      Ok(Storage::{
        data_dir: dir,
        progress_format: fmt,
        progress_every_pages: match
          require_int_in(v, "progress_every_pages", path, 1, 1, 1000) {
          Ok(__try_v_24) => __try_v_24
          Err(__try_e_24) => return Err(__try_e_24)
        },
      })
    }
  }
}

// ---------------- 与分页策略的桥 ----------------

///|
/// 配置 -> 分页策略（）。这是唯一的换算点，保证「改配置即改分页」。
pub fn to_page_policy(c : Config) -> @paginate.PagePolicy {
  @paginate.PagePolicy::{
    page_width: @paginate.mm_to_px(c.page.width_mm),
    page_height: @paginate.mm_to_px(c.page.height_mm),
    margin_top: @paginate.mm_to_px(c.page.margin_top_mm),
    margin_bottom: @paginate.mm_to_px(c.page.margin_bottom_mm),
    margin_inner: @paginate.mm_to_px(c.page.margin_inner_mm),
    margin_outer: @paginate.mm_to_px(c.page.margin_outer_mm),
    column_gap: @paginate.mm_to_px(c.page.column_gap_mm),
    header_template: "",
    footer_template: "{page} / {total}",
    orphan_min: 2,
    widow_min: 2,
    break_after_chapter_start: true,
    honor_rtl: c.page.direction == "rtl",
  }
}

///|
/// 行高（CSS px）：字号 pt 换算成 px 再乘 line-height。
pub fn line_height_px(c : Config) -> Double {
  pt_to_px(c.typography.font_size_pt) * c.typography.line_height
}

///|
pub fn pt_to_px(pt : Double) -> Double {
  pt * 96.0 / 72.0
}

///|
/// 段落间距（CSS px）。
pub fn paragraph_spacing_px(c : Config) -> Double {
  c.typography.paragraph_spacing_em * pt_to_px(c.typography.font_size_pt)
}

///| 覆盖关系（）：本书配置覆盖全局配置。

///| 合并发生在 **JSON 层**而不是结构体层——解析后就无法区分「用户显式写了默认值」

///| 与「用户没写」，在结构体层合并会丢掉这个信息。

///| 合并规则：对象递归合并；数组与标量整体替换（不做逐元素合并，

///|
/// 因为「合并语义」会让用户无法确定最终值，违反 的可预测性）。
pub fn merge_json(base : @jsonio.Json, over : @jsonio.Json) -> @jsonio.Json {
  match (base, over) {
    (@jsonio.JObj(bf), @jsonio.JObj(of)) => {
      let out : Array[(String, @jsonio.Json)] = []
      for kv in bf {
        match @jsonio.obj_get(over, kv.0) {
          Some(ov) => out.push((kv.0, merge_json(kv.1, ov)))
          None => out.push(kv)
        }
      }
      for kv in of {
        if @jsonio.obj_get(base, kv.0) == None {
          out.push(kv)
        }
      }
      @jsonio.JObj(out)
    }
    _ => over
  }
}

///|
/// 全局配置 + 本书配置 -> 最终配置。
pub fn load_with_overlay(
  global_text : String,
  book_text : String,
) -> Result[Config, String] {
  let g = match @jsonio.parse(global_text) {
    Err(e) => Err("全局配置不是合法 JSON：" + e)
    Ok(v) => Ok(v)
  }
  let o = match @jsonio.parse(book_text) {
    Err(e) => Err("本书配置不是合法 JSON：" + e)
    Ok(v) => Ok(v)
  }
  match (g, o) {
    (Err(e), _) => Err(e)
    (_, Err(e)) => Err(e)
    (Ok(gv), Ok(ov)) => from_json(merge_json(gv, ov))
  }
}
