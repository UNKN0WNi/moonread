/// EPUB 结构解析：container.xml / OPF / nav.xhtml / NCX / 加密声明。
///
/// 容错策略（出口条件「降级可用，不 panic」）：
/// - 一切解析函数返回 `Result`，错误信息带**中文原因 + 定位线索**；
/// - 可降级的问题（缺 nav、缺 spine、重复 id、非法 XML）走 `warnings`，
///   不阻断打开；只有「根本没有 OPF」这类致命问题才返回 `Err`。
/// - 已知风险 明确写了「真实 EPUB 语料比预期脏（概率：高）」，
///   所以这里的默认态度是**尽量解析出来并如实报告**，而不是严格拒绝。

///|
/// container.xml 解析结果。
#derive(Debug, Eq)
pub(all) struct ContainerInfo {
  /// rootfile 的 full-path，已规范化为归档内路径。
  opf_path : String
  version : String
  warnings : Array[String]
}

///|
/// OPF 解析结果。
#derive(Debug, Eq)
pub(all) struct OpfInfo {
  metadata : Metadata
  manifest : Array[ManifestItem]
  spine : Array[SpineItem]
  guide : Array[GuideRef]
  /// EPUB2/OPF2 的 `spine@toc`：指定 NCX 的 manifest id。
  /// 多份 NCX 时不能靠「第一份」猜，必须按这个 id 选。
  ncx_id : String
  package_version : String
  unique_id : String
  warnings : Array[String]
}

// ---------------- container.xml ----------------

///| 解析 container.xml。规范要求恰好一个 `application/oebps-package+xml` 的

///|
/// rootfile；多个时取第一个并告警。
pub fn parse_container(
  text : String,
  lenient : Bool,
) -> Result[ContainerInfo, String] {
  let opts = if lenient {
    @xml.lenient_options()
  } else {
    @xml.strict_options()
  }
  match @xml.parse_document_with(text, opts) {
    Err(e) => Err("container.xml 解析失败：" + e)
    Ok(root) => {
      if !@xml.tag_is(root, "container") {
        return Err(
          "container.xml 根元素应为 container，实际是 '" +
          root.tag +
          "'",
        )
      }
      let warnings : Array[String] = []
      let files : Array[String] = []
      let mediatypes : Array[String] = []
      for rf in collect_rootfiles(root) {
        files.push(normalize_full_path(@xml.attr_or_empty(rf, "full-path")))
        mediatypes.push(lower_or_empty(@xml.attr_ci(rf, "media-type")))
      }
      let mut chosen = -1
      let mut i = 0
      while i < files.length() {
        if mediatypes[i] == "application/oebps-package+xml" {
          chosen = i
          break
        }
        i = i + 1
      }
      if chosen < 0 {
        if files.length() > 0 {
          chosen = 0
          warnings.push(
            "rootfile 的 media-type 不是 application/oebps-package+xml，按第一个条目处理",
          )
        } else {
          return Err("container.xml 的 rootfiles 内没有任何 rootfile")
        }
      }
      if files.length() > 1 {
        warnings.push(
          "container.xml 含 " +
          files.length().to_string() +
          " 个 rootfile，取第一个",
        )
      }
      let path = files[chosen]
      if path.length() == 0 {
        return Err("container.xml 的 rootfile 缺少 full-path")
      }
      Ok(ContainerInfo::{
        opf_path: path,
        version: lower_or_empty(@xml.attr_ci(root, "version")),
        warnings,
      })
    }
  }
}

///|
fn collect_rootfiles(root : @xml.Element) -> Array[@xml.Element] {
  let out : Array[@xml.Element] = []
  for d in @xml.descendants(root) {
    if @xml.tag_is(d, "rootfile") {
      out.push(d)
    }
  }
  out
}

///| `full-path` 允许写成 `OEBPS/content.opf`，脏语料里也见过 `OEBPS\content.opf`

///|
/// 与 `./OEBPS/content.opf`。统一规范化，并在越出根时截断。
fn normalize_full_path(raw : String) -> String {
  let swapped = @util.replace_all(raw, "\\", "/")
  let trimmed = @util.trim(swapped)
  let no_lead = if @util.starts_with(trimmed, "/") {
    @util.slice_string(trimmed, 1, @util.to_chars(trimmed).length())
  } else {
    trimmed
  }
  @util.path_normalize("", no_lead)
}

// ---------------- OPF ----------------

