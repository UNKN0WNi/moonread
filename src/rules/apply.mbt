///|
/// 规则匹配与施加（L4）。
///
/// ## 元素身份
///
/// 规则效果（断页、注记、重定向）必须能回指到具体元素，但 EPUB 章节里多数
/// 元素没有 `id`。因此这里用**结构路径**做身份：`html[0]/body[0]/p[2]/img[0]`。
/// 路径在同一文档内唯一且稳定，满足 不变式 4（幂等）的前提。
///
/// ## text_regex 的真实语义
///
/// 的示例是 `"subscribe|订阅|newsletter"` —— 实际用法是**字面量
/// 交替**，不是完整正则。本实现按 `|` 分隔的字面量、ASCII 大小写无关包含匹配
/// 处理，并在文档里明确写出这个边界（docs/EPUB-COVERAGE.md）。
/// 需要完整正则时应引入生态里的正则包，而不是在这里假装支持。
#derive(Debug, Eq)
pub(all) struct RuleEffects {
  /// 需要在其前断页的元素路径（对应 `page_break_before`）
  breaks_before : Array[String]
  breaks_after : Array[String]
  /// `(元素路径, 注记标签)`
  annotations : Array[(String, String)]
  /// `(元素路径, 原 href, 新目标)`
  redirects : Array[(String, String, String)]
  /// 被移除的元素路径
  removed : Array[String]
  /// 被隐藏的元素路径
  hidden : Array[String]
  /// 规则执行过程中的降级说明（例如选择器命中 0 个元素不算错误，但要能查到）
  notes : Array[String]
  /// 实际命中的规则 id（按数组顺序，可重复）
  fired : Array[String]
}

///|
#derive(Debug, Eq)
pub(all) struct Applied {
  doc : @xml.Element
  effects : RuleEffects
}

///|
pub fn empty_effects() -> RuleEffects {
  RuleEffects::{
    breaks_before: [],
    breaks_after: [],
    annotations: [],
    redirects: [],
    removed: [],
    hidden: [],
    notes: [],
    fired: [],
  }
}

// ---------------- 选择器匹配 ----------------

///|
/// 单个复合选择器是否命中 `el`。`stack` 是从根到 `el` 的元素栈（含 `el`）。
fn compound_matches(
  c : Compound,
  stack : Array[@xml.Element],
  si : Int32,
) -> Bool {
  let el = stack[si]
  match c.tag {
    Some(t) =>
      if @util.ascii_lower(@xml.local_name(el.tag)) != @util.ascii_lower(t) {
        return false
      }
    None => ()
  }
  match c.id {
    Some(i) =>
      match @xml.attr_ci(el, "id") {
        Some(v) => if v != i { return false }
        None => return false
      }
    None => ()
  }
  if c.classes.length() > 0 {
    let class_attr = match @xml.attr_ci(el, "class") {
      Some(v) => v
      None => ""
    }
    for want in c.classes {
      if !has_word(class_attr, want) {
        return false
      }
    }
  }
  for a in c.attrs {
    let name = a.0
    let op = a.1
    let want = a.2
    let actual = @xml.attr_ci(el, name)
    match actual {
      None => return false
      Some(v) =>
        if op == "exists" {
          ()
        } else if op == "=" {
          if v != want {
            return false
          }
        } else if op == "^=" {
          if !@util.starts_with(v, want) {
            return false
          }
        } else if op == "$=" {
          if !@util.ends_with(v, want) {
            return false
          }
        } else if op == "*=" {
          if !@util.contains(v, want) {
            return false
          }
        } else if op == "~=" {
          if !has_word(v, want) {
            return false
          }
        } else {
          return false
        }
    }
  }
  for ps in c.pseudo {
    if ps == "first-child" {
      if !is_nth_child(stack, si, 0) {
        return false
      }
    } else if ps == "last-child" {
      if !is_nth_child(stack, si, 1) {
        return false
      }
    } else if ps == "root" {
      if si != 0 {
        return false
      }
    }
  }
  true
}

///|
fn has_word(text : String, want : String) -> Bool {
  for w in @util.split_char(text, ' ') {
    if w == want {
      return true
    }
  }
  for w in @util.split_char(text, '\t') {
    if w == want {
      return true
    }
  }
  false
}

///|
/// `which` = 0 表示第一个元素子节点，1 表示最后一个。
fn is_nth_child(stack : Array[@xml.Element], si : Int32, which : Int32) -> Bool {
  if si == 0 {
    return which == 0
  }
  let parent = stack[si - 1]
  let kids = @xml.child_elements(parent)
  let self_el = stack[si]
  let mut idx = -1
  let mut i = 0
  while i < kids.length() {
    if kids[i] == self_el {
      idx = i
      break
    }
    i = i + 1
  }
  if idx < 0 {
    false
  } else if which == 0 {
    idx == 0
  } else {
    idx == kids.length() - 1
  }
}

