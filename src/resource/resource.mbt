/// 资源解析。
///
/// 输入是两个字符串：`base`（引用发生处的文件在归档内的规范路径，例如
/// `OEBPS/content.opf` 或 `OEBPS/ch1.xhtml`）与 `href`（原始引用）。
/// 输出是 `ResourceRef`，即「这条引用到底指向哪里」的四分类。
///
/// 刻意**不做**的事：
/// - 不访问网络（远程资源只分类出来，由宿主决定怎么处理）；
/// - 不猜编码（URL 百分号解码按 UTF-8 严格校验，失败即 `Invalid`）；
/// - 不静默吞掉脏数据（一律以 `Invalid(中文原因)` 返回，交上层聚合告警）。

///| 一条引用的归属。载荷用位置参数而不是命名字段，是为了让 `match` 模式

///|
/// 在所有工具链版本上都写法一致（见 docs/DEV-GUIDE.md 的「枚举载荷」条）。
#derive(Debug, Eq)
pub(all) enum ResourceRef {
  /// 归档内规范路径（已折叠 `..`、已百分号解码、已去锚点）。
  InArchive(String)
  /// `data:` 内嵌资源：媒体类型、载荷、是否 base64。
  Inline(String, String, Bool)
  /// 外部引用：scheme、原始 href、是否被策略允许。
  Remote(String, String, Bool)
  /// 无法安全解析，携带中文原因，供告警聚合。
  Invalid(String)
}

///|
#derive(Debug, Eq)
pub(all) struct RemotePolicy {
  /// 是否允许远程资源。内核默认 `false`：离线可读是「可嵌入内核」的前提。
  /// 允许时 `Remote` 的第三个载荷为 `true`，宿主据此决定是否交给浏览器。
  allow_remote : Bool
  /// 是否允许 `data:` 内嵌。默认 `true`（EPUB 3 允许，且不需要外部依赖）。
  allow_inline : Bool
  /// `data:` 内嵌解码后的字节预算，防构造输入。默认 8 MiB。
  inline_budget_bytes : Int32
}

///|
pub fn default_remote_policy() -> RemotePolicy {
  RemotePolicy::{
    allow_remote: false,
    allow_inline: true,
    inline_budget_bytes: 8388608,
  }
}

///|
pub fn allow_all_policy() -> RemotePolicy {
  RemotePolicy::{
    allow_remote: true,
    allow_inline: true,
    inline_budget_bytes: 8388608,
  }
}

///|
/// 主入口。`base` 是引用所在文件路径，`href` 是原始引用文本。
pub fn resolve_with(
  base : String,
  href : String,
  policy : RemotePolicy,
) -> ResourceRef {
  let trimmed = @util.trim(href)
  if trimmed.length() == 0 {
    return Invalid("引用为空")
  }
  if @util.starts_with(trimmed, "data:") {
    return decode_data_uri(trimmed, policy)
  }
  if @util.has_scheme(trimmed) {
    let s = @util.ascii_lower(@util.scheme_of(trimmed))
    if s == "urn" {
      // OPF 的 `unique-identifier` / `dc:identifier` 常用 urn，不是可取用资源
      return Remote(s, trimmed, false)
    }
    return Remote(s, trimmed, policy.allow_remote)
  }
  let without_fragment = @util.strip_fragment(trimmed)
  if without_fragment.length() == 0 {
    // 纯锚点引用：指向所在文件自身
    return InArchive(base)
  }
  match @util.percent_decode(without_fragment) {
    Err(reason) => Invalid("百分号解码失败：" + reason)
    Ok(decoded) =>
      if decoded.length() == 0 {
        Invalid("解码后为空：" + href)
      } else if @util.contains(decoded, "\\") {
        Invalid("路径含反斜杠：'" + decoded + "'")
      } else {
        // 以 `/` 开头的引用相对归档根，而不是相对当前目录（OPF 允许这种写法）
        let norm = if @util.starts_with(decoded, "/") {
          strip_root(@util.path_normalize("", decoded))
        } else {
          @util.path_normalize(@util.path_dirname(base), decoded)
        }
        if norm.length() == 0 {
          Invalid("规范化后为空路径：" + href)
        } else if has_dotdot_segment(norm) {
          Invalid("规范化后仍含上跳：" + norm)
        } else {
          InArchive(norm)
        }
      }
  }
}

///|
/// 按段判定，避免把 `ch..1.xhtml` 这类合法文件名误判为上跳。
fn has_dotdot_segment(p : String) -> Bool {
  for seg in @util.split_char(p, '/') {
    if seg == ".." {
      return true
    }
  }
  false
}

///|
fn strip_root(p : String) -> String {
  if @util.starts_with(p, "/") {
    @util.slice_string(p, 1, @util.to_chars(p).length())
  } else {
    p
  }
}

///|
pub fn resolve(base : String, href : String) -> ResourceRef {
  resolve_with(base, href, default_remote_policy())
}

///|
/// 只要归档路径，其它分类一律转成 `Err(原因)`。OPF/NCX 解析内部用这个。
pub fn resolve_path(base : String, href : String) -> Result[String, String] {
  match resolve(base, href) {
    InArchive(p) => Ok(p)
    Remote(sc, h, _) =>
      Err("外部引用不在内核取用范围：" + sc + " " + h)
    Inline(mt, _, _) => Err("内嵌资源没有归档路径：" + mt)
    Invalid(reason) => Err(reason)
  }
}

///|
/// 锚点片段（`nav.xhtml#toc_2` -> `toc_2`）。
pub fn fragment(href : String) -> String {
  @util.fragment_of(@util.trim(href))
}