///|
pub fn parse_opf(
  opf_path : String,
  text : String,
  lenient : Bool,
) -> Result[OpfInfo, String] {
  let opts = if lenient {
    @xml.lenient_options()
  } else {
    @xml.strict_options()
  }
  match @xml.parse_document_with(text, opts) {
    Err(e) => Err("OPF 解析失败：" + e)
    Ok(root) => {
      if !@xml.tag_is(root, "package") {
        return Err("OPF 根元素应为 package，实际是 '" + root.tag + "'")
      }
      let warnings : Array[String] = []
      let unique_id = lower_attr_to_raw(
        @xml.get_attr(root, "unique-identifier"),
      )
      let package_version = lower_attr_to_raw(@xml.get_attr(root, "version"))
      let metadata_el = match @xml.find_child(root, "metadata") {
        None => {
          warnings.push(
            "OPF 缺少 metadata 元素，元数据全部按空处理",
          )
          @xml.Element::{ tag: "metadata", attrs: [], children: [], }
        }
        Some(m) => m
      }
      let manifest_el = match @xml.find_child(root, "manifest") {
        None => {
          warnings.push("OPF 缺少 manifest 元素")
          @xml.Element::{ tag: "manifest", attrs: [], children: [], }
        }
        Some(m) => m
      }
      let spine_el = match @xml.find_child(root, "spine") {
        None => {
          warnings.push("OPF 缺少 spine 元素，章节顺序为空")
          @xml.Element::{ tag: "spine", attrs: [], children: [], }
        }
        Some(s) => s
      }
      // §5.3.7：`package/@xml:lang` 是未标注元素的默认语言，
      // 而不是 `metadata/@xml:lang`。上一版读错元素，导致合法输入丢语言。
      let default_lang = @util.trim(@xml.attr_or_empty(root, "lang"))
      let md = parse_metadata(
        opf_path, metadata_el, manifest_el, unique_id, default_lang, warnings,
      )
      let manifest = parse_manifest(opf_path, manifest_el, warnings)
      let spine = parse_spine(spine_el, manifest, warnings)
      md.page_progression_direction = spine_page_direction(spine_el)
      let guide = parse_guide(opf_path, root, warnings)
      Ok(OpfInfo::{
        metadata: md,
        manifest,
        spine,
        guide,
        ncx_id: lower_attr_to_raw(@xml.get_attr(spine_el, "toc")),
        package_version,
        unique_id,
        warnings,
      })
    }
  }
}

///|
fn lower_attr_to_raw(v : String?) -> String {
  match v {
    Some(s) => s
    None => ""
  }
}

///|
fn lower_or_empty(v : String?) -> String {
  match v {
    Some(s) => @util.ascii_lower(s)
    None => ""
  }
}

///|
fn push_warning(warnings : Array[String], msg : String) -> Unit {
  warnings.push(msg)
}

///|
/// §D.3.10：role 的词汇表基于 MARC relators。
/// 自定义 scheme 的 role 不能覆盖作者角色，否则会给出错误语义。
fn refines_role(md : Metadata, target : String) -> String {
  for r in md.refines {
    if r.target == target && r.property == "role" && r.scheme == "marc:relators" {
      return @util.ascii_lower(r.value)
    }
  }
  ""
}

