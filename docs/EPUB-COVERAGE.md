# EPUB 支持范围

本文按代码位置说明 EPUB / CBZ 的支持矩阵。目标是「内核可解析、可降级」，不是完整
阅读器界面。

## 1. 支持矩阵

| 能力 | 状态 | 代码位置 |
|---|---|---|
| `mimetype` 首位、ZIP 条目读取 | ✅ | `src/zipio`、`src/container` |
| `META-INF/container.xml` | ✅ | `src/epub/parse.mbt` |
| OPF 2.0 / 3.0 `manifest` / `spine` / `metadata` | ✅ | `src/epub/parse.mbt` |
| `nav` 目录 | ✅ | `src/epub/parse.mbt` |
| NCX 目录（EPUB2） | ✅ | `src/epub/parse.mbt` |
| 章节 XHTML 读取 | ✅ | `src/epub/open.mbt` |
| 资源相对路径 / URL 编码 / base64 | ✅ | `src/resource` |
| DRM / 加密声明检测 | ✅ 仅检测并提示 | `src/epub/parse.mbt` |
| 缺 nav / 缺 spine / 重复 id / 非法 XML 降级 | ✅ 告警不 panic | `src/epub/parse.mbt` |
| CBZ 页面顺序 / RTL / 跨页 | ✅ 接口与数据 | `src/comic` |
| 真实 ZIP 解压（STORED / DEFLATE，含 mimetype 首位） | ✅ 已接入 | `src/zipio/fzip_adapter.mbt`（`hustcer/fzip`）；真实书经 `apps/epub-cli` 验证 |
| OPF `collection` / 多文档 | ❌ 未实现 | — |
| DRM 解密 | ❌ 非目标 | — |
| RAR / 7z 解码 | ❌ 非目标 | — |

## 2. 容错策略

畸形输入不 panic，而是返回 `Ok(book) + warnings`：

- 缺 `container.xml`：清晰报错；
- 缺 nav：回退到 NCX，再回退到 spine 顺序；
- 重复 manifest id：跳过重复项并记录告警；
- `<meta>...</meta>` 按普通 XML 元素处理，不当 HTML void tag；
- 加密声明：只提示，不尝试解密。

## 3. 测试语料

`tools/gen_fixtures.py` 生成 15 本最小 EPUB，覆盖：

- EPUB2 + NCX / EPUB3 + nav / 双目录 / 无目录；
- 零章节 / 三十章节；
- mimetype 位置异常 / 坏 idref / 重复 id；
- 加密声明 / 封面 / 无 CSS / 实体标题；
- 缺 creator / language / container / OPF 畸形。

清单在 `tests/fixtures/manifest.json`。用下面命令检查：

```bash
python3 tools/gen_fixtures.py
python3 tools/corpus_check.py --require-manifest --skip-missing-books
```

当前只做清单自检；与内核解析结果的自动对账尚未接入 CI。
