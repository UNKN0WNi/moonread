/// EPUB 数据模型。
///
/// 依赖方向遵守 ：本包只 import L1（util）与同层的 container/resource/xml，
/// **不 import crater、不 import L4**。目录树在这里是「原始 NavPoint」，
/// 带层级的 UI 语义由 `src/toc` 负责转换。

///|
/// 一个 `dc:title` 及其语言标注。
///
/// EPUB 3.3「The dc:title element」：元素可重复，`xml:lang` 可选；
/// 文档顺序中的第一个是主标题。全部标题都要保留，不能被折叠成单个字符串。
#derive(Debug, Eq)
pub(all) struct TitleInfo {
  value : String
  /// `xml:lang`，缺省为空串（继承 `package/@xml:lang`）。
  lang : String
  /// `dc:title/@id`，供 `<meta refines="#id">` 关联。
  id : String
}

///|
/// 一条 `<meta refines="#id" property="..." scheme="..." xml:lang="...">`。
///
/// EPUB 3.3「The refines attribute」：修饰关系是合法的语义载体，
/// 例如 `role`、`alternate-script`、`file-as`、`identifier-type`。
#derive(Debug, Eq)
pub(all) struct RefineInfo {
  /// 被修饰元素的 id（去掉前导 `#`）。
  target : String
  property : String
  value : String
  scheme : String
  lang : String
}

///| Dublin Core 元数据。多值字段保留数组，因为 EPUB3 允许重复 `dc:` 元素。

///| 字段可变是为了让解析器按元素顺序增量填充（`parse_metadata`），

///|
/// 而不是攒齐十几个局部变量再一次性构造。
#derive(Debug, Eq)
pub(all) struct Metadata {
  mut title : String
  /// 全部 `dc:title`（保序），首个即 `title`。合法多语言/分部标题不再丢失。
  mut titles : Array[TitleInfo]
  /// 全部 `meta refines` 修饰（保序），供宿主取 alternate-script / file-as 等。
  mut refines : Array[RefineInfo]
  /// `(姓名, marcrel 角色)`；角色缺省为 `aut`。
  mut creators : Array[(String, String)]
  mut contributors : Array[String]
  mut language : String
  /// `(id, 值)`，来自 `dc:identifier`。
  mut identifiers : Array[(String, String)]
  /// 以下 Dublin Core 元素在 EPUB 3.3 中均为 Repeatable，
  /// 数组保序保留全部值；单数槽位只作为兼容旧 API 的「首值」。
  mut publishers : Array[String]
  mut dates : Array[String]
  mut descriptions : Array[String]
  mut sources : Array[String]
  mut types : Array[String]
  mut coverages : Array[String]
  mut relations : Array[String]
  mut formats : Array[String]
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
  /// 创作者偏好（§8.2/§8.3）：阅读系统可忽略，但语义应可查询。
  mut rendition_layout : String
  mut rendition_flow : String
}

///|
pub fn empty_metadata() -> Metadata {
  Metadata::{
    title: "",
    titles: [],
    refines: [],
    creators: [],
    contributors: [],
    language: "",
    identifiers: [],
    publishers: [],
    dates: [],
    descriptions: [],
    sources: [],
    types: [],
    coverages: [],
    relations: [],
    formats: [],
    publisher: "",
    date: "",
    description: "",
    rights: [],
    subjects: [],
    source: "",
    modified: "",
    cover_path: "",
    page_progression_direction: "",
    rendition_layout: "",
    rendition_flow: "",
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
/// 主标题：EPUB 3.3 规定文档顺序中的首个 `dc:title` 即主标题。
pub fn main_title(m : Metadata) -> String {
  if m.titles.length() > 0 {
    m.titles[0].value
  } else {
    m.title
  }
}

///|
/// 取某个 `<meta refines="#target" property="prop">` 的值；无匹配返回空串。
/// `target` 传 `dc:title` / `dc:creator` 的 `@id`（不含 `#`）。
pub fn refine(m : Metadata, target : String, property : String) -> String {
  for r in m.refines {
    if r.target == target && @util.ascii_lower(r.property) == property {
      return r.value
    }
  }
  ""
}

///|
/// 取某元素全部 refinements（同一 target + property 可重复，保序）。
pub fn refine_all(
  m : Metadata,
  target : String,
  property : String,
) -> Array[RefineInfo] {
  let out : Array[RefineInfo] = []
  for r in m.refines {
    if r.target == target && @util.ascii_lower(r.property) == property {
      out.push(r)
    }
  }
  out
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
  /// EPUB 3.3 nav 内容模型允许 `li` 首元素是 `span`（分组标题，无 href）。
  /// true 表示这是分组标签而非可跳转链接，`path` 通常为空。
  is_group : Bool
  /// HTML `hidden` 布尔属性：规范允许隐藏仅供机器处理的目录分支。
  hidden : Bool
}

///|
pub fn nav_point(label : String, path : String, fragment : String) -> NavPoint {
  NavPoint::{
    label,
    path,
    fragment,
    children: [],
    is_group: false,
    hidden: false,
  }
}

///|
/// 分组标题节点（EPUB3 nav 的 `span`）。
pub fn nav_group(label : String) -> NavPoint {
  NavPoint::{
    label,
    path: "",
    fragment: "",
    children: [],
    is_group: true,
    hidden: false,
  }
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
