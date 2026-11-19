///|
/// 书签与阅读位置持久化。
///
/// 存储格式是严格 JSON（）：一个对象数组，顺序即用户添加顺序。
/// 内核**不读写文件系统**——`Store` 只做序列化与增删改查，落盘由宿主完成。
/// 这样内核在浏览器（localStorage）、桌面（文件）、服务端（数据库）里
/// 用的是同一套逻辑，满足 「一次源码，四端分发」。
#derive(Debug, Eq)
pub(all) struct Bookmark {
  /// 稳定 id。由 `add` 生成（自增计数），不由内容哈希，
  /// 因为删除后 id 不复用更利于宿主做增量同步。
  id : Int32
  label : String
  note : String
  locator : @paginator.Locator
  /// ISO-8601 文本，由宿主传入（内核不读时钟）。
  created : String
}

///|
#derive(Debug, Eq)
pub(all) struct Store {
  book_key : String
  items : Array[Bookmark]
}

///|
pub fn new_store(book_key : String) -> Store {
  Store::{ book_key, items: [], }
}

///| 自增 id 由当前最大 id 推出，不额外保存计数器——

///|
/// 少一个可变字段就少一处状态不同步的可能。
pub fn next_id(s : Store) -> Int32 {
  let mut m = 0
  for b in s.items {
    if b.id > m {
      m = b.id
    }
  }
  m + 1
}

///|
pub fn add(
  s : Store,
  label : String,
  note : String,
  loc : @paginator.Locator,
  created : String,
) -> Int32 {
  let id = next_id(s)
  s.items.push(Bookmark::{ id, label, note, locator: loc, created, })
  id
}

///|
pub fn find(s : Store, id : Int32) -> Bookmark? {
  let mut found : Bookmark? = None
  for b in s.items {
    if b.id == id {
      found = Some(b)
      break
    }
  }
  found
}

///|
/// 删除返回新表与是否命中；id 不存在时不报错（幂等）。
pub fn remove(s : Store, id : Int32) -> (Store, Bool) {
  let mut idx = -1
  let mut i = 0
  while i < s.items.length() {
    if s.items[i].id == id {
      idx = i
      break
    }
    i = i + 1
  }
  if idx < 0 {
    return (s, false)
  }
  let rest : Array[Bookmark] = []
  let mut j = 0
  while j < s.items.length() {
    if j != idx {
      rest.push(s.items[j])
    }
    j = j + 1
  }
  (Store::{ book_key: s.book_key, items: rest, }, true)
}

///|
pub fn update_label(s : Store, id : Int32, label : String) -> Bool {
  let mut ok = false
  let mut i = 0
  while i < s.items.length() {
    if s.items[i].id == id {
      let b = s.items[i]
      s.items[i] = Bookmark::{
        id: b.id,
        label,
        note: b.note,
        locator: b.locator,
        created: b.created,
      }
      ok = true
      break
    }
    i = i + 1
  }
  ok
}

///|
pub fn count(s : Store) -> Int32 {
  s.items.length()
}

///|
/// 按章节过滤（目录侧栏常用）。
pub fn in_chapter(s : Store, chapter : Int32) -> Array[Bookmark] {
  let out : Array[Bookmark] = []
  for b in s.items {
    if b.locator.chapter == chapter {
      out.push(b)
    }
  }
  out
}

// ---------------- JSON ----------------

///|
fn bookmark_to_json(b : Bookmark) -> String {
  "{" +
  "\"id\":" +
  b.id.to_string() +
  ",\"label\":" +
  @jsonio.encode_string_literal(b.label) +
  ",\"note\":" +
  @jsonio.encode_string_literal(b.note) +
  ",\"chapter\":" +
  b.locator.chapter.to_string() +
  ",\"page\":" +
  b.locator.page.to_string() +
  ",\"total_pages\":" +
  b.locator.total_pages.to_string() +
  ",\"anchor\":" +
  @jsonio.encode_string_literal(b.locator.anchor) +
  ",\"created\":" +
  @jsonio.encode_string_literal(b.created) +
  "}"
}