///|
fn parse_metadata(
  opf_path : String,
  el : @xml.Element,
  manifest_el : @xml.Element,
  unique_id : String,
  default_lang : String,
  warnings : Array[String],
) -> Metadata {
  let md = empty_metadata()
  let cover_id : Array[String] = []
  // 先收集 refines：EPUB 3.3 允许 <meta refines> 出现在被修饰元素之前或之后，
  // 因此必须先把修饰关系建好，再解析 dc: 元素时回填（如 creator 的 role）。
  for c in @xml.child_elements(el) {
    if @util.ascii_lower(@xml.local_name(c.tag)) != "meta" {
      continue
    }
    let ref_raw = @util.trim(@xml.attr_or_empty(c, "refines"))
    if ref_raw.length() == 0 {
      continue
    }
    let target = if @util.starts_with(ref_raw, "#") {
      @util.slice_string(ref_raw, 1, @util.to_chars(ref_raw).length())
    } else {
      ref_raw
    }
    md.refines.push(RefineInfo::{
      target,
      property: @util.ascii_lower(@xml.attr_or_empty(c, "property")),
      value: @util.trim(@xml.text_content(c)),
      scheme: @util.ascii_lower(@xml.attr_or_empty(c, "scheme")),
      lang: @util.trim(@xml.attr_or_empty(c, "lang")),
    })
  }
  // `default_lang` 由 parse_opf 从 package/@xml:lang 取得（见 §5.3.7）。
  for c in @xml.child_elements(el) {
    let name = @util.ascii_lower(@xml.local_name(c.tag))
    if name == "title" {
      let value = @util.trim(@xml.text_content(c))
      let lang = @util.trim(@xml.attr_or_empty(c, "lang"))
      md.titles.push(TitleInfo::{
        value,
        lang: if lang.length() == 0 {
          default_lang
        } else {
          lang
        },
        id: @util.trim(@xml.attr_or_empty(c, "id")),
      })
      // 规范：文档顺序首个 dc:title 就是主标题，即使其文本为空。
      // 旧实现取首个非空，会把空标题悄悄换成第二标题。
      if md.titles.length() == 1 {
        md.title = value
      }
    } else if name == "creator" {
      let cname = @util.trim(@xml.text_content(c))
      if cname.length() > 0 {
        let cid = @util.trim(@xml.attr_or_empty(c, "id"))
        // EPUB2 用 opf:role 属性；EPUB3 用 <meta refines="#id" property="role">。
        // 后者优先，才不会把插画师/译者误当作者。
        let inline_role = @util.ascii_lower(@xml.attr_or_empty(c, "role"))
        let refined_role = if cid.length() == 0 {
          ""
        } else {
          refines_role(md, cid)
        }
        let r = if refined_role.length() > 0 {
          refined_role
        } else if inline_role.length() > 0 {
          inline_role
        } else {
          "aut"
        }
        // EPUB2 遗留 `opf:file-as`；EPUB3 的 <meta refines> 优先。
        if cid.length() > 0 && refine(md, cid, "file-as").length() == 0 {
          match @xml.attr_ci(c, "file-as") {
            Some(file_as) =>
              if @util.trim(file_as).length() > 0 {
                md.refines.push(RefineInfo::{
                  target: cid,
                  property: "file-as",
                  value: @util.trim(file_as),
                  scheme: "",
                  lang: "",
                })
              }
            None => ()
          }
        }
        md.creators.push((cname, r))
      }
    } else if name == "contributor" {
      let v = @util.trim(@xml.text_content(c))
      if v.length() > 0 {
        md.contributors.push(v)
      }
    } else if name == "language" && md.language.length() == 0 {
      md.language = @util.trim(@xml.text_content(c))
    } else if name == "identifier" {
      let v = @xml.text_content(c)
      if v.length() > 0 {
        md.identifiers.push((lower_attr_to_raw(@xml.attr_ci(c, "id")), v))
      }
    } else if name == "publisher" {
      let v = @util.trim(@xml.text_content(c))
      md.publishers.push(v)
      if md.publisher.length() == 0 {
        md.publisher = v
      }
    } else if name == "date" {
      let v = @util.trim(@xml.text_content(c))
      md.dates.push(v)
      if md.date.length() == 0 {
        md.date = v
      }
    } else if name == "description" {
      let v = @util.trim(@xml.text_content(c))
      md.descriptions.push(v)
      if md.description.length() == 0 {
        md.description = v
      }
    } else if name == "source" {
      let v = @util.trim(@xml.text_content(c))
      md.sources.push(v)
      if md.source.length() == 0 {
        md.source = v
      }
    } else if name == "type" {
      md.types.push(@util.trim(@xml.text_content(c)))
    } else if name == "coverage" {
      md.coverages.push(@util.trim(@xml.text_content(c)))
    } else if name == "relation" {
      md.relations.push(@util.trim(@xml.text_content(c)))
    } else if name == "format" {
      md.formats.push(@util.trim(@xml.text_content(c)))
    } else if name == "rights" {
      let v = @util.trim(@xml.text_content(c))
      if v.length() > 0 {
        md.rights.push(v)
      }
    } else if name == "subject" {
      let v = @util.trim(@xml.text_content(c))
      if v.length() > 0 {
        md.subjects.push(v)
      }
    } else if name == "meta" {
      let prop = @util.ascii_lower(@xml.attr_or_empty(c, "property"))
      let mname = @util.ascii_lower(@xml.attr_or_empty(c, "name"))
      let body = @util.trim(@xml.text_content(c))
      if prop == "dcterms:modified" && md.modified.length() == 0 {
        md.modified = body
      } else if mname == "cover" {
        // EPUB2/OPF2 的遗留写法是 `<meta name="cover" content="ITEM-ID"/>`；
        // 内容不是封面 id，读元素文本会取到空串并让第一张图冒充封面。
        match @xml.attr_ci(c, "content") {
          Some(id) => cover_id.push(@util.trim(id))
          None => ()
        }
      } else if prop == "rendition:layout" && md.rendition_layout.length() == 0 {
        md.rendition_layout = body
      } else if prop == "rendition:flow" && md.rendition_flow.length() == 0 {
        md.rendition_flow = body
      }
    }
  }
  if md.title.length() == 0 {
    push_warning(warnings, "元数据缺少 dc:title")
  }
  if md.language.length() == 0 {
    push_warning(warnings, "元数据缺少 dc:language")
  }
  if md.identifiers.length() == 0 {
    push_warning(warnings, "元数据缺少 dc:identifier")
  } else if unique_id.length() > 0 {
    let mut hit = false
    for kv in md.identifiers {
      if kv.0 == unique_id {
        hit = true
      }
    }
    if !hit {
      push_warning(
        warnings,
        "package@unique-identifier '" +
        unique_id +
        "' 在 dc:identifier 中不存在",
      )
    }
  }
  if md.modified.length() == 0 {
    push_warning(
      warnings, "EPUB3 要求 dcterms:modified，缺失（按 EPUB2 处理）",
    )
  }
  md.cover_path = resolve_cover(opf_path, cover_id, manifest_el, warnings)
  md
}

