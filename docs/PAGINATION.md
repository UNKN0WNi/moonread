# 分页

本文描述 `src/paginate` 的算法与不变式。每条不变式都有对应测试，可用 `moon test` 复现。

## 1. 两层分工

| 层 | 负责 | 位置 |
|---|---|---|
| 排版 | 把 DOM / 布局树变成块，计算行盒与高度 | 渲染后端（当前由 `Backend::Null` 模拟） |
| 分片 | 把块切成片段，处理断点、避免重叠、页眉页脚 | `src/paginate` |

分页层接收的是「块 + 高度 + 行数」，不直接碰 DOM。这样替换渲染后端时，
分页算法与不变式不受影响。

## 2. 策略来源

`config.json` 的 `page` 段以毫米为单位，`src/config` 负责换算成分页层的 CSS px
（96 dpi）。`typography` 的字号与行高也参与块高度计算。

主要字段：

| 字段 | 含义 |
|---|---|
| `page.width_mm` / `page.height_mm` | 纸张尺寸 |
| `margin_*_mm` | 页边距；上下之和必须小于页高，左右之和必须小于页宽 |
| `column_gap_mm` | 分栏间距 |
| `direction` | `ltr` / `rtl` |
| `typography.font_size_pt` | 字号 |
| `typography.line_height` | 行高倍数 |

## 3. 四条不变式

| 不变式 | 含义 | 测试方式 |
|---|---|---|
| 不丢内容 | 分页前后块高度 / 行数总和一致 | 对比分页前后 `sum_block_heights` |
| 不越界 | 每页用量不超过页容量 | 逐页检查 `used <= limit` |
| 单调 | 后续页不会回到前面 | 检查片段顺序索引递增 |
| 幂等 | 同样输入重复运行得到同样结果 | 连续运行两次比较结果 |

## 4. 术语澄清

`orphan_min` / `widow_min` 采用 CSS 原始定义：对**被拆分的那个块**生效——
`orphan_min` 是该块在前页留下的最少行数，`widow_min` 是在后页留下的最少行数。
不是「章节末 / 章节首」的整章概念。

## 5. 可拆与不可拆块

- 标题、图片、表格等不可拆块尽量整体移动；
- 段落等可拆块按行切分；
- 断点优先级：显式分页 > 标题前断页 > 孤行 / 寡行控制 > 普通容纳判断；
- 影响记录在 `PageEffects.breaks_before` / `PageEffects.removed`，便于诊断规则是否生效。

## 6. 页眉页脚

页眉页脚模板支持 `{page}` / `{total}` 占位符，渲染前按当前页替换。
`Backend::Null` 下页脚文本也参与确定性输出，因此三端可以逐字节比对。

## 7. 当前限制

- 尚未接入真实 crater 的 `fragmentation` 公共 API；
- 还没有与 KOReader / foliate 做逐页边界对照；
- `moon prove` 需要外部 SMT 求解器，仓库未内置。