///|
/// 从右往左匹配整条选择器。
fn matches_selector(sel : Selector, stack : Array[@xml.Element]) -> Bool {
  let n = sel.parts.length()
  if n == 0 || stack.length() == 0 {
    return false
  }
  match_suffix(sel, n - 1, stack, stack.length() - 1)
}

///|
fn match_suffix(
  sel : Selector,
  pi : Int32,
  stack : Array[@xml.Element],
  si : Int32,
) -> Bool {
  if si < 0 {
    return false
  }
  if !compound_matches(sel.parts[pi], stack, si) {
    return false
  }
  if pi == 0 {
    return true
  }
  let comb = sel.combinators[pi - 1]
  match comb {
    Child => match_suffix(sel, pi - 1, stack, si - 1)
    Descendant => {
      let mut k = si - 1
      while k >= 0 {
        if match_suffix(sel, pi - 1, stack, k) {
          return true
        }
        k = k - 1
      }
      false
    }
  }
}

///|
/// 任一选择器命中即为命中（逗号选择器列表）。
pub fn rule_matches(rule : Rule, stack : Array[@xml.Element]) -> Bool {
  let mut hit = false
  for sel in rule.match_.selector {
    if matches_selector(sel, stack) {
      hit = true
    }
  }
  if !hit {
    return false
  }
  if !rule.match_.has_text_regex {
    return true
  }
  // text_regex：作用于该元素及其后代的文本内容
  let el = stack[stack.length() - 1]
  let text = @xml.text_content(el)
  matches_alternation(text, rule.match_.text_regex)
}

///|
/// `|` 分隔的字面量交替，ASCII 大小写无关包含匹配。
pub fn matches_alternation(text : String, pattern : String) -> Bool {
  if pattern.length() == 0 {
    return true
  }
  let hay = @util.ascii_lower(text)
  for alt in @util.split_char(pattern, '|') {
    let needle = @util.ascii_lower(@util.trim(alt))
    if needle.length() == 0 {
      continue
    }
    if @util.contains(hay, needle) {
      return true
    }
  }
  false
}

// ---------------- 施加 ----------------

///|
/// 按数组顺序依次应用规则；后一条看到前一条的结果。
pub fn apply_rules(root : @xml.Element, set : RuleSet) -> Applied {
  let effects = empty_effects()
  let stack : Array[@xml.Element] = []
  let doc = rebuild(root, "", stack, set, effects)
  Applied::{ doc, effects, }
}

///|
/// `my_path` 为空串表示文档根元素。**路径编号规则由 `@xml.child_path` 统一提供**：
/// 只数元素子节点、文本不占序号；渲染侧走同一函数，断页对接才成立。
fn rebuild(
  el : @xml.Element,
  my_path : String,
  parent_stack : Array[@xml.Element],
  set : RuleSet,
  effects : RuleEffects,
) -> @xml.Element {
  let stack = push_copy(parent_stack, el)
  // 1) 先递归重建子元素；被 Remove 的子树在父层丢弃
  let children : Array[@xml.Node] = []
  let mut idx = 0
  for c in el.children {
    match c {
      @xml.EText(t) => children.push(@xml.EText(t))
      @xml.EElement(child) => {
        let cp = @xml.child_path(my_path, child.tag, idx)
        idx = idx + 1
        let kept = rebuild(child, cp, stack, set, effects)
        if !contains_path(effects.removed, cp) {
          children.push(@xml.EElement(kept))
        }
      }
    }
  }
  let mut out = @xml.Element::{ tag: el.tag, attrs: el.attrs, children, }
  // 2) 再对本元素施加规则（顺序即 的数组顺序）
  if my_path.length() > 0 {
    for r in set.rules {
      if rule_matches(r, stack) {
        effects.fired.push(r.id)
        out = apply_one(r, my_path, out, effects)
      }
    }
  }
  out
}

///|
fn push_copy(
  stack : Array[@xml.Element],
  el : @xml.Element,
) -> Array[@xml.Element] {
  let out : Array[@xml.Element] = []
  for e in stack {
    out.push(e)
  }
  out.push(el)
  out
}

///|
fn contains_path(arr : Array[String], p : String) -> Bool {
  let mut found = false
  for x in arr {
    if x == p {
      found = true
    }
  }
  found
}