///|
fn resolve_cover(
  opf_path : String,
  cover_id : Array[String],
  manifest_el : @xml.Element,
  warnings : Array[String],
) -> String {
  // 1) `<meta name="cover" content="img-id"/>`
  if cover_id.length() > 0 {
    for item in @xml.child_elements(manifest_el) {
      if @xml.attr_ci(item, "id") == Some(cover_id[0]) {
        match @xml.attr_ci(item, "href") {
          Some(h) => {
            let r = @resource.resolve(opf_path, h)
            return ref_to_path(r, "封面", warnings)
          }
          None => ()
        }
      }
    }
    push_warning(
      warnings,
      "meta name=cover 指向不存在的 item id：'" + cover_id[0] + "'",
    )
  }
  // 2) `properties="cover-image"`
  for item in @xml.child_elements(manifest_el) {
    let props = lower_attr_to_raw(@xml.attr_ci(item, "properties"))
    if @resource.has_property(props, "cover-image") {
      match @xml.attr_ci(item, "href") {
        Some(h) => {
          let r = @resource.resolve(opf_path, h)
          return ref_to_path(r, "封面", warnings)
        }
        None => ()
      }
    }
  }
  // 3) 兜底：第一个 image 媒体类型条目
  for item in @xml.child_elements(manifest_el) {
    let mt = lower_attr_to_raw(@xml.attr_ci(item, "media-type"))
    if @resource.is_image_media(mt) {
      match @xml.attr_ci(item, "href") {
        Some(h) => {
          let r = @resource.resolve(opf_path, h)
          return ref_to_path(r, "封面", warnings)
        }
        None => ()
      }
    }
  }
  ""
}

///| `ResourceRef` 到路径字符串：解析失败时返回空串并告警。

///| `label` 只用于拼告警文本（例如「封面」或「manifest item 'ch1'」），

///|
/// 保证告警能定位到具体引用（「畸形 EPUB 容错」要求可诊断）。
fn ref_to_path(
  r : @resource.ResourceRef,
  label : String,
  warnings : Array[String],
) -> String {
  match r {
    @resource.InArchive(p) => p
    @resource.Inline(_, _, _) => {
      push_warning(
        warnings,
        label + " 是 data: 内嵌资源，无归档路径",
      )
      ""
    }
    @resource.Remote(sc, h, _) => {
      push_warning(
        warnings,
        label + " 是外部引用（" + sc + " " + h + "），离线不可用",
      )
      ""
    }
    @resource.Invalid(reason) => {
      push_warning(warnings, label + " 引用无法解析：" + reason)
      ""
    }
  }
}

