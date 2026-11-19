/// 字符与字符串工具。
///
/// 设计约束：本包属于 L1，**不得依赖 L2 及以上**。
/// 之所以自带这些工具而不是直接调用标准库对应函数，是为了把「跨工具链版本
/// 最容易漂移的三个操作」（`Char -> String`、`Char -> Int`、`Int -> Char`）
/// 收敛到本文件的三个函数里。换版本时只需要改这三处。

///| Char 转 String 的唯一入口。

///|
/// 若工具链提供 `String::from_char`，把函数体换成它即可。
pub fn char_to_string(c : Char) -> String {
  c.to_string()
}

///|
/// Char 的码位值。
pub fn char_to_int(c : Char) -> Int32 {
  c.to_int()
}

///|
/// 码位转 Char；代理区与越界一律返回 None，不抛异常（验收项：无 panic）。
pub fn codepoint_to_char(cp : Int32) -> Char? {
  if cp < 0 || cp > 0x10ffff {
    None
  } else if cp >= 0xd800 && cp <= 0xdfff {
    None
  } else {
    cp.to_char()
  }
}

///|
/// 自然序比较结果。`Ordering` 不在当前工具链的内建类型里，这里自行定义。
#derive(Eq, Debug)
pub(all) enum Ordering {
  Less
  Equal
  Greater
}

///| 字符串拆成字符数组。后续所有解析器都在 `Array[Char]` 上做随机访问，

///|
/// 避免 `String` 切片返回 `StringView` 带来的类型不一致（已知踩坑）。
pub fn to_chars(s : String) -> Array[Char] {
  let out : Array[Char] = []
  for c in s {
    out.push(c)
  }
  out
}

///|
/// 字符数组拼回字符串。
pub fn from_chars(cs : Array[Char]) -> String {
  let mut acc = ""
  for c in cs {
    acc = acc + char_to_string(c)
  }
  acc
}

///|
/// 按**字符**下标取字符，越界返回 None。
pub fn char_at(s : String, i : Int32) -> Char? {
  let cs = to_chars(s)
  if i >= 0 && i < cs.length() {
    Some(cs[i])
  } else {
    None
  }
}

///| 按**字符**下标取子串，越界自动夹住。

///| 刻意不用 `s[a:b]`：那返回 `StringView`（已知踩坑），且按下标语义在

///|
/// 不同后端上是字节位还是码位位不统一，这里固定为码位位。
pub fn slice_string(s : String, a : Int32, b : Int32) -> String {
  from_chars(slice_chars(to_chars(s), a, b))
}

///| ASCII 小写化。非 ASCII 字符原样返回——EPUB 的属性名、标签名、媒体类型

///|
/// 全部是 ASCII，不需要完整的 Unicode 大小写折叠。
pub fn ascii_lower_char(c : Char) -> Char {
  if c >= 'A' && c <= 'Z' {
    match codepoint_to_char(char_to_int(c) + 32) {
      Some(l) => l
      None => c
    }
  } else {
    c
  }
}

///|
pub fn ascii_lower(s : String) -> String {
  let cs = to_chars(s)
  let out : Array[Char] = []
  for c in cs {
    out.push(ascii_lower_char(c))
  }
  from_chars(out)
}

///|
/// 去掉首尾空白（XML/JSON 的空白定义：空格、制表、换行、回车）。
pub fn is_xml_space(c : Char) -> Bool {
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u{0c}'
}

///|
pub fn trim(s : String) -> String {
  let cs = to_chars(s)
  let n = cs.length()
  if n == 0 {
    return s
  }
  let mut a = 0
  while a < n && is_xml_space(cs[a]) {
    a = a + 1
  }
  let mut b = n
  while b > a && is_xml_space(cs[b - 1]) {
    b = b - 1
  }
  from_chars(slice_chars(cs, a, b))
}

///|
/// 在 `Array[Char]` 上取半开区间 `[a, b)`，越界自动夹住。
pub fn slice_chars(cs : Array[Char], a : Int32, b : Int32) -> Array[Char] {
  let n = cs.length()
  let lo = if a < 0 { 0 } else if a > n { n } else { a }
  let hi = if b < lo { lo } else if b > n { n } else { b }
  let out : Array[Char] = []
  let mut i = lo
  while i < hi {
    out.push(cs[i])
    i = i + 1
  }
  out
}

