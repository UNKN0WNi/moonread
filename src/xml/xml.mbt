///|
/// XML 子集解析（OPF / container.xml / NCX / XHTML 章节通用）。
///
/// 首选 `moonbit-community/XMLParser`。本包是**同接口的本地实现**，
/// 理由写在 `docs/ARCHITECTURE.md` 的「依赖取舍」：
/// 1. 预研沙箱无法联网取包，主线代码必须能在零外部依赖下编译并跑测试；
/// 2. EPUB 只需要 XML 1.0 的一个良构子集（无外部实体、无命名空间 URI 归一化）；
/// 3. 接口做成 `Element`/`Node` 树 + 纯函数访问器，换实现时只需要替换本包。
///
/// 实体处理遵循 EPUB 3.3「XML conformance」条款：
/// - 支持 DOCTYPE 内部子集声明的**内部实体**（`<!ENTITY name "value">`），
///   文本与属性值中按 XML 规则展开——这是合法 EPUB 输入的一部分；
/// - 拒绝**外部实体**（SYSTEM / PUBLIC，含网络与 file URL），
///   规范原文「MUST NOT contain external entity declarations in the internal DTD subset」，
///   防止 XXE；
/// - 命名空间前缀原样保留（`opf:`、`xmlns:epub` 等），
///   由上层用 `local_name` / 大小写无关比较处理，不做 URI 归一化。
///
/// `lenient` 模式（已知风险「真实 EPUB 语料比预期脏」的缓解）：
/// - 未识别的命名实体按字面保留；
/// - HTML 空元素（`br`/`img`/`meta` …）允许不写自闭合斜杠；
/// - 结束标签大小写与开始标签不一致时按 ASCII 大小写无关匹配。
#derive(Debug, Eq)
pub(all) struct Element {
  tag : String
  attrs : Array[(String, String)]
  children : Array[Node]
  /// 该元素作用域内有效的命名空间绑定（prefix -> URI，默认命名空间用 "" 键）。
  /// 含祖先继承 + 自身 xmlns 声明；用于按 XML Namespaces 判定元素身份。
  ns : Array[(String, String)]
}

///|
#derive(Debug, Eq)
pub(all) enum Node {
  EElement(Element)
  EText(String)
}

///|
#derive(Debug, Eq)
pub(all) struct ParseOptions {
  lenient : Bool
}

///|
pub fn strict_options() -> ParseOptions {
  ParseOptions::{ lenient: false, }
}

///|
pub fn lenient_options() -> ParseOptions {
  ParseOptions::{ lenient: true, }
}

///|
priv struct XP {
  src : Array[Char]
  mut pos : Int32
  mut depth : Int32
  opts : ParseOptions
  /// DOCTYPE 内部子集声明的内部实体：name -> value。外部实体不进表。
  entities : Array[(String, String)]
  /// 内部参数实体 `<!ENTITY % name "value">`：只在 DTD 内部子集中展开，
  /// 用于构造其它声明。EPUB 3.3 §3.9 只禁「外部实体声明」，内部参数实体合法。
  param_entities : Array[(String, String)]
  /// 实体替换递归深度；避免自引用实体无限展开。
  entity_depth : Int32
}

///|
/// 解析整篇文档：允许 `<?xml?>`、注释、`<!DOCTYPE ...>` 前言，要求恰好一个根元素。
pub fn parse_document(text : String) -> Result[Element, String] {
  parse_document_with(text, strict_options())
}

///|
/// 语料解析推荐入口：脏 EPUB 用 lenient，仍失败再降级（出口条件「不 panic」）。
pub fn parse_document_lenient(text : String) -> Result[Element, String] {
  parse_document_with(text, lenient_options())
}

