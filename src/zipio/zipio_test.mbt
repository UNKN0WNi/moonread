///|
/// fzip 适配器测试：内存造 ZIP -> 真实解压 -> Archive。
/// 覆盖 mimetype 首位、文本 UTF-8 解码、二进制降级、坏输入不 panic。

///|
fn make_zip(entries : Array[(String, FixedArray[Byte])]) -> Bytes {
  let fixed = @fzip.zip_sync(entries)
  Bytes::from_array(fixed.exact_view())
}

///|
test "fzip 解压：mimetype 首位 + 文本条目" {
  let z = make_zip([
    ("mimetype", @fzip.str_to_u8("application/epub+zip")),
    ("OEBPS/content.opf", @fzip.str_to_u8("<?xml version=\"1.0\"?><package/>")),
    ("OEBPS/ch.xhtml", @fzip.str_to_u8("<p>你好，世界</p>")),
  ])
  match @zipio.open_archive_from_bytes("sample.epub", z, 1048576) {
    Err(_) => panic()
    Ok(r) => {
      assert_eq(@container.entry_count(r.archive), 3)
      assert_true(@container.mimetype_is_first(r.archive))
      match @container.read(r.archive, "OEBPS/ch.xhtml") {
        Err(_) => panic()
        Ok(text) => assert_eq(text, "<p>你好，世界</p>")
      }
      assert_eq(r.total_bytes > 0, true)
    }
  }
}

///|
test "fzip 解压：二进制条目降级不进 Archive" {
  let img = FixedArray::make(8, b'\xff')
  let z = make_zip([
    ("mimetype", @fzip.str_to_u8("application/epub+zip")),
    ("OEBPS/Images/cover.jpg", img),
  ])
  match @zipio.open_archive_from_bytes("sample.epub", z, 1048576) {
    Err(_) => panic()
    Ok(r) => {
      assert_eq(@container.entry_count(r.archive), 1)
      assert_eq(r.binary_names.length(), 1)
      assert_eq(r.binary_names[0], "OEBPS/Images/cover.jpg")
    }
  }
}

///|
test "fzip 解压：非 ZIP 输入返回 Err 不 panic" {
  let junk = Bytes::from_array(@fzip.str_to_u8("not a zip").exact_view())
  match @zipio.open_archive_from_bytes("junk.epub", junk, 1048576) {
    Ok(_) => panic()
    Err(e) => assert_true(@util.contains(e, "fzip"))
  }
}
