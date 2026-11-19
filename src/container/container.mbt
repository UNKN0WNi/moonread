/// 归档抽象。
///
/// 要求容器层用 `hustcer/fzip`，同时 接口要求「容器层做成 trait，
/// 可替换为其他实现」。本仓库用**数据而非 trait** 表达这层抽象：
///
/// `Archive` 就是一个「有序条目表」（名字 -> 文本内容）。
/// 无论是 fzip 解出来的 ZIP、MemoryArchive 构造的测试语料，还是宿主直接
/// 传进来的目录树，落到这里都是同一种形状。这样：
/// - 容器层与解压实现彻底解耦，`moon test` 无需任何外部依赖即可跑；
/// - `derive(Eq)` 让 「三端输出逐字节一致」可以直接用结构相等断言；
/// - 唯一需要外部依赖的解压细节被隔离在 `src/zipio` 一个包里。
///
/// **边界**：`Archive` 只承载**文本**条目（XHTML / CSS / OPF / NCX / JSON）。
/// 图片与字体等二进制资源由 `zipio` 提供 `read_bytes`，交给渲染后端或宿主，
/// 不在内核里以 String 传递（避免 UTF-8 有损解码）。见 docs/ARCHITECTURE.md。

///|
/// 归档条目摘要。`byte_len` 是内容的 UTF-8 字节数，用于 zip-bomb 预算核对。
#derive(Debug, Eq)
pub(all) struct EntryInfo {
  name : String
  byte_len : Int32
}

///|
/// 有序条目表。条目顺序**有语义**：EPUB 要求 `mimetype` 是第一个条目。
#derive(Debug, Eq)
pub(all) struct Archive {
  name : String
  items : Array[(String, String)]
}

///|
pub fn archive(name : String, items : Array[(String, String)]) -> Archive {
  Archive::{ name, items, }
}

///|
/// 读取文本条目。不存在时返回带归档名的错误，不 panic（验收项）。
pub fn read(a : Archive, name : String) -> Result[String, String] {
  match find_index(a, name) {
    Some(i) => Ok(a.items[i].1)
    None => Err("归档 '" + a.name + "' 中不存在条目 '" + name + "'")
  }
}

///|
pub fn find_index(a : Archive, name : String) -> Int32? {
  let mut found : Int32? = None
  let mut i = 0
  while i < a.items.length() {
    if a.items[i].0 == name {
      found = Some(i)
      break
    }
    i = i + 1
  }
  found
}

///|
pub fn has(a : Archive, name : String) -> Bool {
  match find_index(a, name) {
    Some(_) => true
    None => false
  }
}

///|
pub fn names(a : Archive) -> Array[String] {
  let out : Array[String] = []
  for kv in a.items {
    out.push(kv.0)
  }
  out
}

///|
pub fn entry_count(a : Archive) -> Int32 {
  a.items.length()
}

///|
pub fn entries(a : Archive) -> Array[EntryInfo] {
  let out : Array[EntryInfo] = []
  for kv in a.items {
    out.push(EntryInfo::{ name: kv.0, byte_len: @util.utf8_len(kv.1), })
  }
  out
}

///|
pub fn total_bytes(a : Archive) -> Int32 {
  let mut n = 0
  for e in entries(a) {
    n = n + e.byte_len
  }
  n
}

///|
/// EPUB 规范硬性要求：`mimetype` 必须是第一个条目。读取侧据此做一致性告警。
pub fn mimetype_is_first(a : Archive) -> Bool {
  a.items.length() > 0 && a.items[0].0 == "mimetype"
}

///| 构造期校验：条目名安全性、重名、总量预算。

///| 返回（清洗后的归档, 告警列表）。**不报错**——真实语料脏（已知风险），

///|
/// 降级 + 告警是  的出口条件之一。
pub fn build_checked(
  name : String,
  items : Array[(String, String)],
  budget_bytes : Int32,
) -> (Archive, Array[String]) {
  let warnings : Array[String] = []
  let kept : Array[(String, String)] = []
  let mut total = 0
  for kv in items {
    if @util.zip_path_is_unsafe(kv.0) {
      warnings.push("拒绝不安全条目名 '" + kv.0 + "'")
      continue
    }
    match find_index(archive(name, kept), kv.0) {
      Some(_) => warnings.push("重复条目名 '" + kv.0 + "'，保留首个")
      None => {
        let l = @util.utf8_len(kv.1)
        if budget_bytes > 0 && total + l > budget_bytes {
          warnings.push(
            "输出总量超出预算 " +
            budget_bytes.to_string() +
            " 字节，在 '" +
            kv.0 +
            "' 处截断",
          )
          break
        }
        total = total + l
        kept.push((kv.0, kv.1))
      }
    }
  }
  (Archive::{ name, items: kept, }, warnings)
}

///|
/// 测试与 fixture 用的便捷构造：跳过校验，直接成归档。
pub fn memory_archive(items : Array[(String, String)]) -> Archive {
  archive("memory", items)
}

///|
/// 按自然序排序条目名（漫画页序用；见 src/comic）。
pub fn names_natural_sorted(a : Archive) -> Array[String] {
  let out = names(a)
  sort_natural(out)
  out
}

///| 稳定的自然序插入排序。条目数量级为「一本书的页面数」，

///|
/// 用插入排序换取零依赖与可预测行为（三端一致，）。
pub fn sort_natural(arr : Array[String]) -> Unit {
  let n = arr.length()
  let mut i = 1
  while i < n {
    let key = arr[i]
    let mut j = i - 1
    while j >= 0 && @util.natural_cmp(arr[j], key) == @util.Greater {
      arr[j + 1] = arr[j]
      j = j - 1
    }
    arr[j + 1] = key
    i = i + 1
  }
}
