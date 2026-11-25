///|
/// 语料对账探针：`moon run --target native tools/probe <corpus-dir> [<corpus-dir> ...]`
///
/// 每个语料目录下读 `epub/*.epub`，走真实磁盘 -> fzip -> 内核完整链路，
/// 输出紧凑 JSON：{"epub/xxx.epub":{"title":...,"chapters":...,"toc_items":...,"resources":...}}
/// corpus_check.py 用它把 manifest 的期望值与内核实际值对账。

///|
fn die(msg : String) -> Unit {
  eprintln("moonread probe: " + msg)
  @env.exit(2)
}

///|
/// 目录来源为 spine-fallback 时视为 0 项：真实目录优先 nav/NCX，
/// 没有真目录的书不该因为合成目录而假装 TOC 有内容。
fn toc_count(b : @epub.EpubBook) -> Int32 {
  let toc = @toc.from_book(b)
  if toc.source == "spine-fallback" {
    0
  } else {
    @toc.total_items(toc)
  }
}

///|
fn probe_file(path : String, key : String) -> (String, @jsonio.Json) {
  let raw = @fs.read_file_to_bytes(path) catch {
    _ => {
      die("无法读取 " + path)
      panic()
    }
  }
  let archive = @zipio.open_archive_from_bytes(
    path,
    raw,
    @zipio.DEFAULT_BUDGET_BYTES,
  )
  // 故意损坏的 fixture（如 malformed-opf）用全零结果表达「打开失败」，
  // 让它和 manifest 里的零期望值对账，而不是让整个探针退出。
  let book : @core.Book? = match archive {
    Err(_) => None
    Ok(a) =>
      match
        @core.open_book(
          a.archive,
          @config.default_config(),
          empty_rules(),
          @render.Null,
        ) {
        Err(_) => None
        Ok(b) => Some(b)
      }
  }
  let fields = match book {
    None =>
      [
        ("title", @jsonio.j_str("")),
        ("chapters", @jsonio.j_int(0)),
        ("toc_items", @jsonio.j_int(0)),
        ("resources", @jsonio.j_int(0)),
        ("cover", @jsonio.j_str("")),
        ("title_lang", @jsonio.j_str("")),
        ("publishers", @jsonio.j_arr([])),
        ("creator_role", @jsonio.j_str("")),
      ]
    Some(b) => {
      let publishers : Array[@jsonio.Json] = []
      for p in b.epub.metadata.publishers {
        publishers.push(@jsonio.j_str(p))
      }
      let title_lang = if b.epub.metadata.titles.length() > 0 {
        b.epub.metadata.titles[0].lang
      } else {
        ""
      }
      [
        ("title", @jsonio.j_str(b.epub.metadata.title)),
        ("chapters", @jsonio.j_int(@epub.chapter_paths(b.epub).length())),
        ("toc_items", @jsonio.j_int(toc_count(b.epub))),
        ("resources", @jsonio.j_int(b.epub.manifest.length())),
        ("cover", @jsonio.j_str(b.epub.metadata.cover_path)),
        ("title_lang", @jsonio.j_str(title_lang)),
        ("publishers", @jsonio.j_arr(publishers)),
        (
          "creator_role",
          @jsonio.j_str(
            if b.epub.metadata.creators.length() > 0 {
              b.epub.metadata.creators[0].1
            } else {
              ""
            },
          ),
        ),
      ]
    }
  }
  (key, @jsonio.j_obj(fields))
}

///|
fn empty_rules() -> @rules.RuleSet {
  match @rules.load_rules("{\"version\":1,\"rules\":[]}") {
    Ok(r) => r
    Err(e) => {
      die("内置空规则集加载失败：" + e)
      panic()
    }
  }
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 {
    die(
      "用法：moon run --target native tools/probe <corpus-dir> [<corpus-dir> ...]",
    )
  }
  let fields : Array[(String, @jsonio.Json)] = []
  let mut i = 1
  while i < args.length() {
    let dir = args[i] + "/epub"
    let names = @fs.read_dir(dir) catch {
      _ => {
        die("无法列目录 " + dir)
        panic()
      }
    }
    for name in names {
      if @util.ends_with(name, ".epub") {
        fields.push(probe_file(dir + "/" + name, "epub/" + name))
      }
    }
    i = i + 1
  }
  println(@jsonio.encode(@jsonio.j_obj(fields)))
}
