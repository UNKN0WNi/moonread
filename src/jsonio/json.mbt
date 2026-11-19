/// 严格 JSON 解析与编码。
///
/// 「严格」的具体含义，也是与宽松 JSON 库的差异点：
/// - 不接受注释、尾随逗号、单引号字符串、`NaN`/`Infinity`；
/// - 数字不接受前导零（`01` 报错），小数点后必须有数字，不允许前导 `+`；
/// - 字符串内不接受未转义控制字符（< 0x20）；
/// - 顶层只允许一个值，值后除空白外不得有任何字符；
/// - `\u` 转义必须构成合法码位，孤立代理项报错。
///
/// 「语义只依赖数组顺序」：对象用 `Array[(String, Json)]` 保存，
/// 键序在解析结果里可见且稳定，但**任何业务逻辑都不得依赖它**——
/// 需要顺序的场合一律用数组。
///
/// 「未知字段报错」：见 `reject_unknown_fields`，config/rules 加载必须调用。

///| JSON 值。`JInt` 与 `JNum` 分离，是因为整数原样回写时不需要浮点格式化，

///|
/// 可以避免「12 变成 12.0」这类跨端字符串差异（三端逐字节一致）。
#derive(Debug, Eq)
pub(all) enum Json {
  JNull
  JBool(Bool)
  JInt(Int32)
  JNum(Double)
  JStr(String)
  JArr(Array[Json])
  JObj(Array[(String, Json)])
}

///|
pub fn j_bool(b : Bool) -> Json {
  JBool(b)
}

///|
pub fn j_int(i : Int32) -> Json {
  JInt(i)
}

///|
pub fn j_str(s : String) -> Json {
  JStr(s)
}

///|
pub fn j_arr(items : Array[Json]) -> Json {
  JArr(items)
}

///|
pub fn j_obj(fields : Array[(String, Json)]) -> Json {
  JObj(fields)
}

///|
priv struct P {
  src : Array[Char]
  mut pos : Int32
  mut depth : Int32
}

///|
/// 解析入口。返回 `Err(中文说明 + 字符偏移)`，绝不 panic（验收项）。
pub fn parse(text : String) -> Result[Json, String] {
  let p = P::{ src: @util.to_chars(text), pos: 0, depth: 0, }
  skip_ws(p)
  match parse_value(p) {
    Err(e) => return Err(e)
    Ok(v) => {
      skip_ws(p)
      if p.pos != p.src.length() {
        Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：顶层值之后存在多余内容",
        )
      } else {
        Ok(v)
      }
    }
  }
}

///|
fn at(p : P, i : Int32) -> Char? {
  if i >= 0 && i < p.src.length() {
    Some(p.src[i])
  } else {
    None
  }
}

///|
fn cur(p : P) -> Char? {
  at(p, p.pos)
}

///|
fn err_at(p : P, msg : String) -> Result[Json, String] {
  Err("第 " + (p.pos + 1).to_string() + " 个字符处：" + msg)
}

///|
fn skip_ws(p : P) -> Unit {
  let n = p.src.length()
  let mut i = p.pos
  while i < n {
    let c = p.src[i]
    if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
      i = i + 1
    } else {
      break
    }
  }
  p.pos = i
}

///|
fn parse_value(p : P) -> Result[Json, String] {
  if p.depth > 128 {
    return err_at(p, "嵌套层级超过 128，疑似构造输入")
  }
  p.depth = p.depth + 1
  let r = parse_value_inner(p)
  p.depth = p.depth - 1
  r
}

///|
fn parse_value_inner(p : P) -> Result[Json, String] {
  match cur(p) {
    None => err_at(p, "内容意外结束")
    Some(c) =>
      if c == '{' {
        parse_object(p)
      } else if c == '[' {
        parse_array(p)
      } else if c == '"' {
        parse_string(p)
      } else if c == 't' {
        expect_literal(p, "true", JBool(true))
      } else if c == 'f' {
        expect_literal(p, "false", JBool(false))
      } else if c == 'n' {
        expect_literal(p, "null", JNull)
      } else if c == '-' || (c >= '0' && c <= '9') {
        parse_number(p)
      } else {
        err_at(p, "意外的字符 '" + @util.char_to_string(c) + "'")
      }
  }
}

