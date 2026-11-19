///|
/// 真实 EPUB 读取器：moon run --target native apps/epub-cli <path.epub>
///
/// 链路：@fs 读原始字节 -> @zipio(fzip) 解压 -> @core.open_book -> 结构报告。
/// 这是「fzip 已真正接入」的可执行证据：输入是磁盘上的真实 .epub，
/// 不再是内存 fixture。

///|
fn fail(msg : String) -> Unit {
  eprintln("moonread: " + msg)
  @env.exit(2)
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    fail("用法：moon run --target native apps/epub-cli <path.epub>")
  }
  let path = args[1]
  let raw = @fs.read_file_to_bytes(path) catch {
    _ => {
      fail("无法读取文件：" + path)
      panic()
    }
  }

  let cfg = @config.default_config()
  let rules = match @rules.load_rules("{\"version\":1,\"rules\":[]}") {
    Ok(r) => r
    Err(_) => {
      fail("内置规则集加载失败")
      panic()
    }
  }

  let opened = @zipio.open_archive_from_bytes(
    path,
    raw,
    @zipio.DEFAULT_BUDGET_BYTES,
  )
  let report = match opened {
    Err(e) => {
      fail("ZIP 解压失败：" + e)
      panic()
    }
    Ok(r) => r
  }
  println("== ZIP ==")
  println("条目：" + @container.entry_count(report.archive).to_string())
  println(
    "mimetype 首位：" +
    bool_text(@container.mimetype_is_first(report.archive)),
  )
  println("解压总量：" + report.total_bytes.to_string() + " 字节")
  for w in report.warnings {
    println("告警：" + w)
  }

  let book = match @core.open_book(report.archive, cfg, rules, @render.Null) {
    Ok(b) => b
    Err(e) => {
      fail("内核打开失败：" + e)
      panic()
    }
  }
  println("")
  println("== EPUB ==")
  println(@epub.describe(book.epub))
  for w in book.epub.warnings {
    println("告警：" + w)
  }

  println("")
  println(
    "== 目录（来源 " +
    book.toc.source +
    "，共 " +
    @toc.total_items(book.toc).to_string() +
    " 项）==",
  )
  println(@toc.render_text(book.toc))

  let chapters = @core.chapters(book)
  println("")
  println(
    "== 逐章分页（共 " + chapters.length().to_string() + " 章）==",
  )
  let mut i = 0
  while i < chapters.length() {
    match @core.render_chapter(book, i) {
      Ok(cp) =>
        println(
          (i + 1).to_string() +
          ". " +
          cp.title +
          "：块 " +
          cp.blocks.length().to_string() +
          " -> 页 " +
          @paginate.page_count(cp.paginated).to_string(),
        )
      Err(e) => println((i + 1).to_string() + ". 失败：" + e)
    }
    i = i + 1
  }
  println("")
  println("验证通过：" + path)
}

///|
fn bool_text(b : Bool) -> String {
  if b {
    "true"
  } else {
    "false"
  }
}