///|
fn apply_one(
  r : Rule,
  path : String,
  el : @xml.Element,
  effects : RuleEffects,
) -> @xml.Element {
  match r.action {
    Remove => {
      effects.removed.push(path)
      el
    }
    Hide => {
      effects.hidden.push(path)
      merge_style(el, "display", "none")
    }
    SetStyle(pairs) => {
      let mut out = el
      for kv in pairs {
        out = merge_style(out, kv.0, kv.1)
      }
      out
    }
    PageBreakBefore => {
      effects.breaks_before.push(path)
      el
    }
    PageBreakAfter => {
      effects.breaks_after.push(path)
      el
    }
    ReplaceText(find, repl) => replace_in_subtree(el, find, repl)
    Annotate(label) => {
      // 真正改写 DOM：把注记标签写到属性上，渲染宿主可据此画边注/角标。
      // 曾经这里只 push effects、原样返回 el，动作等于空转。
      effects.annotations.push((path, label))
      set_attr(el, "data-moonread-note", label)
    }
    Redirect(target) => {
      let href = match @xml.attr_ci(el, "href") {
        Some(v) => v
        None => ""
      }
      // 真正改写 DOM：把 href 指向 target，链接重定向才生效。
      effects.redirects.push((path, href, target))
      set_attr(el, "href", target)
    }
  }
}

///|
/// 设置/覆盖一个属性（按 local_name 大小写无关匹配），返回新元素。
/// 与 `merge_style` 同一思路，但作用于任意属性。
pub fn set_attr(
  el : @xml.Element,
  name : String,
  value : String,
) -> @xml.Element {
  let want = @util.ascii_lower(name)
  let attrs : Array[(String, String)] = []
  let mut replaced = false
  for kv in el.attrs {
    if @util.ascii_lower(@xml.local_name(kv.0)) == want {
      attrs.push((kv.0, value))
      replaced = true
    } else {
      attrs.push(kv)
    }
  }
  if !replaced {
    attrs.push((name, value))
  }
  @xml.Element::{ tag: el.tag, attrs, children: el.children, }
}

///|
/// 把样式写进 `style` 属性（crater 的 style 桥接受内联样式，`set_style`）。
pub fn merge_style(
  el : @xml.Element,
  prop : String,
  value : String,
) -> @xml.Element {
  let decl = @util.ascii_lower(prop) + ":" + value
  let old = match @xml.attr_ci(el, "style") {
    Some(v) => v
    None => ""
  }
  let merged = if old.length() == 0 {
    decl
  } else {
    drop_prop(old, prop) + "; " + decl
  }
  let attrs : Array[(String, String)] = []
  let mut replaced = false
  for kv in el.attrs {
    if @util.ascii_lower(@xml.local_name(kv.0)) == "style" {
      attrs.push((kv.0, merged))
      replaced = true
    } else {
      attrs.push(kv)
    }
  }
  if !replaced {
    attrs.push(("style", merged))
  }
  @xml.Element::{ tag: el.tag, attrs, children: el.children, }
}

///|
fn drop_prop(style : String, prop : String) -> String {
  let want = @util.ascii_lower(prop) + ":"
  let out : Array[String] = []
  for d in @util.split_char(style, ';') {
    let t = @util.trim(d)
    if t.length() == 0 {
      continue
    }
    if @util.starts_with(@util.ascii_lower(t), want) {
      continue
    }
    out.push(t)
  }
  let mut acc = ""
  let mut i = 0
  while i < out.length() {
    if i > 0 {
      acc = acc + "; "
    }
    acc = acc + out[i]
    i = i + 1
  }
  acc
}

///|
fn replace_in_subtree(
  el : @xml.Element,
  find : String,
  repl : String,
) -> @xml.Element {
  let children : Array[@xml.Node] = []
  for c in el.children {
    match c {
      @xml.EText(t) =>
        children.push(@xml.EText(@util.replace_all(t, find, repl)))
      @xml.EElement(e) =>
        children.push(@xml.EElement(replace_in_subtree(e, find, repl)))
    }
  }
  @xml.Element::{ tag: el.tag, attrs: el.attrs, children, }
}

///|
/// 某条规则的命中次数，供「规则是否真的生效」的可诊断性（精神）。
pub fn fired_count(effects : RuleEffects, rule_id : String) -> Int32 {
  let mut n = 0
  for f in effects.fired {
    if f == rule_id {
      n = n + 1
    }
  }
  n
}

///|
/// 一条都没命中的规则 id（降级提示，不是错误）。
pub fn unfired_rules(set : RuleSet, effects : RuleEffects) -> Array[String] {
  let out : Array[String] = []
  for r in set.rules {
    if fired_count(effects, r.id) == 0 {
      out.push(r.id)
    }
  }
  out
}
