///|
/// 严格 JSON 的单元与负例测试。
///
/// 测试体内不使用 `?`：`test` 块返回 `Unit`，`?` 的提前返回类型在此不直观，
/// 失败时也难以定位。统一走显式 `match` 与布尔辅助函数。
fn parse_ok(text : String, want : @jsonio.Json) -> Bool {
  match @jsonio.parse(text) {
    Ok(v) => v == want
    Err(_) => false
  }
}

///|
fn parse_fails(text : String) -> Bool {
  match @jsonio.parse(text) {
    Err(_) => true
    Ok(_) => false
  }
}

///|
fn parse_err_contains(text : String, needle : String) -> Bool {
  match @jsonio.parse(text) {
    Err(e) => @util.contains(e, needle)
    Ok(_) => false
  }
}

///|
fn get_str(v : @jsonio.Json, k : String) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) =>
      match @jsonio.as_str(j) {
        Some(_) => true
        None => false
      }
    None => false
  }
}

///|
fn str_is(v : @jsonio.Json, k : String, want : String) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) =>
      match @jsonio.as_str(j) {
        Some(s) => s == want
        None => false
      }
    None => false
  }
}

///|
fn int_is(v : @jsonio.Json, k : String, want : Int32) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) =>
      match @jsonio.as_int(j) {
        Some(i) => i == want
        None => false
      }
    None => false
  }
}

///|
fn double_is(v : @jsonio.Json, k : String, want : Double) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) =>
      match @jsonio.as_double(j) {
        Some(d) => {
          let diff = d - want
          let ad = if diff < 0.0 { 0.0 - diff } else { diff }
          ad < 0.000000001
        }
        None => false
      }
    None => false
  }
}

///|
fn bool_is(v : @jsonio.Json, k : String, want : Bool) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) =>
      match @jsonio.as_bool(j) {
        Some(b) => b == want
        None => false
      }
    None => false
  }
}

///|
fn arr_len_is(v : @jsonio.Json, k : String, want : Int32) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) => @jsonio.arr_len(j) == want
    None => false
  }
}

///|
fn obj_len_is(v : @jsonio.Json, k : String, want : Int32) -> Bool {
  match @jsonio.obj_get(v, k) {
    Some(j) => @jsonio.obj_len(j) == want
    None => false
  }
}

///|
fn sample() -> @jsonio.Json {
  match
    @jsonio.parse(
      "{\"a\":\"s\",\"n\":3,\"f\":1.5,\"b\":true,\"arr\":[1,2],\"obj\":{\"z\":null}}",
    ) {
    Ok(v) => v
    Err(_) => panic()
  }
}

///|
test "解析标量" {
  assert_true(parse_ok("null", JNull), msg="null")
  assert_true(parse_ok("true", JBool(true)), msg="true")
  assert_true(parse_ok("false", JBool(false)), msg="false")
  assert_true(parse_ok("42", JInt(42)), msg="整数")
  assert_true(parse_ok("-7", JInt(-7)), msg="负整数")
  assert_true(parse_ok("\"hi\"", JStr("hi")), msg="字符串")
  assert_true(parse_ok("[]", JArr([])), msg="空数组")
  assert_true(parse_ok("{}", JObj([])), msg="空对象")
}

///|
test "解析容器与嵌套" {
  assert_true(
    parse_ok("[1,2,3]", JArr([JInt(1), JInt(2), JInt(3)])),
    msg="整数数组",
  )
  assert_true(
    parse_ok(
      "{ \"a\" : 1 , \"b\" : [ true , null ] }",
      JObj([("a", JInt(1)), ("b", JArr([JBool(true), JNull]))]),
    ),
    msg="嵌套对象（含空白容忍）",
  )
  assert_true(
    parse_ok("[ [ ] ]", JArr([JArr([])])),
    msg="空数组套空数组",
  )
}

///|
test "数字：JInt 与 JNum 分离" {
  assert_true(parse_ok("12", JInt(12)), msg="12 应为 JInt")
  assert_true(
    match @jsonio.parse("12.0") {
      Ok(JNum(_)) => true
      _ => false
    },
    msg="12.0 应为 JNum",
  )
  assert_true(
    match @jsonio.parse("1e3") {
      Ok(JNum(_)) => true
      _ => false
    },
    msg="1e3 应为 JNum",
  )
  assert_true(
    match @jsonio.parse("-0") {
      Ok(JInt(0)) => true
      _ => false
    },
    msg="-0 归一为 JInt(0)",
  )
}

