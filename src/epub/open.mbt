/// EPUB 打开流程。
///
/// `open` 的策略：先按严格模式解析，任一步失败**自动降级**到 lenient 重试，
/// 并把两次尝试的差异记入 `warnings`。这样既满足「规范文档严格解析」，
/// 又满足  的「缺 nav、缺 spine、重复 id、非法 XML —— 降级可用，不 panic」。

///|
/// 严格模式打开。失败即返回 Err，不做降级。
pub fn open_strict(a : @container.Archive) -> Result[EpubBook, String] {
  open_with(a, false)
}

///|
/// 默认入口：严格失败则 lenient 重试。
pub fn open(a : @container.Archive) -> Result[EpubBook, String] {
  match open_with(a, false) {
    Ok(b) => Ok(b)
    Err(strict_err) =>
      match open_with(a, true) {
        Ok(b) => {
          // `warnings` 是 Array 字段，push 原地生效，无需可变绑定
          b.warnings.push(
            "严格模式失败（" +
            strict_err +
            "），已按宽松模式重新解析",
          )
          Ok(b)
        }
        Err(lenient_err) =>
          Err(
            "无法打开：严格模式 " +
            strict_err +
            "；宽松模式 " +
            lenient_err,
          )
      }
  }
}

///|
pub fn open_with(
  a : @container.Archive,
  lenient : Bool,
) -> Result[EpubBook, String] {
  let all_warnings : Array[String] = []
  // --- 1. container.xml ---
  let container_info = match @container.read(a, "META-INF/container.xml") {
    Err(_) => {
      if !lenient {
        return Err("缺少 META-INF/container.xml")
      }
      push_warning(
        all_warnings, "缺少 META-INF/container.xml，改为在归档内搜索 *.opf",
      )
      match find_opf_by_scan(a) {
        None => return Err("归档内找不到任何 .opf 文件")
        Some(p) => ContainerInfo::{ opf_path: p, version: "", warnings: [], }
      }
    }
    Ok(text) =>
      match parse_container(text, lenient) {
        Err(e) => return Err(e)
        Ok(ci) => {
          for w in ci.warnings {
            push_warning(all_warnings, w)
          }
          ci
        }
      }
  }
  // --- 2. OPF ---
  let opf_text = match @container.read(a, container_info.opf_path) {
    Err(e) => return Err(e)
    Ok(t) => t
  }
  let opf = match parse_opf(container_info.opf_path, opf_text, lenient) {
    Err(e) => return Err(e)
    Ok(o) => {
      for w in o.warnings {
        push_warning(all_warnings, w)
      }
      o
    }
  }
  // --- 3. nav（EPUB3） ---
  let nav_toc : Array[NavPoint] = []
  let nav_href = find_nav_item(opf.manifest)
  match nav_href {
    None =>
      if opf.package_version == "3.0" ||
        opf.package_version == "3.1" ||
        opf.package_version == "3.2" {
        push_warning(all_warnings, "EPUB3 文档缺少 properties=nav 的 item")
      }
    Some(item) =>
      match @container.read(a, item.path) {
        Err(e) => push_warning(all_warnings, "nav 文档读取失败：" + e)
        Ok(text) =>
          match parse_nav(item.path, text) {
            Err(e) => push_warning(all_warnings, e)
            Ok((points, ws)) => {
              for w in ws {
                push_warning(all_warnings, w)
              }
              for p in points {
                nav_toc.push(p)
              }
            }
          }
      }
  }
  // --- 4. NCX（EPUB2） ---
  let ncx_toc : Array[NavPoint] = []
  let ncx_item = find_ncx_item(opf.manifest)
  match ncx_item {
    None => ()
    Some(item) =>
      match @container.read(a, item.path) {
        Err(e) => push_warning(all_warnings, "NCX 文档读取失败：" + e)
        Ok(text) =>
          match parse_ncx(item.path, text) {
            Err(e) => push_warning(all_warnings, e)
            Ok((points, ws)) => {
              for w in ws {
                push_warning(all_warnings, w)
              }
              for p in points {
                ncx_toc.push(p)
              }
            }
          }
      }
  }
  if nav_toc.length() == 0 && ncx_toc.length() == 0 {
    push_warning(
      all_warnings, "既无 nav 也无 NCX，目录树为空（正文仍可阅读）",
    )
  }
  // --- 5. 加密声明 ---
  let enc = detect_encryption(a, container_info.opf_path)
  if enc.encrypted {
    push_warning(all_warnings, enc.message)
  }
  // --- 6. mimetype 一致性（规范硬性要求，读取侧只告警） ---
  if !@container.has(a, "mimetype") {
    push_warning(all_warnings, "归档缺少 mimetype 条目")
  } else if !@container.mimetype_is_first(a) {
    push_warning(
      all_warnings, "mimetype 不是第一个条目（违反 EPUB 规范，读取侧容忍）",
    )
  }
  Ok(EpubBook::{
    opf_path: container_info.opf_path,
    container_version: container_info.version,
    package_version: opf.package_version,
    unique_id: opf.unique_id,
    metadata: opf.metadata,
    manifest: opf.manifest,
    spine: opf.spine,
    guide: opf.guide,
    nav_toc,
    ncx_toc,
    encryption: enc,
    warnings: all_warnings,
    archive: a,
  })
}

///|
fn find_nav_item(manifest : Array[ManifestItem]) -> ManifestItem? {
  let mut found : ManifestItem? = None
  for m in manifest {
    if m.resolve_error.length() == 0 && has_prop(m, "nav") {
      found = Some(m)
      break
    }
  }
  found
}

///|
fn find_ncx_item(manifest : Array[ManifestItem]) -> ManifestItem? {
  let mut found : ManifestItem? = None
  for m in manifest {
    if m.resolve_error.length() == 0 &&
      m.media_type == "application/x-dtbncx+xml" {
      found = Some(m)
      break
    }
  }
  found
}

///|
/// 降级路径：没有 container.xml 时按扩展名找 OPF。
fn find_opf_by_scan(a : @container.Archive) -> String? {
  let mut found : String? = None
  for n in @container.names(a) {
    if @util.ends_with_ci(n, ".opf") {
      found = Some(n)
      break
    }
  }
  found
}

///|
/// 读取章节源码（里「这就是渲染层的输入」）。
pub fn read_resource(
  a : @container.Archive,
  path : String,
) -> Result[String, String] {
  @container.read(a, path)
}

///|
/// 按章节序号读取；序号越界返回带上下标的错误。
pub fn read_chapter(b : EpubBook, index : Int32) -> Result[String, String] {
  let paths = chapter_paths(b)
  if index < 0 || index >= paths.length() {
    return Err(
      "章节序号 " +
      index.to_string() +
      " 越界（共 " +
      paths.length().to_string() +
      " 章）",
    )
  }
  @container.read(b.archive, paths[index])
}

///|
/// 全部 CSS 源码，按 manifest 顺序。渲染层据此做级联。
pub fn read_all_css(b : EpubBook) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for p in css_paths(b) {
    match @container.read(b.archive, p) {
      Ok(text) => out.push((p, text))
      Err(_) => ()
    }
  }
  out
}

///|
/// 打开结果的完整报告，用于 `moon run` 与语料回归（）。
pub fn report(b : EpubBook) -> String {
  let lines : Array[String] = []
  lines.push(describe(b))
  if b.warnings.length() > 0 {
    lines.push("--- 告警 ---")
    for w in b.warnings {
      lines.push("  ! " + w)
    }
  }
  @util.join_nl(lines)
}
