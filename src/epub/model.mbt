/// EPUB 数据模型。
///
/// 依赖方向遵守 ：本包只 import L1（util）与同层的 container/resource/xml，
/// **不 import crater、不 import L4**。目录树在这里是「原始 NavPoint」，
/// 带层级的 UI 语义由 `src/toc` 负责转换。

///| Dublin Core 元数据。多值字段保留数组，因为 EPUB3 允许重复 `dc:` 元素。

///| 字段可变是为了让解析器按元素顺序增量填充（`parse_metadata`），

///|
/// 而不是攒齐十几个局部变量再一次性构造。
#derive(Debug, Eq)
pub(all) struct Metadata {
  mut title : String
  /// `(姓名, marcrel 角色)`；角色缺省为 `aut`。
  mut creators : Array[(String, String)]
  mut contributors : Array[String]
  mut language : String
  /// `(id, 值)`，来自 `dc:identifier`。
  mut identifiers : Array[(String, String)]
  mut publisher : String
  mut date : String
  mut description : String
  mut rights : Array[String]
  mut subjects : Array[String]
  mut source : String
  /// `meta[property=dcterms:modified]`，EPUB3 校验必填，缺失只告警。
  mut modified : String
  /// 封面图在归档内的规范路径；无法确定时为空串。
  mut cover_path : String
  mut page_progression_direction : String
}

///|
pub fn empty_metadata() -> Metadata {
  Metadata::{
    title: "",
    creators: [],
    contributors: [],
    language: "",
    identifiers: [],
    publisher: "",
    date: "",
    description: "",
    rights: [],
    subjects: [],
    source: "",
    modified: "",
    cover_path: "",
    page_progression_direction: "",
  }
}

///|
pub fn primary_creator(m : Metadata) -> String {
  if m.creators.length() > 0 {
    m.creators[0].0
  } else {
    ""
  }
}

///|
/// `manifest/item`。`path` 是已规范化的归档内路径（「章节内所有资源可定位」）。
#derive(Debug, Eq)
pub(all) struct ManifestItem {
  id : String
  href : String
  path : String
  media_type : String
  properties : Array[String]
  fallbacks : Array[String]
  /// `href` 解析失败时的原因；为空表示解析成功。
  resolve_error : String
}

///|
pub fn has_prop(item : ManifestItem, want : String) -> Bool {
  for p in item.properties {
    if p == want {
      return true
    }
  }
  false
}

///| `spine/itemref` 解析结果。`resolved` 为 false 表示 `idref` 指向不存在的

///|
/// `item id`（真实语料常见，接口要求降级可用），此时 `path` 为空串。
#derive(Debug, Eq)
pub(all) struct SpineItem {
  idref : String
  linear : Bool
  path : String
  media_type : String
  resolved : Bool
}

///| 目录节点（nav.xhtml 的 `epub:type=toc` 子树，或 NCX 的 `navMap`）。

///|
/// 递归结构；`children` 保序即目录顺序。
#derive(Debug, Eq)
pub(all) struct NavPoint {
  label : String
  path : String
  fragment : String
  children : Array[NavPoint]
}

///|
pub fn nav_point(label : String, path : String, fragment : String) -> NavPoint {
  NavPoint::{ label, path, fragment, children: [], }
}

///|
/// 目录节点总数（含自身），供语料回归断言使用。
pub fn count_nav_points(points : Array[NavPoint]) -> Int32 {
  let mut n = 0
  for p in points {
    n = n + 1 + count_nav_points(p.children)
  }
  n
}

///|
/// `guide/reference`（EPUB2 遗留，EPUB3 用 `properties` 取代，但仍需读）。
#derive(Debug, Eq)
pub(all) struct GuideRef {
  typ : String
  title : String
  path : String
}

///|
/// 加密声明（「仅检测并给出清晰提示，不解密」）。
#derive(Debug, Eq)
pub(all) struct EncryptionInfo {
  encrypted : Bool
  /// 逗号分隔的 scheme URI，例如 `http://www.adobe.com/xml/schemas/epub-drm`。
  schemes : String
  /// 人可读结论，直接展示给用户。
  message : String
}

///|
pub fn no_encryption() -> EncryptionInfo {
  EncryptionInfo::{ encrypted: false, schemes: "", message: "未声明加密", }
}