///|
test "严格性负例：注释 / 尾随逗号 / 前导零 / 单引号" {
  assert_true(parse_fails("{ \"a\": 1, }"), msg="对象尾随逗号")
  assert_true(parse_fails("[1, 2, ]"), msg="数组尾随逗号")
  assert_true(parse_fails("01"), msg="前导零")
  assert_true(parse_fails("'x'"), msg="单引号字符串")
  assert_true(parse_fails("NaN"), msg="NaN")
  assert_true(parse_fails("Infinity"), msg="Infinity")
  assert_true(parse_fails("{ \"a\": 1 \"b\": 2 }"), msg="缺逗号")
  assert_true(parse_fails("[1,2"), msg="未闭合数组")
  assert_true(parse_fails("{\"a\":"), msg="值缺失")
  assert_true(parse_fails(""), msg="空输入")
  assert_true(parse_fails("1 2"), msg="顶层多余内容")
  assert_true(parse_fails("+1"), msg="正号")
  assert_true(parse_fails("1."), msg="小数点后无数字")
  assert_true(parse_fails("1e"), msg="指数缺数字")
  assert_true(parse_fails("// comment"), msg="行注释")
  assert_true(parse_fails("/* c */1"), msg="块注释")
  assert_true(
    !parse_fails("{\"a\":1}"),
    msg="合法输入不应失败（反向确认）",
  )
}

///|
test "字符串转义与码位" {
  assert_true(parse_ok("\"a\\\"b\"", JStr("a\"b")), msg="引号转义")
  assert_true(parse_ok("\"a\\\\b\"", JStr("a\\b")), msg="反斜杠转义")
  assert_true(parse_ok("\"a\\/b\"", JStr("a/b")), msg="斜杠转义")
  assert_true(parse_ok("\"\\n\\t\\r\"", JStr("\n\t\r")), msg="控制转义")
  assert_true(parse_ok("\"\\u0041\"", JStr("A")), msg="拉丁字母")
  assert_true(parse_ok("\"\\u4e2d\"", JStr("中")), msg="BMP 中文")
  assert_true(
    parse_ok("\"\\ud83d\\ude00\"", JStr("\u{1f600}")),
    msg="代理对",
  )
  assert_true(parse_fails("\"\u{01}\""), msg="未转义控制字符")
  assert_true(parse_fails("\"\\ud83d\""), msg="孤立高代理项")
  assert_true(parse_fails("\"\\udc00\""), msg="孤立低代理项")
  assert_true(parse_fails("\"\\u00zz\""), msg="非法十六进制转义")
  assert_true(parse_fails("\"abc"), msg="未闭合字符串")
  assert_true(parse_fails("\"\\x41\""), msg="不支持的转义字母")
}

///|
test "嵌套深度上限防构造输入" {
  let mut deep = ""
  let mut i = 0
  while i < 200 {
    deep = deep + "["
    i = i + 1
  }
  let mut k = 0
  while k < 200 {
    deep = deep + "]"
    k = k + 1
  }
  assert_true(parse_fails(deep), msg="200 层嵌套应被拒绝")
  let mut ok = ""
  let mut j = 0
  while j < 64 {
    ok = ok + "["
    j = j + 1
  }
  let mut m = 0
  while m < 64 {
    ok = ok + "]"
    m = m + 1
  }
  assert_true(!parse_fails(ok), msg="64 层嵌套应通过")
}

///|
test "错误信息带字符偏移与字段名" {
  assert_true(
    parse_err_contains("[1,2,]", "第 6 个字符处"),
    msg="尾随逗号偏移",
  )
  assert_true(
    parse_err_contains("{\"a\" 1}", "缺少冒号"),
    msg="缺冒号说明",
  )
  assert_true(
    parse_err_contains("{\"a\":1,,\"b\":2}", "对象键必须"),
    msg="连续逗号",
  )
}

