/// fzip 适配器：真实 ZIP（.epub / .cbz）解压入口。
///
/// 本文件是整棵树里**唯一**调用 `@fzip` 的地方。解压实现被收敛在这里，
/// `zipio.mbt` 的 `entries_to_archive` 与内核其余部分都不依赖 fzip 的细节，
/// 因此换解压后端只需替换本文件。
///
/// ## 为什么输入是 `Bytes`
///
/// `@fs.read_file_to_bytes` 返回 `Bytes`；fzip 的 `unzip_sync` 吃
/// `FixedArray[Byte]`。二者内存布局相同，这里用逐字节拷贝转换，
/// 不依赖 `%identity` 这类 unsafe 桥接。
///
/// ## 文本 / 二进制
///
/// EPUB 的 XHTML / CSS / OPF / NCX 是文本，图片与字体是二进制。
/// 按条目名后缀判定：文本条目 UTF-8 解码后进入 `Archive`；
/// 二进制条目只记录名字与字节数（避免有损解码），供宿主另行处理。

///|
/// 把文件字节转成 fzip 输入。逐字节显式拷贝，四端行为一致。
fn bytes_to_fixed(b : Bytes) -> FixedArray[Byte] {
  let n = b.length()
  let out = FixedArray::make(n, b'\x00')
  let mut i = 0
  while i < n {
    out[i] = b[i]
    i = i + 1
  }
  out
}

///|
/// `FixedArray[Byte]` 转 `Array[Int32]`（字节值 0..255），供 `@util.utf8_decode`。
fn fixed_to_ints(b : FixedArray[Byte]) -> Array[Int32] {
  let out : Array[Int32] = []
  let n = b.length()
  let mut i = 0
  while i < n {
    out.push(b[i].to_int())
    i = i + 1
  }
  out
}

///|
/// 条目是否为应进入 `Archive` 的文本。按名字后缀白名单判定，
/// 大小写不敏感；`mimetype` 无后缀，单独列出。
fn is_text_entry(name : String) -> Bool {
  if name == "mimetype" {
    return true
  }
  let n = @util.ascii_lower(name)
  @util.ends_with(n, ".xhtml") ||
  @util.ends_with(n, ".html") ||
  @util.ends_with(n, ".htm") ||
  @util.ends_with(n, ".xml") ||
  @util.ends_with(n, ".opf") ||
  @util.ends_with(n, ".ncx") ||
  @util.ends_with(n, ".css") ||
  @util.ends_with(n, ".json") ||
  @util.ends_with(n, ".txt") ||
  @util.ends_with(n, ".svg")
}

///|
/// 从 `.epub` / `.cbz` 的原始字节得到 `ZipReport`。
///
/// 解压顺序沿用 fzip 返回的中央目录顺序，EPUB 的 `mimetype` 首位判定
/// 因此成立。`FzipError` 被转换为前缀统一的 String 错误。
pub fn open_archive_from_bytes(
  name : String,
  raw : Bytes,
  budget_bytes : Int32,
) -> Result[ZipReport, String] {
  let data = bytes_to_fixed(raw)
  let unzipped = @fzip.unzip_sync(data) catch {
    @fzip.FzipError(message~, ..) => return Err(adapter_error("fzip", message))
  }
  let entries : Array[DecodedEntry] = []
  for (entry_name, content) in unzipped {
    if is_text_entry(entry_name) {
      match @util.utf8_decode(fixed_to_ints(content)) {
        Ok(text) => entries.push(text_entry(entry_name, text))
        Err(_) => entries.push(binary_entry(entry_name, content.length()))
      }
    } else {
      entries.push(binary_entry(entry_name, content.length()))
    }
  }
  match entries_to_archive(name, entries, budget_bytes) {
    Err(msg) => Err(adapter_error("fzip", msg))
    Ok(r) => Ok(r)
  }
}

///|
/// 从文件字节打开 EPUB：`zipio` -> `core` 的完整入口由宿主把结果交给
/// `@core.open_book`。这里只负责解压与归类，保持层职责单一。
pub fn open_epub_bytes(
  name : String,
  raw : Bytes,
  budget_bytes : Int32,
) -> Result[ZipReport, String] {
  open_archive_from_bytes(name, raw, budget_bytes)
}
