///|
/// 度量后端的确定性近似测试。重点钉死 P0-2：汉字此前按 1 个 ASCII 宽度计数，
/// 导致中文行数与页数低估约 2 倍。

///|
fn repeat(text : String, n : Int32) -> String {
  let mut out = ""
  let mut i = 0
  while i < n {
    out = out + text
    i = i + 1
  }
  out
}

///|
test "汉字显示宽度是 ASCII 的两倍" {
  assert_true(@render.display_width('A') == 1, msg="ASCII 记 1")
  assert_true(@render.display_width('中') == 2, msg="汉字记 2")
  assert_true(@render.display_width('あ') == 2, msg="假名记 2")
  assert_true(@render.display_width('한') == 2, msg="韩文记 2")
  assert_true(@render.display_width('．') == 2, msg="全角标点记 2")
}

///|
/// 每行 40 个 ASCII 宽度单位：40 个 ASCII = 1 行，40 个汉字 = 2 行。
test "同等字符数下中文行数是 ASCII 的两倍" {
  let cpl = 40
  let ascii = @render.lines_of(repeat("a", 40), cpl)
  let cjk = @render.lines_of(repeat("中", 40), cpl)
  assert_true(ascii == 1, msg="40 ASCII => 1 行，实际 " + ascii.to_string())
  assert_true(cjk == 2, msg="40 汉字 => 2 行，实际 " + cjk.to_string())
}

///|
/// 3000 字中文在每行 40 单位时约 150 行；旧实现（每字 1 单位）只给 75 行。
test "整章中文的行数不再低估一半" {
  let cpl = 40
  let lines = @render.lines_of(repeat("字", 3000), cpl)
  assert_true(
    lines == 150,
    msg="3000 汉字 => 150 行，实际 " + lines.to_string(),
  )
}

///|
/// HTML5 混合内容：块容器里块子节点前后的裸文本必须各自成为度量块。
test "块容器内的裸文本不再丢失" {
  let doc = @xml.parse_document(
    "<html><body><div>段前文字<p>块内段落</p>段后文字</div></body></html>",
  )
  match doc {
    Err(_) => panic()
    Ok(root) =>
      match
        @render.measure(@render.Null, @render.RenderRequest::{
          doc: root,
          viewport_width: 400.0,
          line_height: 20.0,
          font_size_px: 16.0,
          avg_char_width_ratio: 0.5,
        }) {
        Err(_) => panic()
        Ok(blocks) => {
          assert_true(blocks.length() == 3, msg="应有 3 个度量块")
          let mut text_blocks = 0
          for b in blocks {
            if @util.contains(b.path, "#text") {
              text_blocks = text_blocks + 1
            }
          }
          assert_true(text_blocks == 2, msg="段前/段后各一个文本块")
        }
      }
  }
}

///|
test "混合文本按累计宽度折行，空串仍占一行" {
  assert_true(@render.lines_of("", 40) == 1, msg="空串 1 行")
  assert_true(@render.lines_of("a中b", 40) == 1, msg="短混合 1 行")
  // 每行 3 单位：a(1) 中(2) b(1) => a+中 占满 3，b 换到第二行
  assert_true(
    @render.lines_of("a中b", 3) == 2,
    msg="a+中 一行，b 第二行",
  )
  assert_true(
    @render.lines_of("abc", 0) == 1,
    msg="非法每行宽度退化为 1 行",
  )
}
