/// JSON 规则引擎。
///
/// 语义要点：
/// - 规则**按数组顺序**依次应用（），命中即执行；后一条看到前一条的
///   结果（例如 `remove` 之后不会有元素再匹配它）。
/// - 未知动作类型**加载时即报错并指出规则 id**（验收项），不静默跳过。
/// - 元素身份用「结构路径」表示（`html/body/p[2]/img`），因为 EPUB 章节里的
///   元素大多没有 `id`，而规则效果必须能稳定回指到渲染层。

///|
/// 选择器：一个「复合选择器序列 + 组合关系」。
#derive(Debug, Eq)
pub(all) struct Compound {
  /// `None` 表示通配 `*`
  tag : String?
  id : String?
  classes : Array[String]
  /// `(属性名, 匹配方式, 值)`；`op` 取 `=` / `^=` / `$=` / `*=`，值为空串表示「仅存在」
  attrs : Array[(String, String, String)]
  pseudo : Array[String]
}

///|
#derive(Debug, Eq)
pub(all) enum Combinator {
  Descendant
  Child
}

///|
#derive(Debug, Eq)
pub(all) struct Selector {
  /// 从右往左匹配用的序列；`combinators[i]` 描述 `parts[i]` 与其父的关系
  parts : Array[Compound]
  combinators : Array[Combinator]
}

///|
#derive(Debug, Eq)
pub(all) struct RuleMatch {
  selector : Array[Selector]
  text_regex : String
  has_text_regex : Bool
}

///|
/// 首发范围的 9 种动作。
#derive(Debug, Eq)
pub(all) enum Action {
  Remove
  Hide
  SetStyle(Array[(String, String)])
  PageBreakBefore
  PageBreakAfter
  ReplaceText(String, String)
  Annotate(String)
  Redirect(String)
}

///|
#derive(Debug, Eq)
pub(all) struct Rule {
  id : String
  match_ : RuleMatch
  action : Action
}

///|
#derive(Debug, Eq)
pub(all) struct RuleSet {
  version : Int32
  rules : Array[Rule]
}

///|
let rule_fields : ReadOnlyArray[String] = ["id", "match", "action"]

///|
let match_fields : ReadOnlyArray[String] = ["selector", "text_regex"]

///|
let action_fields : ReadOnlyArray[String] = [
  "type", "style", "find", "replace", "label", "target",
]

// ---------------- 加载 ----------------

///|
pub fn load_rules(text : String) -> Result[RuleSet, String] {
  match @jsonio.parse(text) {
    Err(e) => Err("规则文件不是合法 JSON：" + e)
    Ok(root) => load_rules_json(root)
  }
}

///|
pub fn load_rules_json(root : @jsonio.Json) -> Result[RuleSet, String] {
  match
    @jsonio.reject_unknown_fields(root, ["$schema", "version", "rules"], "$") {
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
      let items = match @jsonio.obj_get(root, "rules") {
        None => return Err("$.rules 是必填数组")
        Some(v) =>
          match v {
            @jsonio.JArr(a) => a
            _ => return Err("$.rules 必须是数组")
          }
      }
      let out : Array[Rule] = []
      let mut i = 0
      while i < items.length() {
        match parse_rule(items[i], i) {
          Err(e) => return Err(e)
          Ok(r) => out.push(r)
        }
        i = i + 1
      }
      Ok(RuleSet::{ version, rules: out, })
    }
  }
}

///|
fn parse_rule(v : @jsonio.Json, index : Int32) -> Result[Rule, String] {
  let fallback_id = "$.rules[" + index.to_string() + "]"
  match @jsonio.reject_unknown_fields(v, rule_fields, fallback_id) {
    Err(e) => return Err(e)
    Ok(_) => {
      let id = match @jsonio.obj_get(v, "id") {
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => s
            None => return Err(fallback_id + ".id 必须是字符串")
          }
        None => fallback_id
      }
      let path = "$.rules[" + id + "]"
      let m = match @jsonio.obj_get(v, "match") {
        None => return Err(path + " 缺少 match")
        Some(x) =>
          match parse_match(x, path) {
            Err(e) => return Err(e)
            Ok(mm) => mm
          }
      }
      let a = match @jsonio.obj_get(v, "action") {
        None => return Err(path + " 缺少 action")
        Some(x) =>
          match parse_action(x, path, id) {
            Err(e) => return Err(e)
            Ok(ac) => ac
          }
      }
      Ok(Rule::{ id, match_: m, action: a, })
    }
  }
}