///|
fn parse_manifest(
  opf_path : String,
  el : @xml.Element,
  warnings : Array[String],
) -> Array[ManifestItem] {
  let out : Array[ManifestItem] = []
  let seen_ids : Array[String] = []
  for c in @xml.child_elements(el) {
    if !@xml.tag_is(c, "item") {
      continue
    }
    let id = lower_attr_to_raw(@xml.attr_ci(c, "id"))
    let href = lower_attr_to_raw(@xml.attr_ci(c, "href"))
    let mt = @util.ascii_lower(@xml.attr_or_empty(c, "media-type"))
    let props_raw = lower_attr_to_raw(@xml.attr_ci(c, "properties"))
    let fb_raw = lower_attr_to_raw(@xml.attr_ci(c, "fallback"))
    if id.length() == 0 {
      push_warning(
        warnings,
        "manifest item 缺少 id，已跳过（href='" + href + "'）",
      )
      continue
    }
    let mut dup = false
    for s in seen_ids {
      if s == id {
        dup = true
      }
    }
    if dup {
      push_warning(
        warnings,
        "manifest 存在重复 id '" + id + "'，保留首个",
      )
      continue
    }
    seen_ids.push(id)
    if href.length() == 0 {
      push_warning(warnings, "manifest item '" + id + "' 缺少 href")
    }
    let path_ref = @resource.resolve(opf_path, href)
    let path = ref_to_path(path_ref, "manifest item '" + id + "'", warnings)
    let resolve_error = match path_ref {
      @resource.Invalid(reason) => reason
      _ => ""
    }
    let properties : Array[String] = []
    for p in @util.split_char(props_raw, ' ') {
      if p.length() > 0 {
        properties.push(p)
      }
    }
    let fallbacks : Array[String] = []
    for f in @util.split_char(fb_raw, ' ') {
      if f.length() > 0 {
        fallbacks.push(f)
      }
    }
    out.push(ManifestItem::{
      id,
      href,
      path,
      media_type: mt,
      properties,
      fallbacks,
      resolve_error,
    })
  }
  out
}

///|
fn spine_page_direction(el : @xml.Element) -> String {
  lower_attr_to_raw(@xml.get_attr(el, "page-progression-direction"))
}

///|
fn parse_spine(
  el : @xml.Element,
  manifest : Array[ManifestItem],
  warnings : Array[String],
) -> Array[SpineItem] {
  let out : Array[SpineItem] = []
  for c in @xml.child_elements(el) {
    if !@xml.tag_is(c, "itemref") {
      continue
    }
    let idref = lower_attr_to_raw(@xml.attr_ci(c, "idref"))
    let linear_raw = @util.ascii_lower(@xml.attr_or_empty(c, "linear"))
    let linear = linear_raw != "no"
    if idref.length() == 0 {
      push_warning(warnings, "spine itemref 缺少 idref，已跳过")
      continue
    }
    let mut item : ManifestItem? = None
    for m in manifest {
      if m.id == idref {
        item = Some(m)
        break
      }
    }
    match item {
      None => {
        push_warning(
          warnings,
          "spine idref '" + idref + "' 在 manifest 中不存在，降级保留",
        )
        out.push(SpineItem::{
          idref,
          linear,
          path: "",
          media_type: "",
          resolved: false,
        })
      }
      Some(it) => {
        // §3.5.1 / §5.7.2：外国内容文档必须通过 fallback 链找到
        // 可渲染的 EPUB 内容文档；否则整章会静默从阅读顺序消失。
        let content = resolve_spine_content(idref, it, manifest, warnings)
        out.push(SpineItem::{
          idref,
          linear,
          path: content.path,
          media_type: content.media_type,
          resolved: true,
        })
      }
    }
  }
  if out.length() == 0 {
    push_warning(warnings, "spine 为空，无法确定阅读顺序")
  }
  out
}

///|
fn find_manifest_item(
  manifest : Array[ManifestItem],
  id : String,
) -> ManifestItem? {
  for m in manifest {
    if m.id == id {
      return Some(m)
    }
  }
  None
}

///|
fn id_seen(ids : Array[String], id : String) -> Bool {
  for x in ids {
    if x == id {
      return true
    }
  }
  false
}

///|
/// 沿 manifest 的 `fallback` 链找到第一个 EPUB 内容文档。
/// 成功与失败都产生告警：合法 fallback 要让上层知道发生了替换，
/// 无可用 fallback 则不能让条目静默消失。
fn resolve_spine_content(
  idref : String,
  item : ManifestItem,
  manifest : Array[ManifestItem],
  warnings : Array[String],
) -> ManifestItem {
  if @resource.is_markup_media(item.media_type) {
    return item
  }
  let visited : Array[String] = [item.id]
  let mut cur = item
  while !@resource.is_markup_media(cur.media_type) {
    let mut next : ManifestItem? = None
    for fid in cur.fallbacks {
      if !id_seen(visited, fid) {
        visited.push(fid)
        match find_manifest_item(manifest, fid) {
          Some(m) => {
            next = Some(m)
            break
          }
          None => ()
        }
      }
    }
    match next {
      None => {
        push_warning(
          warnings,
          "spine idref '" +
          idref +
          "' 的媒体类型 '" +
          cur.media_type +
          "' 无可用 fallback，未进入章节列表",
        )
        return cur
      }
      Some(m) => cur = m
    }
  }
  push_warning(
    warnings,
    "spine idref '" +
    idref +
    "' 的媒体类型 '" +
    item.media_type +
    "' 不是内容文档，已按 fallback '" +
    cur.id +
    "' 加入阅读顺序",
  )
  cur
}

