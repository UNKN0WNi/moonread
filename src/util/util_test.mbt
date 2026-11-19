///|
/// src/util 单元测试。
///
/// 这里刻意不使用 `?` / `is_err()` 之类的便捷写法：测试体是 `Unit` 函数，
/// `?` 的提前返回类型在测试块里不直观，失败时也更难定位。
fn opt_int(r : Int32?, want : Int32) -> Bool {
  match r {
    Some(v) => v == want
    None => false
  }
}

///| 浮点近似比较。`parse_double` 用十进制累加合成数值，与字面量的最后一位

///|
/// ULP 可能不同，因此断言一律走容差而不是 `==`。
fn opt_double_close(r : Double?, want : Double) -> Bool {
  match r {
    Some(v) => {
      let d = v - want
      let ad = if d < 0.0 { 0.0 - d } else { d }
      ad < 0.000000001
    }
    None => false
  }
}

///|
fn opt_none_double(r : Double?) -> Bool {
  match r {
    Some(_) => false
    None => true
  }
}

///|
fn opt_none_char(r : Char?) -> Bool {
  match r {
    Some(_) => false
    None => true
  }
}

///|
fn opt_none_int(r : Int32?) -> Bool {
  match r {
    Some(_) => false
    None => true
  }
}

///|
fn res_is_err(r : Result[String, String]) -> Bool {
  match r {
    Err(_) => true
    Ok(_) => false
  }
}

///|
fn res_ok(r : Result[String, String], want : String) -> Bool {
  match r {
    Ok(v) => v == want
    Err(_) => false
  }
}

///|
test "trim 去掉首尾空白" {
  assert_true(
    @util.trim("  \t\n hello \r\n") == "hello",
    msg="trim 结果错误",
  )
  assert_true(@util.trim("") == "", msg="空串 trim")
  assert_true(@util.trim("   ") == "", msg="全空白 trim")
}

///|
test "starts_with / ends_with" {
  assert_true(
    @util.starts_with("OEBPS/content.opf", "OEBPS/"),
    msg="starts_with",
  )
  assert_true(
    !@util.starts_with("OEBPS/a.opf", "OPS/"),
    msg="starts_with 否定",
  )
  assert_true(@util.ends_with("style.css", ".css"), msg="ends_with")
  assert_true(!@util.ends_with("css", ".css"), msg="ends_with 长度不足")
}

///|
test "split_char 保留空段" {
  let parts = @util.split_char("a,,b", ',')
  assert_true(parts.length() == 3, msg="split_char 段数")
  assert_true(
    parts[0] == "a" && parts[1] == "" && parts[2] == "b",
    msg="split_char 内容",
  )
  let one = @util.split_char("solo", ',')
  assert_true(
    one.length() == 1 && one[0] == "solo",
    msg="split_char 无分隔符",
  )
}

///|
test "split_str 多字符分隔符" {
  let parts = @util.split_str("ch1;  ch2;  ch3", "; ")
  assert_true(parts.length() == 3, msg="split_str 段数")
  assert_true(parts[2] == " ch3", msg="split_str 保留前导空格")
  assert_true(
    @util.split_str("abc", "").length() == 1,
    msg="空分隔符退化为原串",
  )
}

///|
test "replace_all 处理重叠与空 from" {
  assert_true(
    @util.replace_all("aXbXc", "X", "-") == "a-b-c",
    msg="replace_all 基本",
  )
  assert_true(
    @util.replace_all("aaa", "aa", "b") == "ba",
    msg="replace_all 不重叠扫描",
  )
  assert_true(
    @util.replace_all("abc", "", "z") == "abc",
    msg="空 from 原样返回",
  )
  assert_true(
    @util.replace_all("fi", "fi", "\u{fb01}") == "\u{fb01}",
    msg="replace_all 写出连字",
  )
}

///|
test "ascii_lower 只折叠 ASCII" {
  assert_true(
    @util.ascii_lower("CONTENT.OPF") == "content.opf",
    msg="ascii_lower",
  )
  assert_true(@util.ascii_lower("ÆØ") == "ÆØ", msg="非 ASCII 原样")
}

///|
test "parse_int 严格" {
  assert_true(opt_int(@util.parse_int("42"), 42), msg="正整数")
  assert_true(opt_int(@util.parse_int(" -7 "), -7), msg="负整数带空白")
  assert_true(opt_none_int(@util.parse_int("12.5")), msg="拒绝小数")
  assert_true(opt_none_int(@util.parse_int("")), msg="拒绝空串")
  assert_true(opt_none_int(@util.parse_int("1e3")), msg="拒绝科学计数法")
  assert_true(opt_none_int(@util.parse_int("+")), msg="拒绝孤立符号")
}

