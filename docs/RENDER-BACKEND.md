# 渲染后端

`src/render` 提供稳定的度量接口，把「怎么排」隔离在内核之外。

## 1. 接口

```moonbit
pub(all) enum Backend {
  Null
  Crater
}

pub(all) struct RenderRequest {
  viewport_width : Double
  font_size_px : Double
  line_height : Double
  avg_char_width_ratio : Double
}

pub(all) struct MeasuredBlock {
  id : String
  lines : Int32
  height : Double
  splitable : Bool
}
```

调用方通过 `measure(backend, request, blocks)` 得到度量结果。分页层只消费
`MeasuredBlock`，不知道渲染后端是谁。

## 2. Backend::Null

零依赖、完全确定性的度量后端，用于：

- 分页算法测试；
- 进度 / 定位测试；
- `scripts/cross_target.sh` 的三端逐字节比对。

它不画像素，只按 `lines * line_height` 计算高度，并按平均字宽估算折行。

## 3. Backend::Crater

当前是外部依赖占位。接入真实 crater 时需要：

1. 用 `moonbit-community/html5-mbt` 解析章节 XHTML；
2. 用 `mizchi/css` 做样式级联与 computed style；
3. 调用 crater 的布局能力得到行盒数量；
4. 把行盒数量映射到 `MeasuredBlock.lines`；
5. 若可用，调用 crater 的 fragmentation 公共 API 处理可拆块。

接入点只在 `src/render`，不需要改 `src/paginate`。

## 4. 当前限制

- 尚未接入真实 crater / css / html5-mbt；
- 没有像素级回归测试；
- 远程资源与字体加载策略只在 `src/resource` 里定义接口，未与渲染层联通。