///|
pub fn parse_guide(
  opf_path : String,
  root : @xml.Element,
  warnings : Array[String],
) -> Array[GuideRef] {
  let out : Array[GuideRef] = []
  match @xml.find_child(root, "guide") {
    None => ()
    Some(g) =>
      for c in @xml.child_elements(g) {
        if !@xml.tag_is(c, "reference") {
          continue
        }
        let typ = lower_attr_to_raw(@xml.attr_ci(c, "type"))
        let title = lower_attr_to_raw(@xml.attr_ci(c, "title"))
        let href = lower_attr_to_raw(@xml.attr_ci(c, "href"))
        if typ.length() == 0 {
          push_warning(warnings, "guide reference 缺少 type，已跳过")
          continue
        }
        // guide/reference/@href 与 manifest/@href 一样相对 OPF 解析，
        // 原样存字符串会让宿主定位不到归档内资源。
        let path = ref_to_path(
          @resource.resolve(opf_path, href),
          "guide reference '" + typ + "'",
          warnings,
        )
        out.push(GuideRef::{ typ, title, path, })
      }
  }
  out
}

// ---------------- nav.xhtml（EPUB3） ----------------

///|
/// EPUB 3.3 §C.2：OPS 语义词汇表的命名空间 URI。
const OPS_NS : String = "http://www.idpf.org/2007/ops"

///|
/// 命名空间前缀只是 URI 的绑定细节，不能写死 `epub:`。
/// 沿 DOM 向下遍历时累积当前作用域里绑定到 OPS 命名空间的前缀；
/// 默认 `epub` 始终保留，兼容省略 xmlns 声明的历史语料。
/// 无前缀的 `type` 永不接受，避免把普通 HTML `type="toc"` 误判为导航语义。
fn with_ops_prefixes(
  el : @xml.Element,
  active : Array[String],
) -> Array[String] {
  let out : Array[String] = []
  for p in active {
    out.push(p)
  }
  for kv in el.attrs {
    let name = @util.ascii_lower(kv.0)
    if @util.starts_with(name, "xmlns:") {
      let prefix = @util.slice_string(name, 6, @util.to_chars(name).length())
      if @util.trim(@util.ascii_lower(kv.1)) == OPS_NS &&
        !array_has(out, prefix) {
        out.push(prefix)
      }
    }
  }
  out
}

///|
fn array_has(xs : Array[String], want : String) -> Bool {
  for x in xs {
    if x == want {
      return true
    }
  }
  false
}

///|
/// 收集所有 nav 及其所在作用域的 OPS 前缀（文档序）。
fn collect_navs(
  el : @xml.Element,
  active : Array[String],
  out : Array[(@xml.Element, Array[String])],
) -> Unit {
  let next = with_ops_prefixes(el, active)
  if @xml.tag_is(el, "nav") {
    out.push((el, next))
  }
  for c in @xml.child_elements(el) {
    collect_navs(c, next, out)
  }
}

///|
/// `epub:type` 是空白分隔的属性值列表（EPUB 3.3 §C.2）。
/// 按「绑定到 OPS 命名空间的前缀 + local name `type`」判定，
/// 因此 `epub:type` 与 `o:type`（`xmlns:o=OPS_NS`）等价，普通 `type` 不算。
fn has_epub_type(
  el : @xml.Element,
  want : String,
  prefixes : Array[String],
) -> Bool {
  for kv in el.attrs {
    let name = @util.ascii_lower(kv.0)
    for p in prefixes {
      if name == p + ":type" {
        let normalized = @util.replace_all(
          @util.replace_all(@util.replace_all(kv.1, "\t", " "), "\n", " "),
          "\r",
          " ",
        )
        for token in @util.split_char(normalized, ' ') {
          if @util.ascii_lower(token) == want {
            return true
          }
        }
      }
    }
  }
  false
}