///|
fn parse_match(v : @jsonio.Json, path : String) -> Result[RuleMatch, String] {
  match @jsonio.reject_unknown_fields(v, match_fields, path + ".match") {
    Err(e) => return Err(e)
    Ok(_) => {
      let sel = match @jsonio.obj_get(v, "selector") {
        None => return Err(path + ".match 缺少 selector")
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => s
            None => return Err(path + ".match.selector 必须是字符串")
          }
      }
      let selectors : Array[Selector] = []
      for part in @util.split_char(sel, ',') {
        let t = @util.trim(part)
        if t.length() == 0 {
          continue
        }
        match parse_selector(t) {
          Err(e) =>
            return Err(path + ".match.selector '" + t + "' 无法解析：" + e)
          Ok(s) => selectors.push(s)
        }
      }
      if selectors.length() == 0 {
        return Err(path + ".match.selector 为空")
      }
      let mut text_regex = ""
      let mut has_text_regex = false
      match @jsonio.obj_get(v, "text_regex") {
        None => ()
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => {
              text_regex = s
              has_text_regex = true
            }
            None => return Err(path + ".match.text_regex 必须是字符串")
          }
      }
      Ok(RuleMatch::{ selector: selectors, text_regex, has_text_regex, })
    }
  }
}

///|
fn parse_action(
  v : @jsonio.Json,
  path : String,
  rule_id : String,
) -> Result[Action, String] {
  match @jsonio.reject_unknown_fields(v, action_fields, path + ".action") {
    Err(e) => return Err(e)
    Ok(_) => {
      let typ = match @jsonio.obj_get(v, "type") {
        None => return Err(path + ".action 缺少 type")
        Some(x) =>
          match @jsonio.as_str(x) {
            Some(s) => s
            None => return Err(path + ".action.type 必须是字符串")
          }
      }
      if typ == "remove" {
        Ok(Remove)
      } else if typ == "hide" {
        Ok(Hide)
      } else if typ == "set_style" {
        match @jsonio.obj_get(v, "style") {
          None => Err(path + ".action(type=set_style) 缺少 style")
          Some(s) =>
            match parse_style_map(s, path) {
              Err(e) => return Err(e)
              Ok(pairs) => Ok(SetStyle(pairs))
            }
        }
      } else if typ == "page_break_before" {
        Ok(PageBreakBefore)
      } else if typ == "page_break_after" {
        Ok(PageBreakAfter)
      } else if typ == "replace_text" {
        let f = match @jsonio.require_str(v, "find", path + ".action") {
          Err(e) => return Err(e)
          Ok(s) => s
        }
        let r = match @jsonio.require_str(v, "replace", path + ".action") {
          Err(e) => return Err(e)
          Ok(s) => s
        }
        Ok(ReplaceText(f, r))
      } else if typ == "annotate" {
        match @jsonio.require_str(v, "label", path + ".action") {
          Err(e) => return Err(e)
          Ok(s) => Ok(Annotate(s))
        }
      } else if typ == "redirect" {
        match @jsonio.require_str(v, "target", path + ".action") {
          Err(e) => return Err(e)
          Ok(s) => Ok(Redirect(s))
        }
      } else {
        // 验收项：未知动作类型报错并指出规则 id
        Err(
          path +
          ".action.type '" +
          typ +
          "' 是未知动作（规则 id='" +
          rule_id +
          "'）。支持：remove / hide / set_style / page_break_before / page_break_after / replace_text / annotate / redirect",
        )
      }
    }
  }
}

///|
fn parse_style_map(
  s : @jsonio.Json,
  path : String,
) -> Result[Array[(String, String)], String] {
  match s {
    @jsonio.JObj(fields) => {
      if fields.length() == 0 {
        return Err(path + ".action.style 不能是空对象")
      }
      let out : Array[(String, String)] = []
      for kv in fields {
        match @jsonio.as_str(kv.1) {
          Some(v) => out.push((kv.0, v))
          None =>
            return Err(
              path + ".action.style." + kv.0 + " 的值必须是字符串",
            )
        }
      }
      Ok(out)
    }
    _ => Err(path + ".action.style 必须是对象")
  }
}

// ---------------- 选择器解析（子集） ----------------

///| 支持：`tag` / `*` / `#id` / `.class`（可多个）/ `[attr]` / `[attr=v]`

///| / `[attr^=v]` / `[attr$=v]` / `[attr*=v]` / `:first-child` / `:last-child`

///| / 后代（空格）/ 子代（`>`）/ 逗号选择器列表。

///| 不支持：伪类函数（`:nth-child(2n)`）、相邻兄弟（`+`/`~`）、`:not()`。