///|
fn expect_literal(p : P, lit : String, v : Json) -> Result[Json, String] {
  let want = @util.to_chars(lit)
  if p.pos + want.length() > p.src.length() {
    return err_at(p, "字面量被截断，期望 " + lit)
  }
  let mut i = 0
  while i < want.length() {
    if p.src[p.pos + i] != want[i] {
      return err_at(p, "期望 " + lit + "，实际不匹配")
    }
    i = i + 1
  }
  p.pos = p.pos + want.length()
  Ok(v)
}

///|
fn parse_object(p : P) -> Result[Json, String] {
  let fields : Array[(String, Json)] = []
  p.pos = p.pos + 1
  skip_ws(p)
  if cur(p) == Some('}') {
    p.pos = p.pos + 1
    return Ok(JObj(fields))
  }
  while true {
    skip_ws(p)
    if cur(p) != Some('"') {
      return err_at(p, "对象键必须是双引号字符串")
    }
    let key = match parse_string_raw(p) {
      Ok(__try_v_1) => __try_v_1
      Err(__try_e_1) => return Err(__try_e_1)
    }
    skip_ws(p)
    if cur(p) != Some(':') {
      return err_at(p, "键 '" + key + "' 之后缺少冒号")
    }
    p.pos = p.pos + 1
    skip_ws(p)
    let v = match parse_value(p) {
      Ok(__try_v_2) => __try_v_2
      Err(__try_e_2) => return Err(__try_e_2)
    }
    fields.push((key, v))
    skip_ws(p)
    match cur(p) {
      Some(',') => p.pos = p.pos + 1
      Some('}') => {
        p.pos = p.pos + 1
        return Ok(JObj(fields))
      }
      _ =>
        return err_at(
          p, "对象成员之后期望 ',' 或 '}'（不接受尾随逗号）",
        )
    }
  }
  Err("对象解析内部错误")
}

///|
fn parse_array(p : P) -> Result[Json, String] {
  let items : Array[Json] = []
  p.pos = p.pos + 1
  skip_ws(p)
  if cur(p) == Some(']') {
    p.pos = p.pos + 1
    return Ok(JArr(items))
  }
  while true {
    skip_ws(p)
    let v = match parse_value(p) {
      Ok(__try_v_3) => __try_v_3
      Err(__try_e_3) => return Err(__try_e_3)
    }
    items.push(v)
    skip_ws(p)
    match cur(p) {
      Some(',') => p.pos = p.pos + 1
      Some(']') => {
        p.pos = p.pos + 1
        return Ok(JArr(items))
      }
      _ =>
        return err_at(
          p, "数组元素之后期望 ',' 或 ']'（不接受尾随逗号）",
        )
    }
  }
  Err("数组解析内部错误")
}

///|
fn parse_string(p : P) -> Result[Json, String] {
  Ok(
    JStr(
      match parse_string_raw(p) {
        Ok(__try_v_4) => __try_v_4
        Err(__try_e_4) => return Err(__try_e_4)
      },
    ),
  )
}

///|
fn parse_string_raw(p : P) -> Result[String, String] {
  p.pos = p.pos + 1
  let out : Array[Char] = []
  let n = p.src.length()
  while true {
    if p.pos >= n {
      return Err(
        "第 " + p.pos.to_string() + " 个字符处：字符串未闭合",
      )
    }
    let c = p.src[p.pos]
    if c == '"' {
      p.pos = p.pos + 1
      return Ok(@util.from_chars(out))
    }
    if c == '\\' {
      p.pos = p.pos + 1
      if p.pos >= n {
        return Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：反斜杠之后缺少转义内容",
        )
      }
      let e = p.src[p.pos]
      p.pos = p.pos + 1
      if e == '"' {
        out.push('"')
      } else if e == '\\' {
        out.push('\\')
      } else if e == '/' {
        out.push('/')
      } else if e == 'b' {
        out.push('\u{08}')
      } else if e == 'f' {
        out.push('\u{0c}')
      } else if e == 'n' {
        out.push('\n')
      } else if e == 'r' {
        out.push('\r')
      } else if e == 't' {
        out.push('\t')
      } else if e == 'u' {
        let cp = match read_unicode_escape(p) {
          Ok(__try_v_5) => __try_v_5
          Err(__try_e_5) => return Err(__try_e_5)
        }
        match @util.codepoint_to_char(cp) {
          Some(ch) => out.push(ch)
          None =>
            return Err(
              "第 " +
              p.pos.to_string() +
              " 个字符处：\\u 转义得到非法码位",
            )
        }
      } else {
        return Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：不支持的转义 '\\" +
          @util.char_to_string(e) +
          "'",
        )
      }
    } else {
      let cp = @util.char_to_int(c)
      if cp < 0x20 {
        return Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：字符串含未转义控制字符 0x" +
          hex2(cp),
        )
      }
      out.push(c)
      p.pos = p.pos + 1
    }
  }
  Err("字符串解析内部错误")
}