///|
/// 解析 EPUB3 nav 文档。找不到 toc nav 时返回空数组并告警，由调用方回退 NCX。
pub fn parse_nav(
  nav_doc_path : String,
  text : String,
) -> Result[(Array[NavPoint], Array[String]), String] {
  let warnings : Array[String] = []
  match @xml.parse_document_lenient(text) {
    Err(e) => Err("nav 文档解析失败：" + e)
    Ok(root) => {
      let mut toc_nav : @xml.Element? = None
      let toc_candidates : Array[@xml.Element] = []
      let navs : Array[(@xml.Element, Array[String])] = []
      collect_navs(root, ["epub"], navs)
      for (n, prefixes) in navs {
        // §C.2：`epub:type` 是空白分隔的属性值列表，`toc landmarks`
        // 完全合法；必须按 token 判定，且不能把无前缀的 type 当 epub:type。
        // 前缀按 xmlns 绑定解析，别的前缀（如 o:）绑定到 OPS URI 时同样有效。
        if has_epub_type(n, "toc", prefixes) {
          toc_nav = Some(n)
        } else {
          toc_candidates.push(n)
        }
      }
      if toc_nav == None && toc_candidates.length() > 0 {
        toc_nav = Some(toc_candidates[0])
        push_warning(
          warnings, "nav 文档没有 epub:type=toc，使用第一个 nav 元素",
        )
      }
      match toc_nav {
        None => {
          push_warning(warnings, "nav 文档内没有任何 nav 元素")
          Ok(([], warnings))
        }
        Some(nav) => {
          let ol = find_first_list(nav)
          match ol {
            None => {
              push_warning(warnings, "nav/toc 内没有有序列表")
              Ok(([], warnings))
            }
            Some(list) =>
              Ok((parse_nav_list(nav_doc_path, list, warnings), warnings))
          }
        }
      }
    }
  }
}

///|
fn find_first_list(nav : @xml.Element) -> @xml.Element? {
  let mut found : @xml.Element? = None
  for c in @xml.child_elements(nav) {
    if @xml.tag_is(c, "ol") || @xml.tag_is(c, "ul") {
      found = Some(c)
      break
    }
  }
  found
}

///|
fn parse_nav_list(
  base : String,
  list : @xml.Element,
  warnings : Array[String],
) -> Array[NavPoint] {
  let out : Array[NavPoint] = []
  for li in @xml.child_elements(list) {
    if !@xml.tag_is(li, "li") {
      continue
    }
    // HTML hidden 是布尔属性：出现即为真，包括 `hidden` / `hidden=""` /
    // `hidden="hidden"`。EPUB 3.3 允许用它把仅供机器处理的分支藏起来。
    let is_hidden = @xml.get_attr(li, "hidden") != None
    // 内容模型：li 的首个子元素是 (span|a)[exactly 1]，之后可选一个 ol。
    // span 是分组标题（无 href），不能像旧实现那样丢掉它的文字。
    let mut point : NavPoint? = None
    for child in @xml.child_elements(li) {
      if point != None {
        break
      }
      if @xml.tag_is(child, "a") {
        let href = lower_attr_to_raw(@xml.attr_ci(child, "href"))
        let label = @util.trim(@xml.text_content(child))
        let r = @resource.resolve(base, href)
        let path = ref_to_path(r, "nav 项 '" + label + "'", warnings)
        point = Some(NavPoint::{
          label,
          path,
          fragment: @resource.fragment(href),
          children: [],
          is_group: false,
          hidden: is_hidden,
        })
      } else if @xml.tag_is(child, "span") {
        // span 分组标题：文字保留为 label，path 为空，is_group 标记供 UI 区分。
        point = Some(NavPoint::{
          label: @util.trim(@xml.text_content(child)),
          path: "",
          fragment: "",
          children: [],
          is_group: true,
          hidden: is_hidden,
        })
      }
    }
    let sub = find_first_list(li)
    match (point, sub) {
      (Some(p), Some(list2)) => {
        let kids = parse_nav_list(base, list2, warnings)
        out.push(NavPoint::{
          label: p.label,
          path: p.path,
          fragment: p.fragment,
          children: kids,
          is_group: p.is_group,
          hidden: p.hidden,
        })
      }
      (Some(p), None) => out.push(p)
      (None, Some(list2)) =>
        // 没有首元素（脏数据）但有子列表：把子项提升到当前层级。
        for k in parse_nav_list(base, list2, warnings) {
          out.push(k)
        }
      (None, None) =>
        push_warning(
          warnings, "nav 列表项既无链接也无子列表，已跳过",
        )
    }
  }
  out
}

