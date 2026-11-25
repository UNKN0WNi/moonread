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

///|
fn measure_doc(xml : String) -> Array[@render.MeasuredBlock] {
  match @xml.parse_document(xml) {
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
        Ok(blocks) => blocks
      }
  }
}

///|
/// `<br>` 贡献真实换行，`<pre>` 保留连续空白。
test "br 与 pre 的文本语义不再丢失" {
  let br_doc = @xml.parse_document(
    "<html><body><p>第一行<br/>第二行</p></body></html>",
  )
  match br_doc {
    Err(_) => panic()
    Ok(root) =>
      match @xml.find_descendant(root, "p") {
        None => panic()
        Some(p) => {
          let text = @render.collapsed_text(p)
          assert_true(
            @util.contains(text, "\n"),
            msg="br 应产生换行：" + text,
          )
          assert_true(@render.lines_of(text, 40) == 2, msg="两行")
        }
      }
  }
  let pre_doc = @xml.parse_document(
    "<html><body><pre>行一  行二</pre></body></html>",
  )
  match pre_doc {
    Err(_) => panic()
    Ok(root) =>
      match @xml.find_descendant(root, "pre") {
        None => panic()
        Some(pre) => {
          let text = @render.preserved_text(pre)
          assert_true(
            @util.contains(text, "行一  行二"),
            msg="pre 空白保留：" + text,
          )
        }
      }
  }
}

///|
/// 列表真正产出 BKList，带有序标记、层级与序号。
test "有序列表产出带序号的 BKList 块" {
  let blocks = measure_doc(
    "<html><body><ol><li>第一章</li><li>第二章</li></ol></body></html>",
  )
  assert_true(blocks.length() == 2, msg="两项")
  let mut i = 0
  while i < 2 {
    assert_true(blocks[i].block.kind == @paginate.BKList, msg="列表块类型")
    assert_true(blocks[i].block.list_ordered, msg="有序列表")
    assert_true(blocks[i].block.list_index == i + 1, msg="序号")
    assert_true(blocks[i].block.list_depth == 0, msg="层级")
    i = i + 1
  }
}

///|
/// 表格单元格文字在块模型里有载体（BKTable.text）。
test "表格单元格文字进入块模型" {
  let blocks = measure_doc(
    "<html><body><table><tr><td>单元格甲</td><td>单元格乙</td></tr></table></body></html>",
  )
  assert_true(blocks.length() == 1, msg="一个表格块")
  assert_true(blocks[0].block.kind == @paginate.BKTable, msg="表格块类型")
  assert_true(
    @util.contains(blocks[0].block.text, "单元格甲") &&
    @util.contains(blocks[0].block.text, "单元格乙"),
    msg="单元格文字：" + blocks[0].block.text,
  )
}

///|
/// 内容层不变式能识别 DOM 文本是否全部进入度量块。
test "可见字符不丢失不变式" {
  let root = @xml.parse_document(
    "<html><body><div>段前文字<p>块内段落</p>段后文字</div></body></html>",
  )
  match root {
    Err(_) => panic()
    Ok(doc) => {
      let blocks = measure_doc(
        "<html><body><div>段前文字<p>块内段落</p>段后文字</div></body></html>",
      )
      assert_true(
        @render.invariant_visible_text_preserved(doc, blocks),
        msg="修复后所有可见字符都在块里",
      )
    }
  }
}
