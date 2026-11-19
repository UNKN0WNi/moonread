/// 归档内路径的通用字符串操作（L1）。
///
/// 放在 L1 的原因：`container`（安全校验）与 `resource`（相对路径解析）都需要
/// 同一套规范化规则，而二者之间存在天然的循环依赖风险。路径字符串操作本身
/// 与 EPUB 语义无关，因此归入 util，避免 L2 内部互相 import。
///
/// 归档路径一律使用 `/` 分隔；`\\` 视为**非法字符**而非分隔符（ZIP 规范如此，
/// fzip 的 `is_unsafe_path` 也按此处理，见）。

///| 判断归档条目名是否不安全：绝对路径、盘符、`..` 上跳、反斜杠、空名。

///|
/// 对应「拒绝 `..` / 绝对路径（防目录穿越）」。
pub fn zip_path_is_unsafe(name : String) -> Bool {
  if name.length() == 0 {
    return true
  }
  let cs = to_chars(name)
  if cs[0] == '/' {
    return true
  }
  if contains(name, "\\") {
    return true
  }
  if starts_with(name, "~") {
    return true
  }
  // 盘符形式 `C:` / `c:/`
  if cs.length() >= 2 &&
    cs[1] == ':' &&
    ascii_lower_char(cs[0]) >= 'a' &&
    ascii_lower_char(cs[0]) <= 'z' {
    return true
  }
  for seg in split_char(name, '/') {
    if seg == ".." {
      return true
    }
  }
  false
}

///| 归一化 OPF/HTML 里出现的相对引用：折叠 `.`、`..`、重复斜杠，保证结果

///| 是归档内的规范路径。上跳越过根时**截断在根**，不报错（真实语料常见，

///|
/// 已知风险），由调用方结合 `zip_path_is_unsafe` 决定是否告警。
pub fn path_normalize(base_dir : String, r : String) -> String {
  if r.length() == 0 {
    return base_dir
  }
  let rc = to_chars(r)
  if rc[0] == '/' {
    return collapse(split_char(r, '/'), true)
  }
  let combined = if base_dir.length() == 0 { r } else { base_dir + "/" + r }
  collapse(split_char(combined, '/'), false)
}

///|
fn collapse(segments : Array[String], absolute : Bool) -> String {
  let stack : Array[String] = []
  for seg in segments {
    if seg == "" || seg == "." {
      continue
    }
    if seg == ".." {
      if stack.length() > 0 {
        let _ = stack.pop()
      } else if absolute {
        continue
      }
    } else {
      stack.push(seg)
    }
  }
  let mut acc = if absolute { "/" } else { "" }
  let mut i = 0
  while i < stack.length() {
    if i > 0 {
      acc = acc + "/"
    } else if absolute {
      ()
    }
    acc = acc + stack[i]
    i = i + 1
  }
  acc
}

///|
pub fn path_dirname(p : String) -> String {
  let cs = to_chars(p)
  let n = cs.length()
  if n == 0 {
    return ""
  }
  let mut i = n
  while i > 0 {
    if cs[i - 1] == '/' {
      break
    }
    i = i - 1
  }
  if i == 0 {
    ""
  } else if i == 1 {
    "/"
  } else {
    from_chars(slice_chars(cs, 0, i - 1))
  }
}

///|
pub fn path_basename(p : String) -> String {
  let cs = to_chars(p)
  let n = cs.length()
  let mut i = n
  while i > 0 {
    if cs[i - 1] == '/' {
      break
    }
    i = i - 1
  }
  from_chars(slice_chars(cs, i, n))
}

///|
/// 去掉查询串与片段标识（`xhtml#sec1` -> `xhtml`）。EPUB 的 `href` 常带锚点。
pub fn strip_fragment(r : String) -> String {
  let parts = split_char(r, '#')
  parts[0]
}

///|
pub fn fragment_of(r : String) -> String {
  let parts = split_char(r, '#')
  if parts.length() <= 1 {
    ""
  } else {
    let mut acc = parts[1]
    let mut i = 2
    while i < parts.length() {
      acc = acc + "#" + parts[i]
      i = i + 1
    }
    acc
  }
}

///|
/// 去掉 `file:` / `http(s):` 之外的 scheme 判定。远程资源策略见 resource 层。
pub fn has_scheme(r : String) -> Bool {
  match index_of(r, ":") {
    Some(i) => {
      let cs = to_chars(r)
      let mut k = 0
      while k < i {
        let c = cs[k]
        let ok = (c >= 'a' && c <= 'z') ||
          (c >= 'A' && c <= 'Z') ||
          (c >= '0' && c <= '9') ||
          c == '+' ||
          c == '-' ||
          c == '.'
        if !ok {
          return false
        }
        k = k + 1
      }
      i > 0
    }
    None => false
  }
}

///|
pub fn scheme_of(r : String) -> String {
  match index_of(r, ":") {
    Some(i) => from_chars(slice_chars(to_chars(r), 0, i))
    None => ""
  }
}

///|
pub fn index_of(haystack : String, needle : String) -> Int32? {
  let cs = to_chars(haystack)
  let pat = to_chars(needle)
  if pat.length() == 0 {
    return Some(0)
  }
  let mut i = 0
  while i + pat.length() <= cs.length() {
    if matches_at(cs, i, pat) {
      return Some(i)
    }
    i = i + 1
  }
  None
}

///|
/// 大小写无关的后缀匹配（图片扩展名判定用）。
pub fn ends_with_ci(s : String, suffix : String) -> Bool {
  ends_with(ascii_lower(s), ascii_lower(suffix))
}
