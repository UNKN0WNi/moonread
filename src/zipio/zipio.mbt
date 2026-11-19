/// ZIP 接入层。
///
/// 解压实现用 `hustcer/fzip`，但调用面被收敛到**唯一**一个文件
/// `fzip_adapter.mbt`；本文件保持纯函数，不感知 fzip 的细节。二者分工：
///
/// 1. `fzip_adapter.mbt`：把文件字节交给 `@fzip.unzip_sync`，按名字分类文本 /
///    二进制，UTF-8 解码文本条目，得到 `Array[DecodedEntry]`。
/// 2. `entries_to_archive`（本文件）：**纯函数**，把「已解码的条目列表」变成
///    `Archive`，包含 zip-bomb 预算、路径安全、重名与顺序告警。
///
/// 这样做的收益：
/// - fzip 换实现（`CAIMEOX/zipper`、系统 zlib、宿主直传目录）只需替换适配器一个文件；
/// - 归档归纳逻辑可独立单测，四端行为一致。
///
/// ## 已知约束
///
/// - EPUB 要求 `mimetype` 是第一个条目且 **STORED**；fzip 的 `ZipEntryOptions.level`
///   对所有条目统一生效，因此**写 EPUB** 需要专门构造首条目。
///   本项目首发只读，写入路径另立项目。
/// - 二进制条目（图片、字体）**不经过** `Archive` 的 String 通道，避免 UTF-8
///   有损解码；由宿主用 `mizchi/image-mbt` 解码后交给渲染后端。

///|
/// 已知的 fzip 版本。
pub const FZIP_VERSION = "0.8.8"

///|
/// 一个已解码条目的中间表示。`text` 为 None 表示二进制内容。
#derive(Debug, Eq)
pub(all) struct DecodedEntry {
  name : String
  byte_len : Int32
  text : String?
}

///|
pub fn text_entry(name : String, content : String) -> DecodedEntry {
  DecodedEntry::{
    name,
    byte_len: @util.utf8_len(content),
    text: Some(content),
  }
}

///|
pub fn binary_entry(name : String, byte_len : Int32) -> DecodedEntry {
  DecodedEntry::{ name, byte_len, text: None, }
}

///|
#derive(Debug, Eq)
pub(all) struct ZipReport {
  archive : @container.Archive
  /// 文本条目名，顺序与归档中央目录一致。
  text_names : Array[String]
  /// 二进制条目名（图片/字体）。
  binary_names : Array[String]
  /// 被拒条目与降级说明。
  warnings : Array[String]
  /// 解压后总字节数，用于对照 zip-bomb 预算。
  total_bytes : Int32
}

///| 默认解压预算：64 MiB。fzip 自身按压缩比（>1000×）拦截，这里再加一道

///|
/// **输出总量**上限，双保险。
pub const DEFAULT_BUDGET_BYTES = 67108864

///|
/// 把已解码条目整理成 `Archive` + 报告。**纯函数，无外部依赖。**
pub fn entries_to_archive(
  name : String,
  entries : Array[DecodedEntry],
  budget_bytes : Int32,
) -> Result[ZipReport, String] {
  if budget_bytes <= 0 {
    return Err("解压预算必须为正，实际 " + budget_bytes.to_string())
  }
  let text_items : Array[(String, String)] = []
  let binary_names : Array[String] = []
  let warnings : Array[String] = []
  let mut total = 0
  for e in entries {
    if e.byte_len < 0 {
      return Err("条目 '" + e.name + "' 长度为负，解压结果不可信")
    }
    total = total + e.byte_len
    if total > budget_bytes {
      warnings.push(
        "解压后总量 " +
        total.to_string() +
        " 超出预算 " +
        budget_bytes.to_string() +
        " 字节，在 '" +
        e.name +
        "' 处停止收录（zip-bomb 防护）",
      )
      break
    }
    match e.text {
      Some(t) => text_items.push((e.name, t))
      None => binary_names.push(e.name)
    }
  }
  let (a, cw) = @container.build_checked(name, text_items, budget_bytes)
  for w in cw {
    warnings.push(w)
  }
  if a.items.length() > 0 && a.items[0].0 != "mimetype" {
    if @container.has(a, "mimetype") {
      warnings.push(
        "mimetype 存在但不在首位（违反 EPUB 规范，读取侧容忍）",
      )
    }
  }
  Ok(ZipReport::{
    archive: a,
    text_names: @container.names(a),
    binary_names,
    warnings,
    total_bytes: total,
  })
}

///|
/// 供 `fzip_adapter` 使用的统一错误前缀，保证不同解压后端的报错文案一致。
pub fn adapter_error(backend : String, detail : String) -> String {
  backend +
  " 解压失败：" +
  detail +
  "（接入点：src/zipio/fzip_adapter.mbt）"
}