///|
pub fn parse_document_with(
  text : String,
  opts : ParseOptions,
) -> Result[Element, String] {
  let p = XP::{
    src: @util.to_chars(text),
    pos: 0,
    depth: 0,
    opts,
    entities: [],
    param_entities: [],
    entity_depth: 0,
  }
  match skip_prolog(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if p.pos >= p.src.length() {
    return Err("文档为空或只有前言")
  }
  let root = match parse_element(p, []) {
    Ok(__try_v_1) => __try_v_1
    Err(__try_e_1) => return Err(__try_e_1)
  }
  match skip_prolog(p) {
    Ok(_) => ()
    Err(e) => return Err(e)
  }
  if p.pos != p.src.length() {
    return Err(
      "第 " +
      p.pos.to_string() +
      " 个字符处：根元素之后存在多余内容 '" +
      @util.char_to_string(p.src[p.pos]) +
      "'",
    )
  }
  Ok(root)
}

///|
/// 解析一个外部解析片段（章节正文常见做法：只有一段 body 内容）。
pub fn parse_fragment(
  text : String,
  opts : ParseOptions,
) -> Result[Element, String] {
  parse_document_with(
    "<moonread-fragment>" + text + "</moonread-fragment>",
    opts,
  )
}

///|
fn cur(p : XP) -> Char? {
  at(p, p.pos)
}

///|
fn at(p : XP, i : Int32) -> Char? {
  if i >= 0 && i < p.src.length() {
    Some(p.src[i])
  } else {
    None
  }
}

///|
fn err_at(p : XP, msg : String) -> Result[Element, String] {
  Err("第 " + p.pos.to_string() + " 个字符处：" + msg)
}

///|
fn err_at_str(p : XP, msg : String) -> Result[String, String] {
  Err("第 " + p.pos.to_string() + " 个字符处：" + msg)
}

///|
fn starts_here(p : XP, lit : String) -> Bool {
  @util.matches_at(p.src, p.pos, @util.to_chars(lit))
}

///|
fn skip_ws(p : XP) -> Unit {
  let n = p.src.length()
  let mut i = p.pos
  while i < n && @util.is_xml_space(p.src[i]) {
    i = i + 1
  }
  p.pos = i
}

///|
/// 跳过前言：空白、`<?...?>`、`<!--...-->`、`<!DOCTYPE ...>`（含内部子集）。
/// 前言中的语法错误（未闭合、禁止的外部实体）必须原样上抛，
/// 否则会被后面的根元素解析误报成「期望名称」。
fn skip_prolog(p : XP) -> Result[Unit, String] {
  let n = p.src.length()
  let mut keep = true
  while keep && p.pos < n {
    skip_ws(p)
    if starts_here(p, "<!--") {
      match skip_until(p, "-->") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if starts_here(p, "<?") {
      match skip_until(p, "?>") {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else if starts_here(p, "<!") {
      match skip_doctype(p) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
    } else {
      keep = false
    }
  }
  Ok(())
}

///|
fn skip_until(p : XP, term : String) -> Result[Unit, String] {
  let pat = @util.to_chars(term)
  let n = p.src.length()
  // 调用方已确认位于起始标记处；从标记内第二个字符开始找终止串，
  // 这样 `<!--`、`<?`、`<!` 三种起始长度都无需区分。
  let mut i = p.pos + 1
  while i + pat.length() <= n {
    if @util.matches_at(p.src, i, pat) {
      p.pos = i + pat.length()
      return Ok(())
    }
    i = i + 1
  }
  Err(
    "第 " +
    p.pos.to_string() +
    " 个字符处：未找到终止标记 '" +
    term +
    "'",
  )
}

///|
/// `<!DOCTYPE ...>`：处理内部子集 `[ ... ]`（其中可能出现 `>`），
/// 收集合法内部实体声明；外部实体声明按 EPUB 3.3 规范拒绝。
///
/// 扫描按 XML 词法跳过引号、注释与 PI：实体值中的 `]` 不能提前结束内部
/// 子集，注释中的 `<!ENTITY … SYSTEM …>` 也不是声明。真正的声明收集
/// 由 `parse_internal_subset` 完成（那里同样跳过注释与引号）。
fn skip_doctype(p : XP) -> Result[Unit, String] {
  let n = p.src.length()
  let mut i = p.pos + 2
  let mut in_subset = false
  let mut subset_start = 0
  let mut subset_end = -1
  let mut quote : Char? = None
  let mut in_comment = false
  let mut in_pi = false
  let comment_start = @util.to_chars("<!--")
  let comment_end = @util.to_chars("-->")
  let pi_start = @util.to_chars("<?")
  let pi_end = @util.to_chars("?>")
  while i < n {
    if in_comment {
      if @util.matches_at(p.src, i, comment_end) {
        in_comment = false
        i = i + 3
      } else {
        i = i + 1
      }
      continue
    }
    if in_pi {
      if @util.matches_at(p.src, i, pi_end) {
        in_pi = false
        i = i + 2
      } else {
        i = i + 1
      }
      continue
    }
    match quote {
      Some(q) => {
        if p.src[i] == q {
          quote = None
        }
        i = i + 1
        continue
      }
      None => ()
    }
    if @util.matches_at(p.src, i, comment_start) {
      in_comment = true
      i = i + 4
      continue
    }
    if @util.matches_at(p.src, i, pi_start) {
      in_pi = true
      i = i + 2
      continue
    }
    let c = p.src[i]
    if c == '"' || c == '\'' {
      quote = Some(c)
      i = i + 1
      continue
    }
    if c == '[' && !in_subset {
      in_subset = true
      subset_start = i + 1
    } else if c == ']' && in_subset {
      in_subset = false
      subset_end = i
    } else if c == '>' && !in_subset {
      if subset_start > 0 {
        match parse_internal_subset(p, subset_start, subset_end) {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
      }
      p.pos = i + 1
      return Ok(())
    }
    i = i + 1
  }
  Err("第 " + p.pos.to_string() + " 个字符处：DOCTYPE 未闭合")
}

///|
/// 解析 DOCTYPE 内部子集中的实体声明（EPUB 3.3 §3.9「XML conformance」）。
///
/// 规范只禁「internal DTD subset 中的 external entity declaration」，因此：
/// - `<!ENTITY name "value">` 内部一般实体：收集进 `p.entities`，供文本/属性值展开；
/// - `<!ENTITY % name "value">` 内部参数实体：合法，收集进 `p.param_entities`，
///   其值在内部子集内按 `%name;` 展开（用于构造后续声明）；不进入正文实体表；
/// - 带 `SYSTEM` / `PUBLIC` 外部标识符的（一般或参数）实体：规范 MUST NOT，拒绝。
///
/// 一律拒绝参数实体是过度收窄，与「符合 XML Namespaces 1.0 + XML 1.0 文档」
/// 的兼容终点冲突；合法内部参数实体声明必须按语义接受。
fn parse_internal_subset(
  p : XP,
  from : Int32,
  to : Int32,
) -> Result[Unit, String] {
  let marker = @util.to_chars("<!ENTITY")
  let comment_start = @util.to_chars("<!--")
  let comment_end = @util.to_chars("-->")
  let mut i = from
  while i < to {
    // 注释是词法单位：其中的 `<!ENTITY … SYSTEM …>` 只是文字，不是声明。
    if @util.matches_at(p.src, i, comment_start) {
      i = i + comment_start.length()
      while i + comment_end.length() <= to &&
            !@util.matches_at(p.src, i, comment_end) {
        i = i + 1
      }
      i = i + comment_end.length()
      continue
    }
    // 引号内文本同理（例如 NOTATION 声明的引号参数）。
    if p.src[i] == '"' || p.src[i] == '\'' {
      let q = p.src[i]
      i = i + 1
      while i < to && p.src[i] != q {
        i = i + 1
      }
      if i < to {
        i = i + 1
      }
      continue
    }
    if @util.matches_at(p.src, i, marker) {
      let decl_start = i
      i = i + marker.length()
      while i < to && @util.is_xml_space(p.src[i]) {
        i = i + 1
      }
      // 参数实体声明以 `%` 开头；它本身合法，只有带外部标识符才被禁。
      let is_param = i < to && p.src[i] == '%'
      if is_param {
        i = i + 1
        while i < to && @util.is_xml_space(p.src[i]) {
          i = i + 1
        }
      }
      let name_start = i
      while i < to &&
            !@util.is_xml_space(p.src[i]) &&
            p.src[i] != '"' &&
            p.src[i] != '\'' &&
            p.src[i] != '>' {
        i = i + 1
      }
      let name = @util.from_chars(@util.slice_chars(p.src, name_start, i))
      if name.length() == 0 {
        return Err(
          "第 " +
          decl_start.to_string() +
          " 个字符处：实体声明缺少名称",
        )
      }
      while i < to && @util.is_xml_space(p.src[i]) {
        i = i + 1
      }
      if i >= to {
        return Err(
          "第 " +
          decl_start.to_string() +
          " 个字符处：实体声明未闭合",
        )
      }
      let c = p.src[i]
      if c == '"' || c == '\'' {
        let saved = p.pos
        p.pos = i + 1
        let raw = match read_entity_value(p, c) {
          Ok(v) => v
          Err(e) => return Err(e)
        }
        i = p.pos
        p.pos = saved
        // 保留原始替换文本：XML 规定实体在文本中被引用时，替换文本要
        // 作为标记重新解析；提前展开会把 `&lt;b&gt;` 误变成真正的 <b> 元素。
        if is_param {
          // 参数实体值可引用先前声明的参数实体，在内部子集作用域内展开。
          let resolved = match expand_param_value(p, raw, 0) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          p.param_entities.push((name, resolved))
        } else {
          // 一般实体的值若含 %param;（DTD 构造常见写法），同样在
          // 内部子集作用域展开，再保留原文本供正文按标记重解析。
          let resolved = match expand_param_value(p, raw, 0) {
            Ok(v) => v
            Err(e) => return Err(e)
          }
          p.entities.push((name, resolved))
        }
      } else {
        // SYSTEM / PUBLIC 或其他非引号形式：外部实体声明，规范禁止
        // （对参数实体同样适用：<!ENTITY % x SYSTEM "…"> 属 external entity declaration）
        return Err(
          "第 " +
          decl_start.to_string() +
          " 个字符处：EPUB 禁止外部实体声明" +
          (if is_param { "（参数实体）" } else { "" }) +
          " '" +
          name +
          "'（internal DTD subset 不得含 external entity declaration）",
        )
      }
    } else {
      i = i + 1
    }
  }
  Ok(())
}

///|
/// 展开实体声明值中的参数实体引用 `%name;`，深度上限 8。
/// 只作用于 DTD 内部子集；正文与属性值不经过这里（那里 `%` 是普通字符）。
fn expand_param_value(
  p : XP,
  raw : String,
  depth : Int32,
) -> Result[String, String] {
  if depth > 8 {
    return Err("参数实体引用嵌套超过 8 层，疑似循环引用")
  }
  let cs = @util.to_chars(raw)
  let out : Array[Char] = []
  let n = cs.length()
  let mut i = 0
  while i < n {
    if cs[i] != '%' {
      out.push(cs[i])
      i = i + 1
      continue
    }
    let mut j = i + 1
    let name_buf : Array[Char] = []
    let mut closed = false
    while j < n && name_buf.length() < 32 {
      if cs[j] == ';' {
        closed = true
        break
      }
      if cs[j] == '%' || @util.is_xml_space(cs[j]) {
        break
      }
      name_buf.push(cs[j])
      j = j + 1
    }
    if !closed {
      // 无 `;` 的 `%` 不是合法参数实体引用，按字面保留
      out.push('%')
      i = i + 1
      continue
    }
    let name = @util.from_chars(name_buf)
    let mut found : String? = None
    for kv in p.param_entities {
      if kv.0 == name {
        found = Some(kv.1)
        break
      }
    }
    match found {
      None =>
        if p.opts.lenient {
          // 宽松模式保留字面，避免脏 DTD 阻断阅读
          out.push('%')
          for ch in name_buf {
            out.push(ch)
          }
          out.push(';')
        } else {
          return Err("未声明的参数实体 '%" + name + ";'")
        }
      Some(v) =>
        match expand_param_value(p, v, depth + 1) {
          Err(e) => return Err(e)
          Ok(expanded) =>
            for ch in @util.to_chars(expanded) {
              out.push(ch)
            }
        }
    }
    i = j + 1
  }
  Ok(@util.from_chars(out))
}

///|
fn read_name(p : XP) -> Result[String, String] {
  skip_ws(p)
  let n = p.src.length()
  let start = p.pos
  if p.pos < n &&
    (p.src[p.pos] == '<' || p.src[p.pos] == '>' || p.src[p.pos] == '/') {
    return Err(
      "第 " +
      start.to_string() +
      " 个字符处：期望名称，实际是标记字符",
    )
  }
  while p.pos < n && is_name_char(p.src[p.pos]) {
    p.pos = p.pos + 1
  }
  if p.pos == start {
    return Err(
      "第 " +
      start.to_string() +
      " 个字符处：期望名称，实际是 '" +
      (match at(p, start) {
        Some(c) => @util.char_to_string(c)
        None => "<结束>"
      }) +
      "'",
    )
  }
  Ok(@util.from_chars(@util.slice_chars(p.src, start, p.pos)))
}

///|
fn has_attr_name(attrs : Array[(String, String)], name : String) -> Bool {
  for kv in attrs {
    if kv.0 == name {
      return true
    }
  }
  false
}

///|
fn is_name_char(c : Char) -> Bool {
  if c >= 'a' && c <= 'z' {
    true
  } else if c >= 'A' && c <= 'Z' {
    true
  } else if c >= '0' && c <= '9' {
    true
  } else if c == '-' || c == '_' || c == ':' || c == '.' {
    true
  } else {
    @util.char_to_int(c) > 0x7f
  }
}

///|
/// `ns` 为祖先作用域内已生效的 xmlns 绑定；本元素声明的 xmlns 会覆盖同名前缀。
fn parse_element(
  p : XP,
  ns : Array[(String, String)],
) -> Result[Element, String] {
  // XML 1.0 没有层级上限；HTML5 的实现建议 512。合法深层文档不能因
  // 内核自设的 96 层上限被误拒，因此对齐到 512 并保留构造输入防线。
  if p.depth > 512 {
    return err_at(p, "元素嵌套超过 512 层，疑似构造输入")
  }
  if cur(p) != Some('<') {
    return err_at(p, "期望 '<' 开始标签")
  }
  p.pos = p.pos + 1
  let tag = match read_name(p) {
    Ok(__try_v_2) => __try_v_2
    Err(__try_e_2) => return Err(__try_e_2)
  }
  let attrs : Array[(String, String)] = []
  let mut self_closed = false
  let mut done = false
  while !done {
    skip_ws(p)
    match cur(p) {
      None => return err_at(p, "标签 '" + tag + "' 未闭合")
      Some('/') => {
        p.pos = p.pos + 1
        if cur(p) != Some('>') {
          return err_at(p, "'/' 之后期望 '>'")
        }
        p.pos = p.pos + 1
        self_closed = true
        done = true
      }
      Some('>') => {
        p.pos = p.pos + 1
        done = true
      }
      _ => {
        let name = match read_name(p) {
          Ok(__try_v_3) => __try_v_3
          Err(__try_e_3) => return Err(__try_e_3)
        }
        // XML WFC: No Duplicate Attributes。expat 也会拒绝同一限定名重复。
        if has_attr_name(attrs, name) {
          return err_at(p, "属性 '" + name + "' 重复（违反 XML WFC）")
        }
        skip_ws(p)
        if cur(p) != Some('=') {
          if p.opts.lenient {
            // XHTML 里允许 `<input checked>` 这类无值属性，按空值处理
            attrs.push((name, name))
          } else {
            return err_at(p, "属性 '" + name + "' 之后期望 '='")
          }
        } else {
          p.pos = p.pos + 1
          skip_ws(p)
          let raw = match read_attr_value(p) {
            Ok(__try_v_4) => __try_v_4
            Err(__try_e_4) => return Err(__try_e_4)
          }
          let decoded = match decode_entities_in(raw, p.opts, p.entities, 0) {
            Ok(__try_v_5) => __try_v_5
            Err(__try_e_5) => return Err(__try_e_5)
          }
          if @util.contains(decoded, "<") {
            return err_at(
              p,
              "属性 '" +
              name +
              "' 的值经实体展开后不得出现裸 '<'",
            )
          }
          attrs.push((name, decoded))
        }
      }
    }
  }
  // XML Namespaces 1.0：本元素声明的 xmlns 覆盖祖先同名前缀。
  // `xmlns="URI"` 写默认命名空间（键 ""），`xmlns:p="URI"` 写前缀 p。
  let scope = merge_ns_scope(ns, attrs)
  if self_closed {
    return Ok(Element::{ tag, attrs, children: [], ns: scope, })
  }
  if is_void_tag(tag, p.opts) {
    // XHTML 允许 `<meta/>`，但 EPUB 里也常见 `<meta>...</meta>`；
    // 宽松模式遇到显式结束标签时要吃掉它，不能留给父元素当成错配。
    let saved = p.pos
    skip_ws(p)
    let closing = "</" + tag + ">"
    if starts_here(p, closing) {
      p.pos = p.pos + closing.length()
    } else {
      p.pos = saved
    }
    return Ok(Element::{ tag, attrs, children: [], ns: scope, })
  }
  p.depth = p.depth + 1
  let children : Array[Node] = []
  let closed = parse_children(p, tag, children, scope)
  p.depth = p.depth - 1
  match closed {
    Err(e) => return Err(e)
    Ok(_) => Ok(Element::{ tag, attrs, children, ns: scope, })
  }
}

///|
/// 把当前元素上的 xmlns 声明合并进祖先作用域；同名前缀后者覆盖前者。
fn merge_ns_scope(
  parent : Array[(String, String)],
  attrs : Array[(String, String)],
) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for kv in parent {
    out.push(kv)
  }
  for kv in attrs {
    let key = @util.ascii_lower(kv.0)
    if key == "xmlns" {
      set_ns(out, "", kv.1)
    } else if @util.starts_with(key, "xmlns:") {
      // XML 前缀区分大小写：`xmlns:X="urn:foreign"` 绑定的是前缀 `X`，
      // 不是 `x`。若把前缀小写化，`<X:title>` 就解析不出 URI，进而被
      // 当成「未声明命名空间的历史语料」冒充 `dc:title`。
      // 标记 `xmlns:` 仍按大小写无关识别（兼容真实书的脏写法），
      // 但绑定键必须取自原始属性名。
      let prefix = @util.slice_string(kv.0, 6, @util.to_chars(kv.0).length())
      set_ns(out, prefix, kv.1)
    }
  }
  out
}

///|
/// 作用域内按前缀覆盖式写入绑定。
fn set_ns(
  scope : Array[(String, String)],
  prefix : String,
  uri : String,
) -> Unit {
  let n = scope.length()
  let mut i = 0
  while i < n {
    if scope[i].0 == prefix {
      scope[i] = (prefix, uri)
      return
    }
    i = i + 1
  }
  scope.push((prefix, uri))
}

///|
fn is_void_tag(tag : String, opts : ParseOptions) -> Bool {
  if !opts.lenient {
    return false
  }
  let t = @util.ascii_lower(tag)
  t == "area" ||
  t == "base" ||
  t == "br" ||
  t == "col" ||
  t == "embed" ||
  t == "hr" ||
  t == "img" ||
  t == "input" ||
  t == "link" ||
  t == "param" ||
  t == "source" ||
  t == "track" ||
  t == "wbr"
}

///|
fn parse_children(
  p : XP,
  open_tag : String,
  out : Array[Node],
  ns : Array[(String, String)],
) -> Result[Unit, String] {
  let n = p.src.length()
  while true {
    if p.pos >= n {
      return Err(
        "第 " +
        p.pos.to_string() +
        " 个字符处：元素 '" +
        open_tag +
        "' 缺少结束标签",
      )
    }
    if cur(p) == Some('<') {
      if starts_here(p, "</") {
        p.pos = p.pos + 2
        let close = match read_name(p) {
          Ok(__try_v_6) => __try_v_6
          Err(__try_e_6) => return Err(__try_e_6)
        }
        skip_ws(p)
        if cur(p) != Some('>') {
          return Err(
            "第 " +
            p.pos.to_string() +
            " 个字符处：结束标签 '" +
            close +
            "' 未闭合",
          )
        }
        p.pos = p.pos + 1
        if close == open_tag {
          return Ok(())
        }
        if p.opts.lenient &&
          @util.ascii_lower(close) == @util.ascii_lower(open_tag) {
          return Ok(())
        }
        return Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：结束标签 '" +
          close +
          "' 与当前元素 '" +
          open_tag +
          "' 不匹配",
        )
      } else if starts_here(p, "<!--") {
        // 注释不进入树：真实语料里注释常包裹被弃用的排版片段
        match skip_until(p, "-->") {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
      } else if starts_here(p, "<![CDATA[") {
        p.pos = p.pos + 9
        let buf : Array[Char] = []
        let mut found = false
        while p.pos < n {
          if @util.matches_at(p.src, p.pos, @util.to_chars("]]>")) {
            p.pos = p.pos + 3
            found = true
            break
          }
          buf.push(p.src[p.pos])
          p.pos = p.pos + 1
        }
        if !found {
          return Err(
            "第 " + p.pos.to_string() + " 个字符处：CDATA 未闭合",
          )
        }
        out.push(EText(@util.from_chars(buf)))
      } else if starts_here(p, "<?") {
        match skip_until(p, "?>") {
          Err(e) => return Err(e)
          Ok(_) => ()
        }
      } else {
        let child = match parse_element(p, ns) {
          Ok(__try_v_7) => __try_v_7
          Err(__try_e_7) => return Err(__try_e_7)
        }
        out.push(EElement(child))
      }
    } else {
      let start = p.pos
      while p.pos < n && p.src[p.pos] != '<' {
        p.pos = p.pos + 1
      }
      let raw = @util.from_chars(@util.slice_chars(p.src, start, p.pos))
      let nodes = match decode_text_nodes(p, raw, ns) {
        Ok(__try_v_8) => __try_v_8
        Err(__try_e_8) => return Err(__try_e_8)
      }
      for n in nodes {
        out.push(n)
      }
    }
  }
  Err("不可达")
}

///|
fn read_attr_value(p : XP) -> Result[String, String] {
  match cur(p) {
    Some('"') => {
      p.pos = p.pos + 1
      read_quoted(p, '"')
    }
    Some('\'') => {
      p.pos = p.pos + 1
      read_quoted(p, '\'')
    }
    _ => err_at_str(p, "属性值必须用单引号或双引号包裹")
  }
}

///|
/// 属性值：禁止裸 '<'，并按 XML §3.3.3 把字面换行/制表归一化为空格。
fn read_quoted(p : XP, quote : Char) -> Result[String, String] {
  read_quoted_with(p, quote, false, true)
}

///|
/// 内部实体声明值：允许 '<'（在正文中引用时作为标记重新解析是合法的）。
fn read_entity_value(p : XP, quote : Char) -> Result[String, String] {
  read_quoted_with(p, quote, true, true)
}

///|
fn read_quoted_with(
  p : XP,
  quote : Char,
  allow_lt : Bool,
  normalize_space : Bool,
) -> Result[String, String] {
  let n = p.src.length()
  let buf : Array[Char] = []
  while p.pos < n {
    let c = p.src[p.pos]
    if c == quote {
      p.pos = p.pos + 1
      return Ok(@util.from_chars(buf))
    }
    if c == '<' && !allow_lt {
      return Err(
        "第 " +
        p.pos.to_string() +
        " 个字符处：属性值内不得出现裸 '<'",
      )
    }
    if normalize_space && (c == '\n' || c == '\t' || c == '\r') {
      buf.push(' ')
    } else {
      buf.push(c)
    }
    p.pos = p.pos + 1
  }
  Err("第 " + p.pos.to_string() + " 个字符处：属性值引号未闭合")
}

///|
/// 实体引用解码（公开入口，无内部实体表）。
/// 支持五个预定义实体与数字引用；未知命名实体在 lenient 模式下按字面保留，
/// 严格模式下报错。文档解析请用带内部实体表的入口。
pub fn decode_entities(
  text : String,
  opts : ParseOptions,
) -> Result[String, String] {
  decode_entities_in(text, opts, [], 0)
}

///|
fn internal_entity_value(
  entities : Array[(String, String)],
  name : String,
) -> String? {
  for ent in entities {
    if ent.0 == name {
      return Some(ent.1)
    }
  }
  None
}

///|
fn append_text_node(out : Array[Node], buf : Array[Char]) -> Unit {
  if buf.length() > 0 {
    out.push(EText(@util.from_chars(buf)))
  }
}

///|
/// 正文中的实体引用：内部实体的替换文本必须作为标记重新解析。
/// 这正是 XML 1.0 §4.4.5 与 expat 的行为；属性值仍走 `decode_entities_in`。
fn decode_text_nodes(
  p : XP,
  raw : String,
  ns : Array[(String, String)],
) -> Result[Array[Node], String] {
  let cs = @util.to_chars(raw)
  let out : Array[Node] = []
  let mut buf : Array[Char] = []
  let n = cs.length()
  let mut i = 0
  while i < n {
    if cs[i] != '&' {
      buf.push(cs[i])
      i = i + 1
    } else {
      let mut j = i + 1
      let name_buf : Array[Char] = []
      let mut closed = false
      while j < n && name_buf.length() < 32 {
        if cs[j] == ';' {
          closed = true
          break
        }
        if cs[j] == '&' || @util.is_xml_space(cs[j]) || cs[j] == '<' {
          break
        }
        name_buf.push(cs[j])
        j = j + 1
      }
      if !closed {
        if p.opts.lenient {
          buf.push('&')
          i = i + 1
        } else {
          return Err(
            "第 " + i.to_string() + " 个字符处：实体引用缺少 ';'",
          )
        }
      } else {
        let name = @util.from_chars(name_buf)
        match internal_entity_value(p.entities, name) {
          Some(value) => {
            if p.entity_depth >= 8 {
              return Err("内部实体 '" + name + "' 替换嵌套超过 8 层")
            }
            append_text_node(out, buf)
            buf = []
            let fragment = "<moonread-fragment>" +
              value +
              "</moonread-fragment>"
            let sub = XP::{
              src: @util.to_chars(fragment),
              pos: 0,
              depth: p.depth,
              opts: p.opts,
              entities: p.entities,
              param_entities: p.param_entities,
              entity_depth: p.entity_depth + 1,
            }
            let el = match parse_element(sub, ns) {
              Ok(__try_v_9) => __try_v_9
              Err(__try_e_9) =>
                return Err(
                  "内部实体 '" +
                  name +
                  "' 替换文本解析失败：" +
                  __try_e_9,
                )
            }
            skip_ws(sub)
            if sub.pos != sub.src.length() {
              return Err(
                "内部实体 '" + name + "' 替换文本含多余内容",
              )
            }
            for node in el.children {
              out.push(node)
            }
          }
          None =>
            match resolve_entity(name, p.opts, p.entities, 0) {
              Ok(Some(s)) =>
                for ch in @util.to_chars(s) {
                  buf.push(ch)
                }
              Ok(None) =>
                if p.opts.lenient {
                  buf.push('&')
                  for ch in name_buf {
                    buf.push(ch)
                  }
                  buf.push(';')
                } else {
                  return Err(
                    "第 " +
                    i.to_string() +
                    " 个字符处：未声明的实体 '&" +
                    name +
                    ";'",
                  )
                }
              Err(e) => return Err(e)
            }
        }
        i = j + 1
      }
    }
  }
  append_text_node(out, buf)
  Ok(out)
}

///|
/// 实体解码内部实现：`entities` 为 DOCTYPE 内部子集声明的内部实体表；
/// `depth` 防止实体循环引用导致无限递归（上限 8）。
fn decode_entities_in(
  text : String,
  opts : ParseOptions,
  entities : Array[(String, String)],
  depth : Int32,
) -> Result[String, String] {
  if depth > 8 {
    return Err("实体引用嵌套超过 8 层，疑似循环引用")
  }
  let cs = @util.to_chars(text)
  let out : Array[Char] = []
  let n = cs.length()
  let mut i = 0
  while i < n {
    if cs[i] != '&' {
      out.push(cs[i])
      i = i + 1
    } else {
      let mut j = i + 1
      let buf : Array[Char] = []
      let mut closed = false
      while j < n && buf.length() < 32 {
        if cs[j] == ';' {
          closed = true
          break
        }
        if cs[j] == '&' || @util.is_xml_space(cs[j]) || cs[j] == '<' {
          break
        }
        buf.push(cs[j])
        j = j + 1
      }
      if !closed {
        if opts.lenient {
          out.push('&')
          i = i + 1
        } else {
          return Err(
            "第 " + i.to_string() + " 个字符处：实体引用缺少 ';'",
          )
        }
      } else {
        let name = @util.from_chars(buf)
        match resolve_entity(name, opts, entities, depth) {
          Ok(Some(s)) =>
            for ch in @util.to_chars(s) {
              out.push(ch)
            }
          Ok(None) =>
            if opts.lenient {
              out.push('&')
              for ch in buf {
                out.push(ch)
              }
              out.push(';')
            } else {
              return Err(
                "第 " +
                i.to_string() +
                " 个字符处：未声明的实体 '&" +
                name +
                ";'",
              )
            }
          Err(e) => return Err(e)
        }
        i = j + 1
      }
    }
  }
  Ok(@util.from_chars(out))
}

///|
fn resolve_entity(
  name : String,
  opts : ParseOptions,
  entities : Array[(String, String)],
  depth : Int32,
) -> Result[String?, String] {
  let cs = @util.to_chars(name)
  if cs.length() == 0 {
    return Err("空实体引用 '&;'")
  }
  // 内部实体优先于 lenient 的 nbsp 兜底；外部实体不入表，故不会被解析
  for ent in entities {
    if ent.0 == name {
      return Ok(
        Some(
          match decode_entities_in(ent.1, opts, entities, depth + 1) {
            Ok(v) => v
            Err(e) => return Err(e)
          },
        ),
      )
    }
  }
  if cs[0] == '#' {
    return Ok(
      Some(
        match decode_numeric(name) {
          Ok(__try_v_10) => __try_v_10
          Err(__try_e_10) => return Err(__try_e_10)
        },
      ),
    )
  }
  if name == "lt" {
    Ok(Some("<"))
  } else if name == "gt" {
    Ok(Some(">"))
  } else if name == "amp" {
    Ok(Some("&"))
  } else if name == "quot" {
    Ok(Some("\""))
  } else if name == "apos" {
    Ok(Some("'"))
  } else if name == "nbsp" {
    // 非 XML 预定义实体，但真实 EPUB 语料里出现率极高
    if opts.lenient {
      Ok(Some("\u{a0}"))
    } else {
      Ok(None)
    }
  } else {
    Ok(None)
  }
}

///|
fn decode_numeric(name : String) -> Result[String, String] {
  let cs = @util.to_chars(name)
  let is_hex = cs.length() > 1 && cs[1] == 'x'
  let digits = @util.from_chars(
    @util.slice_chars(cs, if is_hex { 2 } else { 1 }, cs.length()),
  )
  if digits.length() == 0 {
    return Err("数字实体缺少数字：&" + name + ";")
  }
  let mut cp = 0
  if is_hex {
    for c in digits {
      match @util.hex_digit_value(c) {
        Some(v) => cp = cp * 16 + v
        None => return Err("数字实体含非法字符：&" + name + ";")
      }
    }
  } else {
    for c in digits {
      match @util.digit_value(c) {
        Some(v) => cp = cp * 10 + v
        None => return Err("数字实体含非法字符：&" + name + ";")
      }
    }
  }
  if !is_xml_char(cp) {
    return Err(
      "数字实体码位非法（XML Char production）：" + cp.to_string(),
    )
  }
  match @util.codepoint_to_char(cp) {
    Some(ch) => Ok(@util.char_to_string(ch))
    None => Err("数字实体码位非法：" + cp.to_string())
  }
}

///|
/// XML 1.0 §2.2 Char production。expat 同样拒绝 #x0、#x1 等控制码位。
fn is_xml_char(cp : Int32) -> Bool {
  cp == 0x9 ||
  cp == 0xa ||
  cp == 0xd ||
  (cp >= 0x20 && cp <= 0xd7ff) ||
  (cp >= 0xe000 && cp <= 0xfffd) ||
  (cp >= 0x10000 && cp <= 0x10ffff)
}

// ---------------- 访问器 ----------------

// ---------------- 命名空间（XML Namespaces 1.0） ----------------
//
// EPUB 3.3 §3.9 要求所有 XML 媒体类型都是符合 XML Namespaces 1.0 的文档。
// 元素身份 = {命名空间 URI} + local name，不是「裸 local name」。
// 标准词汇（dc:title、opf:item、epub:type…）必须核对前缀绑定的 URI；
// 外来命名空间里恰好同名的入口（如 <x:title xmlns:x="urn:foreign">）
// 不得被当成标准词汇，否则会把外来文档语义错误地塞进元数据。

///|
/// OPF / package 文档命名空间。
pub const OPF_NS : String = "http://www.idpf.org/2007/opf"

///|
/// Dublin Core 元素命名空间。
pub const DC_NS : String = "http://purl.org/dc/elements/1.1/"

///|
/// EPUB 3 语义词汇表命名空间（epub:type）。
pub const OPS_NS : String = "http://www.idpf.org/2007/ops"

///|
/// NCX 命名空间（EPUB 2）。
pub const NCX_NS : String = "http://www.daisy.org/z3986/2005/ncx/"

///|
/// XHTML 命名空间（EPUB 3 内容文档）。
pub const XHTML_NS : String = "http://www.w3.org/1999/xhtml"

///|
/// 取限定名的前缀部分：`dc:title` -> `"dc"`；无前缀返回 `""`。
pub fn prefix_of(tag : String) -> String {
  let parts = @util.split_char(tag, ':')
  if parts.length() >= 2 {
    parts[0]
  } else {
    ""
  }
}

///|
/// 元素按其前缀在作用域内解析出的命名空间 URI；无前缀元素用默认命名空间。
/// 未声明的前缀返回空串（调用方据此判定为外来/未知命名空间）。
pub fn namespace_uri(el : Element) -> String {
  let prefix = prefix_of(el.tag)
  match ns_lookup(el.ns, prefix) {
    Some(uri) => uri
    None => ""
  }
}

///|
fn ns_lookup(scope : Array[(String, String)], prefix : String) -> String? {
  for kv in scope {
    if kv.0 == prefix {
      return Some(kv.1)
    }
  }
  None
}

///|
/// 按 XML Namespaces 的元素身份判定标准词汇。
/// - local name 必须相等（ASCII 大小写无关）；
/// - 元素前缀解析出的 URI：为空（历史语料未声明命名空间）时按 local name 兼容命中；
///   非空时必须精确等于 `want_uri`——因此外来命名空间的同名入口
///   （如 `<x:title xmlns:x="urn:foreign">`）不会冒充 `dc:title`。
/// `want_uri` 传空串表示只按 local name 判定（宽松入口）。
pub fn element_is(el : Element, want_local : String, want_uri : String) -> Bool {
  if @util.ascii_lower(local_name(el.tag)) != @util.ascii_lower(want_local) {
    return false
  }
  let uri = namespace_uri(el)
  if want_uri.length() == 0 || uri.length() == 0 {
    return true
  }
  uri == want_uri
}

///|
/// 去掉命名空间前缀，`opf:scheme` -> `scheme`。
pub fn local_name(tag : String) -> String {
  let parts = @util.split_char(tag, ':')
  if parts.length() == 0 {
    tag
  } else {
    parts[parts.length() - 1]
  }
}

///|
/// 标签名是否等于 `want`（忽略命名空间前缀与 ASCII 大小写）。
pub fn tag_is(el : Element, want : String) -> Bool {
  @util.ascii_lower(local_name(el.tag)) == @util.ascii_lower(want)
}

///|
pub fn get_attr(el : Element, name : String) -> String? {
  let mut found : String? = None
  for kv in el.attrs {
    if kv.0 == name {
      found = Some(kv.1)
      break
    }
  }
  found
}

///|
/// 大小写无关 + 前缀无关的属性查找。真实 OPF 里 `id`/`ID`、`href`/`HREF` 都出现过。

///|
/// 属性不存在时返回空串，供只关心「有或没有」的调用方使用。
pub fn attr_or_empty(el : Element, name : String) -> String {
  match attr_ci(el, name) {
    Some(v) => v
    None => ""
  }
}

///|
pub fn attr_ci(el : Element, name : String) -> String? {
  let want = @util.ascii_lower(name)
  let mut found : String? = None
  for kv in el.attrs {
    if @util.ascii_lower(local_name(kv.0)) == want {
      found = Some(kv.1)
      break
    }
  }
  found
}

///|
pub fn child_elements(el : Element) -> Array[Element] {
  let out : Array[Element] = []
  for c in el.children {
    match c {
      EElement(e) => out.push(e)
      EText(_) => ()
    }
  }
  out
}

///|
pub fn child_text(el : Element) -> String {
  let mut acc = ""
  for c in el.children {
    match c {
      EText(t) => acc = acc + t
      EElement(_) => ()
    }
  }
  acc
}

///|
/// 按文档顺序拼接全部后代文本。注意与 `child_text` 的区别：后者只取直接子文本。
pub fn text_content(el : Element) -> String {
  let mut acc = ""
  for c in el.children {
    match c {
      EText(t) => acc = acc + t
      EElement(e) => acc = acc + text_content(e)
    }
  }
  acc
}

///|
pub fn find_child(el : Element, tag : String) -> Element? {
  let mut found : Element? = None
  for c in child_elements(el) {
    if tag_is(c, tag) {
      found = Some(c)
      break
    }
  }
  found
}

///|
pub fn find_all_child(el : Element, tag : String) -> Array[Element] {
  let out : Array[Element] = []
  for c in child_elements(el) {
    if tag_is(c, tag) {
      out.push(c)
    }
  }
  out
}

///|
/// 前序遍历收集所有后代元素（不含自身）。
pub fn descendants(el : Element) -> Array[Element] {
  let out : Array[Element] = []
  collect_descendants(el, out)
  out
}

///|
fn collect_descendants(el : Element, out : Array[Element]) -> Unit {
  for c in child_elements(el) {
    out.push(c)
    collect_descendants(c, out)
  }
}

///|
pub fn find_descendant(el : Element, tag : String) -> Element? {
  let mut found : Element? = None
  for d in descendants(el) {
    if tag_is(d, tag) {
      found = Some(d)
      break
    }
  }
  found
}

///|
/// 按 `id` 属性在整棵树里找元素（EPUB 的 `spine idref`、nav 锚点都要用）。
pub fn find_by_id(root : Element, id : String) -> Element? {
  let mut found : Element? = None
  if plain_attr(root, "id") == Some(id) {
    return Some(root)
  }
  for d in descendants(root) {
    if plain_attr(d, "id") == Some(id) {
      found = Some(d)
      break
    }
  }
  found
}

///|
/// 只取无前缀的 id 属性：`xml:id` 与 `id` 在 XML 里是不同属性，
/// 按 local name 混用会让 id 查找命中错误节点。
fn plain_attr(el : Element, name : String) -> String? {
  for kv in el.attrs {
    if @util.ascii_lower(kv.0) == name {
      return Some(kv.1)
    }
  }
  None
}

///|
/// 元素总数，供语料回归（manifest 断言）使用。
pub fn count_elements(root : Element) -> Int32 {
  1 + descendants(root).length()
}