///|
test "parse_double 数值合成" {
  assert_true(opt_double_close(@util.parse_double("1.5"), 1.5), msg="1.5")
  assert_true(opt_double_close(@util.parse_double("-2e3"), -2000.0), msg="-2e3")
  assert_true(opt_double_close(@util.parse_double("0.25"), 0.25), msg="0.25")
  assert_true(
    opt_double_close(@util.parse_double("12"), 12.0),
    msg="整数形式",
  )
  assert_true(
    opt_double_close(@util.parse_double("+1.5e-2"), 0.015),
    msg="正号 + 负指数",
  )
}

///|
test "parse_double 拒绝残缺" {
  assert_true(
    opt_none_double(@util.parse_double("1.")),
    msg="小数点后无数字",
  )
  assert_true(
    opt_none_double(@util.parse_double("e3")),
    msg="缺少整数部分",
  )
  assert_true(opt_none_double(@util.parse_double("")), msg="空串")
  assert_true(
    opt_none_double(@util.parse_double("1.2.3")),
    msg="多个小数点",
  )
  assert_true(opt_none_double(@util.parse_double("1e")), msg="指数缺数字")
  assert_true(opt_none_double(@util.parse_double("-")), msg="孤立符号")
}

///|
test "natural_cmp 让 p2 排在 p10 之前" {
  assert_true(
    @util.natural_cmp("p2.png", "p10.png") == @util.Less,
    msg="p2 < p10",
  )
  assert_true(
    @util.natural_cmp("001.jpg", "01.jpg") == @util.Greater,
    msg="前导零更少者在前",
  )
  assert_true(@util.natural_cmp("a", "a") == @util.Equal, msg="相同")
  assert_true(@util.natural_cmp("a1", "a1b") == @util.Less, msg="短者在前")
  assert_true(
    @util.natural_cmp("ch02.png", "ch10.png") == @util.Less,
    msg="ch02 < ch10",
  )
  assert_true(@util.natural_cmp("10", "9") == @util.Greater, msg="10 > 9")
}

///|
test "percent_decode 与 utf8_decode" {
  assert_true(res_ok(@util.percent_decode("a%20b"), "a b"), msg="空格")
  assert_true(res_ok(@util.percent_decode("100%25"), "100%"), msg="百分号")
  assert_true(
    res_ok(@util.percent_decode("%E4%B8%AD"), "中"),
    msg="UTF-8 中文",
  )
  assert_true(res_ok(@util.percent_decode("plain"), "plain"), msg="无转义")
  assert_true(res_is_err(@util.percent_decode("%")), msg="截断转义报错")
  assert_true(
    res_is_err(@util.percent_decode("%zz")),
    msg="非十六进制报错",
  )
  assert_true(
    res_is_err(@util.utf8_decode([0xe0, 0x80, 0x80])),
    msg="过长编码拒绝",
  )
  assert_true(
    res_is_err(@util.utf8_decode([0xed, 0xa0, 0x80])),
    msg="代理区拒绝",
  )
  assert_true(
    res_is_err(@util.utf8_decode([0xf4, 0x90, 0x80, 0x80])),
    msg="码位越界拒绝",
  )
  assert_true(
    res_is_err(@util.utf8_decode([0x80])),
    msg="连续字节开头非法",
  )
}

///|
test "codepoint_to_char 拒绝非法码位" {
  assert_true(opt_none_char(@util.codepoint_to_char(-1)), msg="负数")
  assert_true(
    opt_none_char(@util.codepoint_to_char(0x110000)),
    msg="超出 Unicode 范围",
  )
  assert_true(opt_none_char(@util.codepoint_to_char(0xd800)), msg="代理区")
}

///|
test "slice_chars 夹住越界" {
  let cs = @util.to_chars("abcdef")
  assert_true(
    @util.from_chars(@util.slice_chars(cs, 1, 3)) == "bc",
    msg="正常区间",
  )
  assert_true(@util.slice_chars(cs, 10, 20).length() == 0, msg="右越界")
  assert_true(@util.slice_chars(cs, 4, 2).length() == 0, msg="逆序区间")
}

///|
test "utf8_len 按码位分档" {
  assert_true(@util.utf8_len("abc") == 3, msg="ASCII")
  assert_true(@util.utf8_len("中") == 3, msg="BMP 三字节")
  assert_true(@util.utf8_len("\u{1f600}") == 4, msg="星外四字节")
}

///|
test "hex_digit_value / digit_value" {
  assert_true(opt_int(@util.hex_digit_value('f'), 15), msg="小写 f")
  assert_true(opt_int(@util.hex_digit_value('A'), 10), msg="大写 A")
  assert_true(
    opt_none_int(@util.hex_digit_value('g')),
    msg="非法十六进制位",
  )
  assert_true(opt_int(@util.digit_value('0'), 0), msg="0")
  assert_true(opt_none_int(@util.digit_value('x')), msg="非数字")
}
