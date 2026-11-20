/// 结构路径：规则（L4）与渲染度量（L3）共用的**唯一**路径来源。
///
/// 一条路径形如 `html[0]/body[1]/p[2]`：从文档根起，每段是 `tag[index]`。
/// `index` 是元素在其父节点的**元素子节点**中的序号（从 0 起），文本节点
/// 一律不占序号。这是两条管线必须一致的约定——`rules` 用它记录断页目标，
/// `render` 用它标记度量块，`apply_break_marks` 按字符串相等对接；任何一侧
/// 改变编号方式都会让规则静默失效。
///
/// `root_path` 表示根元素自身，为空串；此时根的第一个元素子节点从 `[0]` 起。

///|
/// 拼接一段子路径。`parent` 为空串表示父节点是文档根。
pub fn child_path(parent : String, tag : String, index : Int32) -> String {
  let seg = tag + "[" + index.to_string() + "]"
  if parent.length() == 0 {
    seg
  } else {
    parent + "/" + seg
  }
}

///|
/// 按统一编号遍历一棵子树，产出 `(路径, 元素)` 列表（先序，含 `el` 自身）。
/// 文本节点不占序号；`el` 自身的路径是 `base`，其元素子节点依次 base + child_path。
pub fn walk_paths(
  el : Element,
  base : String,
  out : Array[(String, Element)],
) -> Unit {
  out.push((base, el))
  let mut idx = 0
  for c in el.children {
    match c {
      EElement(child) => {
        walk_paths(child, child_path(base, child.tag, idx), out)
        idx = idx + 1
      }
      EText(_) => ()
    }
  }
}

///|
/// 文档根下第一个 `tag` 匹配元素的完整路径；找不到返回空串。
/// 根自身若匹配，返回空串（根路径）。
pub fn path_of_first(el : Element, tag : String) -> String {
  let all : Array[(String, Element)] = []
  walk_paths(el, "", all)
  for kv in all {
    if tag_is(kv.1, tag) {
      return kv.0
    }
  }
  ""
}