///|
pub fn starts_with(s : String, prefix : String) -> Bool {
  let a = to_chars(s)
  let b = to_chars(prefix)
  if b.length() > a.length() {
    return false
  }
  let mut i = 0
  while i < b.length() {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///|
pub fn ends_with(s : String, suffix : String) -> Bool {
  let a = to_chars(s)
  let b = to_chars(suffix)
  let la = a.length()
  let lb = b.length()
  if lb > la {
    return false
  }
  let mut i = 0
  while i < lb {
    if a[la - lb + i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

///| 按单个分隔字符切分。保留空段（`"a,,b"` 切成 `["a", "", "b"]`），

///|
/// 因为 EPUB 的 `href` 与 OPF 的 `idrefs` 语义都依赖段数。
pub fn split_char(s : String, sep : Char) -> Array[String] {
  let cs = to_chars(s)
  let out : Array[String] = []
  let mut cur : Array[Char] = []
  let mut i = 0
  while i < cs.length() {
    if cs[i] == sep {
      out.push(from_chars(cur))
      cur = []
    } else {
      cur.push(cs[i])
    }
    i = i + 1
  }
  out.push(from_chars(cur))
  out
}

///|
pub fn split_str(s : String, sep : String) -> Array[String] {
  if sep.length() == 0 {
    return [s]
  }
  let cs = to_chars(s)
  let ps = to_chars(sep)
  let out : Array[String] = []
  let mut cur : Array[Char] = []
  let mut i = 0
  while i < cs.length() {
    if matches_at(cs, i, ps) {
      out.push(from_chars(cur))
      cur = []
      i = i + ps.length()
    } else {
      cur.push(cs[i])
      i = i + 1
    }
  }
  out.push(from_chars(cur))
  out
}

///|
/// 子串包含判定。错误信息与规则匹配都要用，故放在 L1。
pub fn contains(haystack : String, needle : String) -> Bool {
  let cs = to_chars(haystack)
  let pat = to_chars(needle)
  let mut i = 0
  while i + pat.length() <= cs.length() {
    if matches_at(cs, i, pat) {
      return true
    }
    i = i + 1
  }
  false
}

///| 用换行连接若干行，末尾不带换行。测试语料与 fixture 生成器都用它，

///|
/// 以避免依赖多行字符串字面量（跨工具链版本的转义规则不稳定）。
pub fn join_nl(lines : Array[String]) -> String {
  let mut acc = ""
  let mut i = 0
  while i < lines.length() {
    if i > 0 {
      acc = acc + "\n"
    }
    acc = acc + lines[i]
    i = i + 1
  }
  acc
}

///|
pub fn matches_at(cs : Array[Char], at : Int32, pat : Array[Char]) -> Bool {
  let n = cs.length()
  let m = pat.length()
  if m == 0 {
    return true
  }
  if at + m > n {
    return false
  }
  let mut k = 0
  while k < m {
    if cs[at + k] != pat[k] {
      return false
    }
    k = k + 1
  }
  true
}

///|
pub fn replace_all(s : String, from : String, to : String) -> String {
  if from.length() == 0 {
    return s
  }
  let cs = to_chars(s)
  let pat = to_chars(from)
  let rep = to_chars(to)
  let out : Array[Char] = []
  let mut i = 0
  while i < cs.length() {
    if matches_at(cs, i, pat) {
      for c in rep {
        out.push(c)
      }
      i = i + pat.length()
    } else {
      out.push(cs[i])
      i = i + 1
    }
  }
  from_chars(out)
}

///|
/// 十六进制位的数值；非法字符返回 None。
pub fn hex_digit_value(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(char_to_int(c) - char_to_int('0'))
  } else if c >= 'a' && c <= 'f' {
    Some(char_to_int(c) - char_to_int('a') + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(char_to_int(c) - char_to_int('A') + 10)
  } else {
    None
  }
}

///|
pub fn digit_value(c : Char) -> Int32? {
  if c >= '0' && c <= '9' {
    Some(char_to_int(c) - char_to_int('0'))
  } else {
    None
  }
}

///|
/// 0..15 转十六进制显示字符（小写）。越界返回 `'0'`，调用方应先做范围检查。
pub fn hex_digit_char(v : Int32) -> Char {
  if v < 0 || v > 15 {
    '0'
  } else if v < 10 {
    match codepoint_to_char(char_to_int('0') + v) {
      Some(c) => c
      None => '0'
    }
  } else {
    match codepoint_to_char(char_to_int('a') + v - 10) {
      Some(c) => c
      None => '0'
    }
  }
}

///| 双精度转整数当且仅当文本形式就是纯整数。

///| 刻意通过 `to_string` 判定而不是用平台相关的 `as_int`/`floor`，

///|
/// 这样三端（native/js/wasm-gc）的判定结果与 的逐字节一致要求同源。
pub fn double_as_int(d : Double) -> Int32? {
  parse_int(d.to_string())
}

///|
/// 严格整数解析：允许前导 `+`/`-` 与首尾空白，其余任何非法字符返回 None。
pub fn parse_int(s : String) -> Int32? {
  let cs = to_chars(trim(s))
  let n = cs.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if cs[0] == '+' || cs[0] == '-' {
    neg = cs[0] == '-'
    i = 1
  }
  if i >= n {
    return None
  }
  let mut acc = 0
  while i < n {
    match digit_value(cs[i]) {
      Some(d) => acc = acc * 10 + d
      None => return None
    }
    i = i + 1
  }
  Some(if neg { 0 - acc } else { acc })
}

///| 严格浮点解析（JSON 数字文法）。用「整数部分 + 小数部分 + 指数」三段

///|
/// 手工合成，不依赖标准库的浮点解析函数，保证三端逐位一致（）。
pub fn parse_double(s : String) -> Double? {
  let cs = to_chars(trim(s))
  let n = cs.length()
  if n == 0 {
    return None
  }
  let mut i = 0
  let mut neg = false
  if cs[0] == '+' || cs[0] == '-' {
    neg = cs[0] == '-'
    i = 1
  }
  if i >= n {
    return None
  }
  let mut int_part = 0.0
  let mut saw_digit = false
  while i < n && cs[i] >= '0' && cs[i] <= '9' {
    int_part = int_part * 10.0 +
      (char_to_int(cs[i]) - char_to_int('0')).to_double()
    saw_digit = true
    i = i + 1
  }
  if !saw_digit {
    return None
  }
  let mut frac = 0.0
  if i < n && cs[i] == '.' {
    i = i + 1
    let mut scale = 0.1
    let mut any = false
    while i < n && cs[i] >= '0' && cs[i] <= '9' {
      frac = frac + (char_to_int(cs[i]) - char_to_int('0')).to_double() * scale
      scale = scale / 10.0
      any = true
      i = i + 1
    }
    if !any {
      return None
    }
  }
  if !saw_digit {
    return None
  }
  let mut value = int_part + frac
  if i < n && (cs[i] == 'e' || cs[i] == 'E') {
    i = i + 1
    let mut eneg = false
    if i < n && (cs[i] == '+' || cs[i] == '-') {
      eneg = cs[i] == '-'
      i = i + 1
    }
    let mut exp = 0
    let mut any = false
    while i < n && cs[i] >= '0' && cs[i] <= '9' {
      exp = exp * 10 + (char_to_int(cs[i]) - char_to_int('0'))
      any = true
      i = i + 1
    }
    if !any {
      return None
    }
    let mut k = 0
    while k < exp {
      if eneg {
        value = value / 10.0
      } else {
        value = value * 10.0
      }
      k = k + 1
    }
  }
  if i != n {
    return None
  }
  Some(if neg { 0.0 - value } else { value })
}

///| 十进制位对齐比较用的自然序：`p2 < p10`。

///| 规则：先按「非数字前缀」逐字符比较，再比较数字段的数值大小（忽略前导零，

///|
/// 但前导零更多者视为更小，与主流漫画阅读器的排序一致）。
pub fn natural_cmp(a : String, b : String) -> Ordering {
  let x = to_chars(a)
  let y = to_chars(b)
  let mut i = 0
  let mut j = 0
  while true {
    let xa = if i < x.length() { Some(x[i]) } else { None }
    let yb = if j < y.length() { Some(y[j]) } else { None }
    match (xa, yb) {
      (None, None) => return Equal
      (None, Some(_)) => return Less
      (Some(_), None) => return Greater
      (Some(c1), Some(c2)) =>
        if is_digit(c1) && is_digit(c2) {
          let (v1, ni) = read_num(x, i)
          let (v2, nj) = read_num(y, j)
          let z1 = count_leading_zeros(x, i, ni)
          let z2 = count_leading_zeros(y, j, nj)
          if v1 != v2 {
            return if v1 < v2 { Less } else { Greater }
          }
          if z1 != z2 {
            return if z1 < z2 { Less } else { Greater }
          }
          i = ni
          j = nj
        } else if c1 != c2 {
          return if char_to_int(c1) < char_to_int(c2) { Less } else { Greater }
        } else {
          i = i + 1
          j = j + 1
        }
    }
  }
  // 循环只在两端同时耗尽时才应结束，这里返回 Equal 作为形式上的兜底。
  Equal
}

///|
pub fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// 从 `at` 起读一个数字段，返回数值与结束下标。
fn read_num(cs : Array[Char], at : Int32) -> (Int32, Int32) {
  let mut i = at
  let mut v = 0
  while i < cs.length() && is_digit(cs[i]) {
    v = v * 10 + (char_to_int(cs[i]) - char_to_int('0'))
    i = i + 1
  }
  (v, i)
}

///|
fn count_leading_zeros(cs : Array[Char], from : Int32, to : Int32) -> Int32 {
  let mut i = from
  let mut z = 0
  while i < to && cs[i] == '0' {
    z = z + 1
    i = i + 1
  }
  if to - from == z {
    // 全零段（"000"）：保留一个零参与比较
    z - 1
  } else {
    z
  }
}

///| 百分号解码：资源解析器需要处理 URL 编码的 href。

///|
/// 输出按 UTF-8 解码；非法转义或非法 UTF-8 序列返回 Err，不 panic。
pub fn percent_decode(s : String) -> Result[String, String] {
  let cs = to_chars(s)
  let bytes : Array[Int32] = []
  let mut i = 0
  while i < cs.length() {
    if cs[i] == '%' {
      if i + 2 >= cs.length() {
        return Err("百分号转义不完整：" + s)
      }
      match (hex_digit_value(cs[i + 1]), hex_digit_value(cs[i + 2])) {
        (Some(h), Some(l)) => bytes.push(h * 16 + l)
        _ => return Err("百分号转义含非十六进制字符：" + s)
      }
      i = i + 3
    } else {
      let c = cs[i]
      let cp = char_to_int(c)
      // 非 ASCII 字符直接按 UTF-8 编码写回
      if cp < 0x80 {
        bytes.push(cp)
      } else if cp < 0x800 {
        bytes.push(0xc0 | (cp >> 6))
        bytes.push(0x80 | (cp & 0x3f))
      } else if cp < 0x10000 {
        bytes.push(0xe0 | (cp >> 12))
        bytes.push(0x80 | ((cp >> 6) & 0x3f))
        bytes.push(0x80 | (cp & 0x3f))
      } else {
        bytes.push(0xf0 | (cp >> 18))
        bytes.push(0x80 | ((cp >> 12) & 0x3f))
        bytes.push(0x80 | ((cp >> 6) & 0x3f))
        bytes.push(0x80 | (cp & 0x3f))
      }
      i = i + 1
    }
  }
  utf8_decode(bytes)
}

///|
/// UTF-8 解码。严格校验：过长编码、代理区、越界码位一律拒绝。
pub fn utf8_decode(bytes : Array[Int32]) -> Result[String, String] {
  let out : Array[Char] = []
  let n = bytes.length()
  let mut i = 0
  while i < n {
    let b0 = bytes[i]
    if b0 < 0 || b0 > 255 {
      return Err("字节值越界")
    }
    if b0 < 0x80 {
      match codepoint_to_char(b0) {
        Some(c) => out.push(c)
        None => return Err("非法码位")
      }
      i = i + 1
    } else if b0 >= 0xc2 && b0 <= 0xdf {
      if i + 1 >= n {
        return Err("UTF-8 序列被截断")
      }
      let cp = ((b0 & 0x1f) << 6) | (bytes[i + 1] & 0x3f)
      match push_cp(out, cp) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      i = i + 2
    } else if b0 >= 0xe0 && b0 <= 0xef {
      if i + 2 >= n {
        return Err("UTF-8 序列被截断")
      }
      let hi = (b0 & 0x0f) << 12
      let mid = (bytes[i + 1] & 0x3f) << 6
      let cp = hi | mid | (bytes[i + 2] & 0x3f)
      if cp < 0x800 {
        return Err("UTF-8 过长编码")
      }
      match push_cp(out, cp) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      i = i + 3
    } else if b0 >= 0xf0 && b0 <= 0xf4 {
      if i + 3 >= n {
        return Err("UTF-8 序列被截断")
      }
      let hi = (b0 & 0x07) << 18
      let m1 = (bytes[i + 1] & 0x3f) << 12
      let m2 = (bytes[i + 2] & 0x3f) << 6
      let cp = hi | m1 | m2 | (bytes[i + 3] & 0x3f)
      if cp < 0x10000 || cp > 0x10ffff {
        return Err("UTF-8 码位越界")
      }
      match push_cp(out, cp) {
        Ok(_) => ()
        Err(e) => return Err(e)
      }
      i = i + 4
    } else {
      return Err("非法 UTF-8 首字节")
    }
  }
  Ok(from_chars(out))
}

///|
fn push_cp(out : Array[Char], cp : Int32) -> Result[Unit, String] {
  if cp >= 0xd800 && cp <= 0xdfff {
    Err("UTF-8 不得编码代理区码位")
  } else {
    match codepoint_to_char(cp) {
      Some(c) => {
        out.push(c)
        Ok(())
      }
      None => Err("UTF-8 码位非法")
    }
  }
}

///|
/// UTF-8 编码长度（字节数），用于估算归档体积。
pub fn utf8_len(s : String) -> Int32 {
  let mut n = 0
  for c in s {
    let cp = char_to_int(c)
    if cp < 0x80 {
      n = n + 1
    } else if cp < 0x800 {
      n = n + 2
    } else if cp < 0x10000 {
      n = n + 3
    } else {
      n = n + 4
    }
  }
  n
}