///|
/// 解析 `\uXXXX`（调用前已消费 `u`）。高代理项必须紧跟 `\uXXXX` 低代理项。
fn read_unicode_escape(p : P) -> Result[Int32, String] {
  match read_hex4(p) {
    None =>
      Err(
        "第 " +
        p.pos.to_string() +
        " 个字符处：\\u 转义需要 4 位十六进制",
      )
    Some(hi) =>
      if hi >= 0xd800 && hi <= 0xdbff {
        let n0 = at(p, p.pos)
        let n1 = at(p, p.pos + 1)
        let is_pair = match (n0, n1) {
          (Some('\\'), Some('u')) => true
          _ => false
        }
        if !is_pair {
          return Err(
            "第 " +
            p.pos.to_string() +
            " 个字符处：存在孤立的高代理项转义",
          )
        }
        p.pos = p.pos + 2
        match read_hex4(p) {
          None =>
            Err(
              "第 " +
              p.pos.to_string() +
              " 个字符处：代理对第二项格式错误",
            )
          Some(lo) =>
            if lo >= 0xdc00 && lo <= 0xdfff {
              Ok(0x10000 + ((hi - 0xd800) << 10) + (lo - 0xdc00))
            } else {
              Err(
                "第 " +
                p.pos.to_string() +
                " 个字符处：代理对第二项不是低代理项",
              )
            }
        }
      } else if hi >= 0xdc00 && hi <= 0xdfff {
        Err(
          "第 " +
          p.pos.to_string() +
          " 个字符处：存在孤立的低代理项转义",
        )
      } else {
        Ok(hi)
      }
  }
}

///|
fn read_hex4(p : P) -> Int32? {
  if p.pos + 4 > p.src.length() {
    return None
  }
  let mut acc = 0
  let mut i = 0
  while i < 4 {
    match @util.hex_digit_value(p.src[p.pos + i]) {
      Some(v) => acc = acc * 16 + v
      None => return None
    }
    i = i + 1
  }
  p.pos = p.pos + 4
  Some(acc)
}

///|
fn hex2(v : Int32) -> String {
  @util.char_to_string(@util.hex_digit_char((v >> 4) & 0xf)) +
  @util.char_to_string(@util.hex_digit_char(v & 0xf))
}

///|
fn parse_number(p : P) -> Result[Json, String] {
  let start = p.pos
  let n = p.src.length()
  let mut i = p.pos
  if i < n && p.src[i] == '-' {
    i = i + 1
  } else if i < n && p.src[i] == '+' {
    return err_at(p, "数字不允许正号 '+'")
  }
  if i >= n {
    return err_at(p, "数字不完整")
  }
  // 前导零：`0` 之后只能接 `.` / `e` / 结束
  if p.src[i] == '0' {
    i = i + 1
    if i < n && p.src[i] >= '0' && p.src[i] <= '9' {
      return err_at(p, "数字不允许前导零")
    }
  } else if p.src[i] >= '1' && p.src[i] <= '9' {
    while i < n && p.src[i] >= '0' && p.src[i] <= '9' {
      i = i + 1
    }
  } else {
    return err_at(p, "数字缺少整数部分")
  }
  let mut is_float = false
  if i < n && p.src[i] == '.' {
    is_float = true
    i = i + 1
    let frac_start = i
    while i < n && p.src[i] >= '0' && p.src[i] <= '9' {
      i = i + 1
    }
    if i == frac_start {
      return err_at(p, "小数点后缺少数字")
    }
  }
  if i < n && (p.src[i] == 'e' || p.src[i] == 'E') {
    is_float = true
    i = i + 1
    if i < n && (p.src[i] == '+' || p.src[i] == '-') {
      i = i + 1
    }
    let exp_start = i
    while i < n && p.src[i] >= '0' && p.src[i] <= '9' {
      i = i + 1
    }
    if i == exp_start {
      return err_at(p, "指数缺少数字")
    }
  }
  let text = @util.from_chars(@util.slice_chars(p.src, start, i))
  p.pos = i
  if is_float {
    match @util.parse_double(text) {
      Some(v) => Ok(JNum(v))
      None => Err("数字解析失败：" + text)
    }
  } else {
    match @util.parse_int(text) {
      Some(v) => Ok(JInt(v))
      None => Err("整数解析失败：" + text)
    }
  }
}