///|
/// 一本书的完整解析结果。
#derive(Debug, Eq)
pub(all) struct EpubBook {
  /// container.xml 里 rootfile 的 full-path，已规范化。
  opf_path : String
  container_version : String
  package_version : String
  unique_id : String
  metadata : Metadata
  manifest : Array[ManifestItem]
  spine : Array[SpineItem]
  guide : Array[GuideRef]
  nav_toc : Array[NavPoint]
  ncx_toc : Array[NavPoint]
  encryption : EncryptionInfo
  /// 降级与脏数据告警；顺序即产生顺序。
  warnings : Array[String]
  archive : @container.Archive
}

///| 章节列表：spine 中 `linear=true` 且媒体类型是 markup 的条目路径。

///|
/// 这正是数据流里「章节 XHTML」的来源。
pub fn chapter_paths(b : EpubBook) -> Array[String] {
  let out : Array[String] = []
  for s in b.spine {
    if s.resolved && s.linear && @resource.is_markup_media(s.media_type) {
      out.push(s.path)
    }
  }
  out
}

///|
/// 全部章节（含 non-linear），供「按 spine 顺序遍历」的实现使用。
pub fn all_spine_paths(b : EpubBook) -> Array[String] {
  let out : Array[String] = []
  for s in b.spine {
    if s.resolved {
      out.push(s.path)
    }
  }
  out
}

///|
pub fn css_paths(b : EpubBook) -> Array[String] {
  let out : Array[String] = []
  for m in b.manifest {
    if m.resolve_error.length() == 0 && @resource.is_css_media(m.media_type) {
      out.push(m.path)
    }
  }
  out
}

///|
pub fn image_paths(b : EpubBook) -> Array[String] {
  let out : Array[String] = []
  for m in b.manifest {
    if m.resolve_error.length() == 0 && @resource.is_image_media(m.media_type) {
      out.push(m.path)
    }
  }
  out
}

///|
pub fn font_paths(b : EpubBook) -> Array[String] {
  let out : Array[String] = []
  for m in b.manifest {
    if m.resolve_error.length() == 0 && @resource.is_font_media(m.media_type) {
      out.push(m.path)
    }
  }
  out
}

///|
pub fn find_item_by_id(b : EpubBook, id : String) -> ManifestItem? {
  let mut found : ManifestItem? = None
  for m in b.manifest {
    if m.id == id {
      found = Some(m)
      break
    }
  }
  found
}

///|
pub fn find_item_by_path(b : EpubBook, path : String) -> ManifestItem? {
  let mut found : ManifestItem? = None
  for m in b.manifest {
    if m.path == path {
      found = Some(m)
      break
    }
  }
  found
}

///|
/// nav 文档路径（EPUB3 `properties="nav"`）。
pub fn nav_path(b : EpubBook) -> String {
  let mut out = ""
  for m in b.manifest {
    if has_prop(m, "nav") {
      out = m.path
      break
    }
  }
  out
}

///|
/// NCX 文档路径（EPUB2：spine 上 `linear="no"` 且媒体类型为 ncx，或 manifest 里唯一 ncx）。
pub fn ncx_path(b : EpubBook) -> String {
  let mut out = ""
  for m in b.manifest {
    if m.media_type == "application/x-dtbncx+xml" {
      out = m.path
      break
    }
  }
  out
}

///|
/// 展示用摘要，供 `moon run` 与嵌入示例直接打印。
pub fn describe(b : EpubBook) -> String {
  let lines : Array[String] = []
  lines.push("标题 = " + or_placeholder(b.metadata.title))
  lines.push("作者 = " + or_placeholder(primary_creator(b.metadata)))
  lines.push("语言 = " + or_placeholder(b.metadata.language))
  lines.push(
    "OPF = " +
    b.opf_path +
    "（package version " +
    or_placeholder(b.package_version) +
    "）",
  )
  lines.push("manifest 条目 = " + b.manifest.length().to_string())
  lines.push("spine 条目 = " + b.spine.length().to_string())
  lines.push("章节数 = " + chapter_paths(b).length().to_string())
  lines.push("nav 目录项 = " + count_nav_points(b.nav_toc).to_string())
  lines.push("ncx 目录项 = " + count_nav_points(b.ncx_toc).to_string())
  lines.push("加密 = " + b.encryption.message)
  lines.push("告警 = " + b.warnings.length().to_string())
  @util.join_nl(lines)
}

///|
fn or_placeholder(s : String) -> String {
  if s.length() == 0 {
    "<未提供>"
  } else {
    s
  }
}