// ---------------- NCX（EPUB2） ----------------

///|
pub fn parse_ncx(
  ncx_path : String,
  text : String,
) -> Result[(Array[NavPoint], Array[String]), String] {
  let warnings : Array[String] = []
  match @xml.parse_document_lenient(text) {
    Err(e) => Err("NCX 解析失败：" + e)
    Ok(root) => {
      if !@xml.tag_is(root, "ncx") {
        return Err("NCX 根元素应为 ncx，实际是 '" + root.tag + "'")
      }
      match @xml.find_descendant(root, "navMap") {
        None => {
          push_warning(warnings, "NCX 缺少 navMap")
          Ok(([], warnings))
        }
        Some(map) => Ok((parse_navmap(ncx_path, map, warnings), warnings))
      }
    }
  }
}

///|
fn parse_navmap(
  base : String,
  map : @xml.Element,
  warnings : Array[String],
) -> Array[NavPoint] {
  let out : Array[NavPoint] = []
  for np in @xml.child_elements(map) {
    if !@xml.tag_is(np, "navPoint") {
      continue
    }
    let label = match @xml.find_descendant(np, "navLabel") {
      None => ""
      Some(l) =>
        match @xml.find_child(l, "text") {
          None => @util.trim(@xml.text_content(l))
          Some(t) => @util.trim(@xml.text_content(t))
        }
    }
    let src = match @xml.find_child(np, "content") {
      None => {
        push_warning(warnings, "NCX navPoint 缺少 content，已跳过")
        ""
      }
      Some(c) => lower_attr_to_raw(@xml.attr_ci(c, "src"))
    }
    if src.length() == 0 {
      continue
    }
    let r = @resource.resolve(base, src)
    let path = ref_to_path(r, "NCX navPoint '" + label + "'", warnings)
    let kids = parse_navmap(base, np, warnings)
    out.push(NavPoint::{
      label,
      path,
      fragment: @resource.fragment(src),
      children: kids,
      is_group: false,
      hidden: false,
    })
  }
  out
}

// ---------------- 加密声明 ----------------

///|
/// ：仅检测并给出清晰提示，**不解密**（非目标 DRM）。
pub fn detect_encryption(
  a : @container.Archive,
  opf_path : String,
) -> EncryptionInfo {
  let schemes : Array[String] = []
  if @container.has(a, "META-INF/encryption.xml") {
    match @container.read(a, "META-INF/encryption.xml") {
      Err(e) =>
        return EncryptionInfo::{
          encrypted: true,
          schemes: "",
          message: "存在 META-INF/encryption.xml 但无法解析：" + e,
        }
      Ok(text) =>
        match @xml.parse_document_lenient(text) {
          Err(_) =>
            // 加密清单本身损坏：仍按「声明了加密」处理，避免误判为可直接阅读
            return EncryptionInfo::{
              encrypted: true,
              schemes: "",
              message: "META-INF/encryption.xml 存在但格式非法，按加密文档处理",
            }
          Ok(root) =>
            for d in @xml.descendants(root) {
              let name = @util.ascii_lower(@xml.local_name(d.tag))
              if name == "encryptionmethod" ||
                name == "encryptedmodule" ||
                name == "enc:encryptionmethod" ||
                name == "xenc:encryptionmethod" {
                let algo = lower_attr_to_raw(@xml.attr_ci(d, "algorithm"))
                if algo.length() > 0 {
                  schemes.push(algo)
                }
              }
            }
        }
    }
  }
  // OPF 里的 `properties="encrypted-data"` 也是加密标记
  if @container.has(a, opf_path) {
    match @container.read(a, opf_path) {
      Err(_) => ()
      Ok(text) =>
        match @xml.parse_document_lenient(text) {
          Err(_) => ()
          Ok(root) =>
            for d in @xml.descendants(root) {
              let props = lower_attr_to_raw(@xml.attr_ci(d, "properties"))
              if @resource.has_property(props, "encrypted-data") {
                schemes.push("epub-encrypted-data")
              }
            }
        }
    }
  }
  if schemes.length() == 0 {
    no_encryption()
  } else {
    let mut joined = ""
    let mut i = 0
    while i < schemes.length() {
      if i > 0 {
        joined = joined + ", "
      }
      joined = joined + schemes[i]
      i = i + 1
    }
    EncryptionInfo::{
      encrypted: true,
      schemes: joined,
      message: "文档声明加密（" +
      joined +
      "），本项目不实现解密",
    }
  }
}