///|
/// 编码为紧凑 JSON 文本。
pub fn encode(j : Json) -> String {
  match j {
    JNull => "null"
    JBool(true) => "true"
    JBool(false) => "false"
    JInt(i) => i.to_string()
    JNum(d) => format_double(d)
    JStr(s) => encode_string_literal(s)
    JArr(items) => "[" + join_comma(map_items(items)) + "]"
    JObj(fields) => {
      let parts : Array[String] = []
      for kv in fields {
        parts.push(encode_string_literal(kv.0) + ":" + encode(kv.1))
      }
      "{" + join_comma(parts) + "}"
    }
  }
}

///|
fn map_items(items : Array[Json]) -> Array[String] {
  let out : Array[String] = []
  for it in items {
    out.push(encode(it))
  }
  out
}

///|
fn join_comma(parts : Array[String]) -> String {
  let mut acc = ""
  let mut i = 0
  while i < parts.length() {
    if i > 0 {
      acc = acc + ","
    }
    acc = acc + parts[i]
    i = i + 1
  }
  acc
}

///|
/// 整数值直接走 `Int` 分支，避免 `12` 被写成 `12.0`。
fn format_double(d : Double) -> String {
  match @util.double_as_int(d) {
    Some(v) => v.to_string()
    None => d.to_string()
  }
}

///|
pub fn encode_string_literal(s : String) -> String {
  let out : Array[Char] = []
  out.push('"')
  for c in s {
    let cp = @util.char_to_int(c)
    if c == '"' {
      out.push('\\')
      out.push('"')
    } else if c == '\\' {
      out.push('\\')
      out.push('\\')
    } else if c == '\n' {
      out.push('\\')
      out.push('n')
    } else if c == '\r' {
      out.push('\\')
      out.push('r')
    } else if c == '\t' {
      out.push('\\')
      out.push('t')
    } else if cp < 0x20 {
      out.push('\\')
      out.push('u')
      out.push('0')
      out.push('0')
      out.push(@util.hex_digit_char((cp >> 4) & 0xf))
      out.push(@util.hex_digit_char(cp & 0xf))
    } else {
      out.push(c)
    }
  }
  out.push('"')
  @util.from_chars(out)
}

// ---------------- 访问器 ----------------

///|
pub fn is_null(j : Json) -> Bool {
  match j {
    JNull => true
    _ => false
  }
}

///|
pub fn obj_get(j : Json, key : String) -> Json? {
  match j {
    JObj(fields) => {
      let mut found : Json? = None
      for kv in fields {
        if kv.0 == key {
          found = Some(kv.1)
          break
        }
      }
      found
    }
    _ => None
  }
}

///|
pub fn obj_keys(j : Json) -> Array[String] {
  match j {
    JObj(fields) => {
      let out : Array[String] = []
      for kv in fields {
        out.push(kv.0)
      }
      out
    }
    _ => []
  }
}

///|
pub fn obj_len(j : Json) -> Int32 {
  match j {
    JObj(fields) => fields.length()
    _ => 0
  }
}

///|
pub fn arr_len(j : Json) -> Int32 {
  match j {
    JArr(items) => items.length()
    _ => 0
  }
}