///|
pub fn to_json_text(s : Store) -> String {
  let parts : Array[String] = []
  parts.push("\"book_key\":" + @jsonio.encode_string_literal(s.book_key))
  parts.push("\"version\":1")
  let items : Array[String] = []
  for b in s.items {
    items.push(bookmark_to_json(b))
  }
  let mut joined = "["
  let mut i = 0
  while i < items.length() {
    if i > 0 {
      joined = joined + ","
    }
    joined = joined + items[i]
    i = i + 1
  }
  joined = joined + "]"
  parts.push("\"items\":" + joined)
  let mut obj = "{"
  let mut k = 0
  while k < parts.length() {
    if k > 0 {
      obj = obj + ","
    }
    obj = obj + parts[k]
    k = k + 1
  }
  obj + "}"
}

///|
pub fn from_json_text(text : String) -> Result[Store, String] {
  match @jsonio.parse(text) {
    Err(e) => Err("书签文件不是合法 JSON：" + e)
    Ok(root) =>
      match
        @jsonio.reject_unknown_fields(
          root,
          ["book_key", "version", "items"],
          "$",
        ) {
        Err(e) => return Err(e)
        Ok(_) => {
          let book_key = match @jsonio.require_str(root, "book_key", "$") {
            Ok(__try_v_1) => __try_v_1
            Err(__try_e_1) => return Err(__try_e_1)
          }
          let version = match @jsonio.obj_get(root, "version") {
            None => 1
            Some(v) =>
              match @jsonio.as_int(v) {
                Some(1) => 1
                Some(n) =>
                  return Err("$.version 只支持 1，实际 " + n.to_string())
                None => return Err("$.version 必须是整数")
              }
          }
          let _ = version
          let arr = match @jsonio.require_arr(root, "items", "$") {
            Ok(__try_v_2) => __try_v_2
            Err(__try_e_2) => return Err(__try_e_2)
          }
          let s = new_store(book_key)
          let mut i = 0
          while i < arr.length() {
            let item = arr[i]
            match
              @jsonio.reject_unknown_fields(
                item,
                [
                  "id", "label", "note", "chapter", "page", "total_pages", "anchor",
                  "created",
                ],
                "$.items[" + i.to_string() + "]",
              ) {
              Err(e) => return Err(e)
              Ok(_) => ()
            }
            let id = match
              @jsonio.require_int(item, "id", "$.items[" + i.to_string() + "]") {
              Ok(__try_v_3) => __try_v_3
              Err(__try_e_3) => return Err(__try_e_3)
            }
            if id <= 0 {
              return Err("$.items[" + i.to_string() + "].id 必须为正整数")
            }
            let label = match
              @jsonio.require_str(
                item,
                "label",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_4) => __try_v_4
              Err(__try_e_4) => return Err(__try_e_4)
            }
            let note = match
              @jsonio.require_str(
                item,
                "note",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_5) => __try_v_5
              Err(__try_e_5) => return Err(__try_e_5)
            }
            let chapter = match
              @jsonio.require_int(
                item,
                "chapter",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_6) => __try_v_6
              Err(__try_e_6) => return Err(__try_e_6)
            }
            let page = match
              @jsonio.require_int(
                item,
                "page",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_7) => __try_v_7
              Err(__try_e_7) => return Err(__try_e_7)
            }
            let total_pages = match
              @jsonio.require_int(
                item,
                "total_pages",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_8) => __try_v_8
              Err(__try_e_8) => return Err(__try_e_8)
            }
            let anchor = match
              @jsonio.require_str(
                item,
                "anchor",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_9) => __try_v_9
              Err(__try_e_9) => return Err(__try_e_9)
            }
            let created = match
              @jsonio.require_str(
                item,
                "created",
                "$.items[" + i.to_string() + "]",
              ) {
              Ok(__try_v_10) => __try_v_10
              Err(__try_e_10) => return Err(__try_e_10)
            }
            if chapter < 0 || page < 0 || total_pages < 0 {
              return Err("$.items[" + i.to_string() + "] 含负数下标")
            }
            s.items.push(Bookmark::{
              id,
              label,
              note,
              locator: @paginator.locator_at(chapter, page, total_pages, anchor),
              created,
            })
            i = i + 1
          }
          Ok(s)
        }
      }
  }
}

///|
/// 进度文件（`progress_format: json`）。直接复用 paginator 的编码。
pub fn save_progress(p : @paginator.Progress) -> String {
  @paginator.progress_to_json(p)
}

///|
pub fn load_progress(text : String) -> Result[@paginator.Progress, String] {
  @paginator.progress_from_json(text)
}