///|
/// 这些在 EPUB 规则里收益低、复杂度高，明确写进 docs 而不是假装支持。
pub fn parse_selector(text : String) -> Result[Selector, String] {
  let toks = match tokenize_selector(text) {
    Ok(__try_v_1) => __try_v_1
    Err(__try_e_1) => return Err(__try_e_1)
  }
  if toks.parts.length() == 0 {
    return Err("选择器为空")
  }
  Ok(toks)
}

///|
priv struct SelParser {
  src : Array[Char]
  mut pos : Int32
}

///| 先按空白与 `>` 切成 token 序列，再逐个解析复合选择器。

///|
/// 这样组合关系（Child / Descendant）与选择器本体分离，状态机不会互相纠缠。
fn tokenize_selector(text : String) -> Result[Selector, String] {
  let spaced = @util.replace_all(text, ">", " > ")
  let tokens = split_on_space(spaced)
  let parts : Array[Compound] = []
  let combinators : Array[Combinator] = []
  let mut pending_child = false
  let mut have_prev = false
  for t in tokens {
    if t == ">" {
      if !have_prev {
        return Err("选择器以 '>' 开头")
      }
      pending_child = true
    } else {
      let c = match parse_compound(t) {
        Ok(__try_v_2) => __try_v_2
        Err(__try_e_2) => return Err(__try_e_2)
      }
      if have_prev {
        combinators.push(if pending_child { Child } else { Descendant })
      }
      pending_child = false
      have_prev = true
      parts.push(c)
    }
  }
  if parts.length() == 0 {
    return Err("选择器为空")
  }
  Ok(Selector::{ parts, combinators, })
}

///|
fn split_on_space(s : String) -> Array[String] {
  let out : Array[String] = []
  let cs = @util.to_chars(s)
  let mut cur : Array[Char] = []
  let mut i = 0
  while i < cs.length() {
    let c = cs[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      if cur.length() > 0 {
        out.push(@util.from_chars(cur))
        cur = []
      }
    } else {
      cur.push(c)
    }
    i = i + 1
  }
  if cur.length() > 0 {
    out.push(@util.from_chars(cur))
  }
  out
}

///|
fn parse_compound(token : String) -> Result[Compound, String] {
  let p = SelParser::{ src: @util.to_chars(token), pos: 0, }
  let tag : String? = read_tag(p)
  let ids : Array[String] = []
  let classes : Array[String] = []
  let attrs : Array[(String, String, String)] = []
  let pseudo : Array[String] = []
  while p.pos < p.src.length() {
    let c = p.src[p.pos]
    if c == '#' {
      p.pos = p.pos + 1
      let v = match read_until_special(p) {
        Ok(__try_v_3) => __try_v_3
        Err(__try_e_3) => return Err(__try_e_3)
      }
      if v.length() == 0 {
        return Err("'" + token + "' 的 '#' 之后缺少 id")
      }
      if ids.length() > 0 {
        return Err("'" + token + "' 出现多个 '#'")
      }
      ids.push(v)
    } else if c == '.' {
      p.pos = p.pos + 1
      let v = match read_until_special(p) {
        Ok(__try_v_4) => __try_v_4
        Err(__try_e_4) => return Err(__try_e_4)
      }
      if v.length() == 0 {
        return Err("'" + token + "' 的 '.' 之后缺少类名")
      }
      classes.push(v)
    } else if c == '[' {
      p.pos = p.pos + 1
      match parse_attr(p, token) {
        Err(e) => return Err(e)
        Ok(a) => attrs.push(a)
      }
    } else if c == ':' {
      p.pos = p.pos + 1
      let v = match read_until_special(p) {
        Ok(__try_v_5) => __try_v_5
        Err(__try_e_5) => return Err(__try_e_5)
      }
      if v.length() == 0 {
        return Err("'" + token + "' 的 ':' 之后缺少伪类名")
      }
      if v != "first-child" && v != "last-child" && v != "root" {
        return Err(
          "'" +
          token +
          "' 用了不支持的伪类 ':" +
          v +
          "'（仅支持 :first-child / :last-child / :root）",
        )
      }
      pseudo.push(v)
    } else {
      return Err(
        "'" + token + "' 含意外字符 '" + @util.char_to_string(c) + "'",
      )
    }
  }
  if tag == None &&
    ids.length() == 0 &&
    classes.length() == 0 &&
    attrs.length() == 0 &&
    pseudo.length() == 0 {
    return Err("空选择器片段")
  }
  let id = if ids.length() > 0 { ids[0] } else { "" }
  Ok(Compound::{
    tag,
    id: if ids.length() > 0 {
      Some(id)
    } else {
      None
    },
    classes,
    attrs,
    pseudo,
  })
}