///|
pub fn arr_items(j : Json) -> Array[Json] {
  match j {
    JArr(items) => items
    _ => []
  }
}

///|
pub fn as_str(j : Json) -> String? {
  match j {
    JStr(s) => Some(s)
    _ => None
  }
}

///|
pub fn as_bool(j : Json) -> Bool? {
  match j {
    JBool(b) => Some(b)
    _ => None
  }
}

///|
pub fn as_int(j : Json) -> Int32? {
  match j {
    JInt(i) => Some(i)
    JNum(d) => @util.double_as_int(d)
    _ => None
  }
}

///|
pub fn as_double(j : Json) -> Double? {
  match j {
    JInt(i) => Some(i.to_double())
    JNum(d) => Some(d)
    _ => None
  }
}

///|
pub fn type_name(j : Json) -> String {
  match j {
    JNull => "null"
    JBool(_) => "boolean"
    JInt(_) => "integer"
    JNum(_) => "number"
    JStr(_) => "string"
    JArr(_) => "array"
    JObj(_) => "object"
  }
}

///|
/// 取必填字段，缺失或类型不符时给出**带路径**的错误（）。
pub fn require_field(
  j : Json,
  key : String,
  path : String,
) -> Result[Json, String] {
  match obj_get(j, key) {
    Some(v) => Ok(v)
    None => Err(path + " 缺少必填字段 '" + key + "'")
  }
}

///|
pub fn require_str(
  j : Json,
  key : String,
  path : String,
) -> Result[String, String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match as_str(v) {
        Some(s) => Ok(s)
        None =>
          Err(
            path + "." + key + " 必须是字符串，实际是 " + type_name(v),
          )
      }
  }
}

///|
pub fn require_int(
  j : Json,
  key : String,
  path : String,
) -> Result[Int32, String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match as_int(v) {
        Some(i) => Ok(i)
        None =>
          Err(path + "." + key + " 必须是整数，实际是 " + type_name(v))
      }
  }
}

///|
pub fn require_double(
  j : Json,
  key : String,
  path : String,
) -> Result[Double, String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match as_double(v) {
        Some(d) => Ok(d)
        None =>
          Err(path + "." + key + " 必须是数值，实际是 " + type_name(v))
      }
  }
}

///|
pub fn require_bool(
  j : Json,
  key : String,
  path : String,
) -> Result[Bool, String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match as_bool(v) {
        Some(b) => Ok(b)
        None =>
          Err(path + "." + key + " 必须是布尔，实际是 " + type_name(v))
      }
  }
}

///|
pub fn require_arr(
  j : Json,
  key : String,
  path : String,
) -> Result[Array[Json], String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match v {
        JArr(items) => Ok(items)
        _ =>
          Err(path + "." + key + " 必须是数组，实际是 " + type_name(v))
      }
  }
}

///|
pub fn require_obj(
  j : Json,
  key : String,
  path : String,
) -> Result[Json, String] {
  match require_field(j, key, path) {
    Err(e) => return Err(e)
    Ok(v) =>
      match v {
        JObj(_) => Ok(v)
        _ =>
          Err(path + "." + key + " 必须是对象，实际是 " + type_name(v))
      }
  }
}

///|
/// 未知字段**报错**而非静默忽略，防止用户以为规则生效了。
/// 以 `_` 开头的键是配置文件里给人看的注释/元数据，运行时忽略。
pub fn reject_unknown_fields(
  j : Json,
  allowed : ReadOnlyArray[String],
  path : String,
) -> Result[Unit, String] {
  for k in obj_keys(j) {
    if k.length() == 0 || k[0] != '_' {
      let mut ok = false
      for a in allowed {
        if a == k {
          ok = true
          break
        }
      }
      if !ok {
        return Err(
          path +
          " 含未知字段 '" +
          k +
          "'（允许：" +
          join_bar(allowed) +
          "）",
        )
      }
    }
  }
  Ok(())
}

///|
fn join_bar(items : ReadOnlyArray[String]) -> String {
  let mut acc = ""
  let mut i = 0
  while i < items.length() {
    if i > 0 {
      acc = acc + " | "
    }
    acc = acc + items[i]
    i = i + 1
  }
  acc
}