///|
test "编码回写" {
  assert_true(@jsonio.encode(JInt(12)) == "12", msg="整数不带小数点")
  assert_true(
    @jsonio.encode(JStr("a\"b\\c")) == "\"a\\\"b\\\\c\"",
    msg="字符串转义",
  )
  assert_true(
    @jsonio.encode(JObj([("k", JArr([JBool(true), JNull]))])) ==
    "{\"k\":[true,null]}",
    msg="嵌套",
  )
  assert_true(
    @jsonio.encode(JStr("\u{01}")) == "\"\\u0001\"",
    msg="控制字符转义",
  )
  assert_true(
    @jsonio.encode(JStr("中")) == "\"中\"",
    msg="非 ASCII 原样输出",
  )
  assert_true(@jsonio.encode(JBool(false)) == "false", msg="布尔")
}

///|
test "编码-解析往返" {
  let src = "{\"version\":1,\"rules\":[{\"id\":\"a\",\"action\":{\"type\":\"remove\"}}]}"
  match @jsonio.parse(src) {
    Err(_) => panic()
    Ok(v) =>
      match @jsonio.parse(@jsonio.encode(v)) {
        Err(_) => panic()
        Ok(v2) => assert_true(v == v2, msg="往返应当等价")
      }
  }
}

///|
test "访问器按类型取值" {
  let v = sample()
  assert_true(str_is(v, "a", "s"), msg="as_str")
  assert_true(int_is(v, "n", 3), msg="as_int")
  assert_true(double_is(v, "f", 1.5), msg="as_double")
  assert_true(bool_is(v, "b", true), msg="as_bool")
  assert_true(arr_len_is(v, "arr", 2), msg="arr_len")
  assert_true(obj_len_is(v, "obj", 1), msg="obj_len")
  assert_true(get_str(v, "a"), msg="get_str")
  assert_true(!get_str(v, "n"), msg="数字不应当字符串取")
  assert_true(@jsonio.is_null(JNull), msg="is_null")
  assert_true(!@jsonio.is_null(JInt(0)), msg="0 不是 null")
  assert_true(@jsonio.obj_get(v, "missing") == None, msg="缺失键返回 None")
}

///|
test "require_* 的错误信息可定位" {
  let v = sample()
  assert_true(
    match @jsonio.require_int(v, "a", "$") {
      Err(e) => @util.contains(e, "必须是整数")
      Ok(_) => false
    },
    msg="字符串不应通过整数校验",
  )
  assert_true(
    match @jsonio.require_field(v, "missing", "$") {
      Err(e) => @util.contains(e, "缺少必填字段")
      Ok(_) => false
    },
    msg="缺失字段应报错",
  )
  assert_true(
    match @jsonio.require_arr(v, "obj", "$") {
      Err(e) => @util.contains(e, "必须是数组")
      Ok(_) => false
    },
    msg="对象不应通过数组校验",
  )
  assert_true(
    match @jsonio.require_obj(v, "obj", "$") {
      Ok(_) => true
      Err(_) => false
    },
    msg="对象字段应通过",
  )
}

///|
test "未知字段必须报错（）" {
  match @jsonio.parse("{\"theme\":\"paper\",\"fontzise\":12}") {
    Err(_) => panic()
    Ok(v) => {
      assert_true(
        match @jsonio.reject_unknown_fields(v, ["theme", "version"], "$") {
          Err(e) => @util.contains(e, "fontzise")
          Ok(_) => false
        },
        msg="报错应指出未知字段名",
      )
      assert_true(
        match
          @jsonio.reject_unknown_fields(
            v,
            ["theme", "version", "fontzise"],
            "$",
          ) {
          Ok(_) => true
          Err(_) => false
        },
        msg="声明过的字段应通过",
      )
    }
  }
}

///|
test "对象键序不影响取值（）" {
  match @jsonio.parse("{\"a\":1,\"b\":2}") {
    Err(_) => panic()
    Ok(v1) =>
      match @jsonio.parse("{\"b\":2,\"a\":1}") {
        Err(_) => panic()
        Ok(v2) => {
          assert_true(
            int_is(v1, "a", 1) && int_is(v2, "a", 1),
            msg="取值与键序无关",
          )
          assert_true(
            int_is(v1, "b", 2) && int_is(v2, "b", 2),
            msg="取值与键序无关",
          )
          assert_true(
            v1 != v2,
            msg="但内部表示保留键序，故两者不相等",
          )
        }
      }
  }
}