///|
fn read_tag(p : SelParser) -> String? {
  let start = p.pos
  let n = p.src.length()
  if p.pos < n && p.src[p.pos] == '*' {
    p.pos = p.pos + 1
    return None
  }
  while p.pos < n && is_tag_char(p.src[p.pos]) {
    p.pos = p.pos + 1
  }
  if p.pos == start {
    None
  } else {
    Some(@util.from_chars(@util.slice_chars(p.src, start, p.pos)))
  }
}

///|
fn is_tag_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '-' ||
  c == '_'
}

///|
fn read_until_special(p : SelParser) -> Result[String, String] {
  let start = p.pos
  let n = p.src.length()
  while p.pos < n {
    let c = p.src[p.pos]
    if c == '#' || c == '.' || c == '[' || c == ':' || c == ']' || c == ' ' {
      break
    }
    p.pos = p.pos + 1
  }
  if p.pos == start {
    Err("选择器片段缺少名称")
  } else {
    Ok(@util.from_chars(@util.slice_chars(p.src, start, p.pos)))
  }
}

///| `[attr]` / `[attr=v]` / `[attr^=v]` / `[attr$=v]` / `[attr*=v]`。

///|
/// 值可带引号也可不带（不带时到 `]` 为止）。
fn parse_attr(
  p : SelParser,
  token : String,
) -> Result[(String, String, String), String] {
  let name = match read_until_equals(p) {
    Ok(__try_v_6) => __try_v_6
    Err(__try_e_6) => return Err(__try_e_6)
  }
  if name.length() == 0 {
    return Err("'" + token + "' 的属性选择器缺少属性名")
  }
  if p.pos >= p.src.length() || p.src[p.pos] == ']' {
    if p.pos >= p.src.length() {
      return Err("'" + token + "' 的属性选择器缺少 ']'")
    }
    p.pos = p.pos + 1
    return Ok((name, "exists", ""))
  }
  let op_start = p.pos
  let op = if p.src[op_start] == '=' {
    "="
  } else if p.src[op_start] == '^' {
    "^="
  } else if p.src[op_start] == '$' {
    "$="
  } else if p.src[op_start] == '*' {
    "*="
  } else if p.src[op_start] == '~' {
    "~="
  } else {
    return Err("'" + token + "' 的属性选择器含意外字符")
  }
  p.pos = p.pos + 1
  if p.pos >= p.src.length() || p.src[p.pos] != '=' {
    return Err("'" + token + "' 的属性选择器缺少 '='")
  }
  p.pos = p.pos + 1
  let value = match read_attr_value_text(p, token) {
    Ok(__try_v_7) => __try_v_7
    Err(__try_e_7) => return Err(__try_e_7)
  }
  Ok((name, op, value))
}

///|
fn read_until_equals(p : SelParser) -> Result[String, String] {
  let start = p.pos
  let n = p.src.length()
  while p.pos < n {
    let c = p.src[p.pos]
    if c == '=' || c == '^' || c == '$' || c == '*' || c == '~' || c == ']' {
      break
    }
    p.pos = p.pos + 1
  }
  Ok(@util.from_chars(@util.slice_chars(p.src, start, p.pos)))
}

///|
fn read_attr_value_text(
  p : SelParser,
  token : String,
) -> Result[String, String] {
  if p.pos >= p.src.length() {
    return Err("'" + token + "' 的属性值未结束")
  }
  let q = p.src[p.pos]
  if q == '"' || q == '\'' {
    p.pos = p.pos + 1
    let buf : Array[Char] = []
    let mut closed = false
    while p.pos < p.src.length() {
      let c = p.src[p.pos]
      p.pos = p.pos + 1
      if c == q {
        closed = true
        break
      }
      buf.push(c)
    }
    if !closed {
      return Err("'" + token + "' 的属性值引号未闭合")
    }
    if p.pos >= p.src.length() || p.src[p.pos] != ']' {
      return Err("'" + token + "' 的属性选择器缺少 ']'")
    }
    p.pos = p.pos + 1
    Ok(@util.from_chars(buf))
  } else {
    let start = p.pos
    while p.pos < p.src.length() && p.src[p.pos] != ']' {
      p.pos = p.pos + 1
    }
    if p.pos >= p.src.length() {
      return Err("'" + token + "' 的属性选择器缺少 ']'")
    }
    let v = @util.from_chars(@util.slice_chars(p.src, start, p.pos))
    p.pos = p.pos + 1
    Ok(v)
  }
}

///|
/// 本实现认识的全部动作类型，供文档与 schema 对齐检查。
pub fn supported_action_types() -> Array[String] {
  [
    "remove", "hide", "set_style", "page_break_before", "page_break_after", "replace_text",
    "annotate", "redirect",
  ]
}
