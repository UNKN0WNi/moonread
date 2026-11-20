# 渲染后端

`src/render` 提供稳定的度量接口，把「怎么排」隔离在内核之外。分页层
（`src/paginate`）只消费块序列，不关心渲染后端是谁。

## 1. 真实接口（与代码一致）

```moonbit
pub(all) enum Backend { Null  Crater }

pub(all) struct RenderRequest {
  doc : @xml.Element
  viewport_width : Double
  line_height : Double
  font_size_px : Double
  avg_char_width_ratio : Double
}

pub(all) struct MeasuredBlock {
  path : String            // 结构路径，与 @rules 共用 @xml.child_path 编号
  block : @paginate.Block  // 真正的块（分页层唯一消费的东西）
}

pub fn measure(b : Backend, req : RenderRequest)
  -> Result[Array[MeasuredBlock], String]
pub fn apply_break_marks(
  blocks : Array[MeasuredBlock],
  breaks_before : Array[String],
  breaks_after : Array[String],
) -> Array[@paginate.Block]
```

注意：`MeasuredBlock` 的字段是 `path` + `block`，**不是** `id` / `lines` /
`height` / `splitable`；那些字段在 `block : @paginate.Block` 里。路径编号由
`@xml.child_path` 单一来源提供（见 `src/xml/path.mbt`），规则侧与度量侧共用，
`apply_break_marks` 才能按路径对接。

## 2. Backend::Null —— 确定性测试替身

零依赖、完全确定性的度量后端，**不是生产排版后端**。它让分页算法、四条
不变式、三端一致性测试在没有 crater 的情况下可跑、可复现。

- 折行：`chars_per_line = floor(viewport_width / (font_size_px * ratio))`；
  行数按**显示宽度**累计（`display_width`：CJK / 全角记 2，其它记 1）。
- 高度：`lines * line_height`；标题乘字号缩放；图片 / figure / 表格用经验
  常量（`line_height * 8` / `* 6` / `* rows`）。
- 用途：`scripts/cross_target.sh` 的逐字节比对、全部内核测试。

它不画像素，误差可能很大（尤其图片与真实字体）。**不要用 Null 计算真实书的
精确页数**；生产排版应走 `Crater`。

## 3. Backend::Crater —— 待接入清单

当前 `measure(Crater, ..)` 返回清晰错误，不 panic。接入真实排版需要补齐下列
子包与适配，全部只在 `src/render` 内完成，**不需要改 `src/paginate`**：

| 步骤 | 子包 / 依赖 | 关键 API | 产出 |
|---|---|---|---|
| 1. HTML5 解析 | `moonbit-community/html5-mbt` | 解析章节 XHTML | DOM（替换自实现 XML 子集） |
| 2. 样式级联 | `mizchi/css` | computed style | 每个节点的计算样式 |
| 3. 布局 | `mizchi/crater-renderer` | `render_html_to_paint_tree(String, Size) -> PaintNode` | 绘制树（上游声称约 94% WPT CSS layout 通过率） |
| 4. 行盒→行数 | 适配层（新增） | 统计 `PaintNode` 的行盒数量 | `MeasuredBlock.block.lines` |
| 5. 分片（可选） | crater fragmentation API | 若可用则处理可拆块跨页 | 更精确的 `splittable` 片段 |

接入约束：

- 只影响 `measure` 的 `Crater` 分支；`Null` 保持确定性不变，测试与一致性
  脚本不受影响。
- 布局尺寸单位统一为 CSS px，与 `RenderRequest` 一致。
- 路径仍用 `@xml.child_path`，保证规则断页能对接到度量块（见 P0-1 回归测试）。
- 每个步骤都要有像素级或行盒级的回归样本，避免重演「近似模型误差 2 倍」。

## 4. 当前边界

- `src/zipio` **只是 ZIP 解压适配**（`hustcer/fzip`），与 crater 排版无关；
  曾有误注称 crater 适配在此，已更正。
- 远程资源与字体加载策略只在 `src/resource` 定义接口，未与渲染层联通。
- 无像素级回归测试；Crater 未接入前，`Null` 的估算不保证等于真实页数。