///|
fn decode_data_uri(href : String, policy : RemotePolicy) -> ResourceRef {
  let rest = @util.slice_string(href, 5, @util.to_chars(href).length())
  match @util.index_of(rest, ",") {
    None => Invalid("data: 引用缺少逗号分隔符")
    Some(i) => {
      let meta = @util.slice_string(rest, 0, i)
      let payload = @util.slice_string(
        rest,
        i + 1,
        @util.to_chars(rest).length(),
      )
      let meta_parts = @util.split_char(meta, ';')
      let first = if meta_parts.length() > 0 { meta_parts[0] } else { "" }
      let last = if meta_parts.length() > 0 {
        meta_parts[meta_parts.length() - 1]
      } else {
        ""
      }
      let is_b64 = @util.ascii_lower(last) == "base64"
      let real_mt = if first.length() == 0 { "text/plain" } else { first }
      if is_b64 {
        // base64 载荷在内核里不解码成二进制：只登记预算，交由渲染层取用
        if @util.to_chars(payload).length() > policy.inline_budget_bytes {
          Invalid(
            "data: 内嵌超出字节预算 " +
            policy.inline_budget_bytes.to_string(),
          )
        } else {
          Inline(real_mt, payload, true)
        }
      } else {
        match @util.percent_decode(payload) {
          Err(reason) => Invalid("data: 百分号解码失败：" + reason)
          Ok(text) =>
            if @util.utf8_len(text) > policy.inline_budget_bytes {
              Invalid(
                "data: 内嵌超出字节预算 " +
                policy.inline_budget_bytes.to_string(),
              )
            } else {
              Inline(real_mt, text, false)
            }
        }
      }
    }
  }
}

// ---------------- 媒体类型 ----------------

///| 按扩展名推断媒体类型。OPF 的 `media-type` 优先，扩展名只作为兜底与

///|
/// nav/NCX 之外的资源（如漫画页图）分类依据。
pub fn media_type_of(path : String) -> String {
  let lower = @util.ascii_lower(@util.path_basename(path))
  if @util.ends_with(lower, ".xhtml") {
    "application/xhtml+xml"
  } else if @util.ends_with(lower, ".html") || @util.ends_with(lower, ".htm") {
    "text/html"
  } else if @util.ends_with(lower, ".xml") {
    "application/xml"
  } else if @util.ends_with(lower, ".opf") {
    "application/oebps-package+xml"
  } else if @util.ends_with(lower, ".ncx") {
    "application/x-dtbncx+xml"
  } else if @util.ends_with(lower, ".css") {
    "text/css"
  } else if @util.ends_with(lower, ".js") {
    "text/javascript"
  } else if @util.ends_with(lower, ".svg") {
    "image/svg+xml"
  } else if @util.ends_with(lower, ".png") {
    "image/png"
  } else if @util.ends_with(lower, ".jpg") || @util.ends_with(lower, ".jpeg") {
    "image/jpeg"
  } else if @util.ends_with(lower, ".gif") {
    "image/gif"
  } else if @util.ends_with(lower, ".webp") {
    "image/webp"
  } else if @util.ends_with(lower, ".avif") {
    "image/avif"
  } else if @util.ends_with(lower, ".tif") || @util.ends_with(lower, ".tiff") {
    "image/tiff"
  } else if @util.ends_with(lower, ".bmp") {
    "image/bmp"
  } else if @util.ends_with(lower, ".ico") {
    "image/vnd.microsoft.icon"
  } else if @util.ends_with(lower, ".woff2") {
    "font/woff2"
  } else if @util.ends_with(lower, ".woff") {
    "font/woff"
  } else if @util.ends_with(lower, ".otf") {
    "font/otf"
  } else if @util.ends_with(lower, ".ttf") {
    "font/ttf"
  } else if @util.ends_with(lower, ".mp3") {
    "audio/mpeg"
  } else if @util.ends_with(lower, ".mp4") {
    "video/mp4"
  } else if @util.ends_with(lower, ".smil") {
    "application/smil+xml"
  } else if @util.ends_with(lower, ".json") {
    "application/json"
  } else if @util.ends_with(lower, ".txt") {
    "text/plain"
  } else {
    "application/octet-stream"
  }
}

///|
pub fn is_markup_media(mt : String) -> Bool {
  let s = @util.ascii_lower(mt)
  s == "application/xhtml+xml" || s == "text/html" || s == "text/xhtml"
}

///|
pub fn is_css_media(mt : String) -> Bool {
  @util.ascii_lower(mt) == "text/css"
}

///|
pub fn is_image_media(mt : String) -> Bool {
  @util.starts_with(@util.ascii_lower(mt), "image/")
}

///|
pub fn is_font_media(mt : String) -> Bool {
  let s = @util.ascii_lower(mt)
  @util.starts_with(s, "font/") ||
  s == "application/font-sfnt" ||
  s == "application/x-font-opentype" ||
  s == "application/x-font-truetype"
}

///|
/// 漫画页扩展名判定（CBZ 里没有 OPF，只能按扩展名筛）。
pub fn is_page_image(path : String) -> Bool {
  is_image_media(media_type_of(path))
}

///|
/// EPUB 的 `properties` 字段（空格分隔多值）判定。
pub fn has_property(properties : String, want : String) -> Bool {
  for p in @util.split_char(properties, ' ') {
    if p == want {
      return true
    }
  }
  for p in @util.split_char(properties, '\t') {
    if p == want {
      return true
    }
  }
  false
}
