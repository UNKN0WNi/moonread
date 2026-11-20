# 测试资产

仓库包含 `fixtures/`（项目自建）与 `corpus/`（第三方公版 EPUB）。
不附带未经许可的第三方电子书或漫画。

## fixtures

```text
tests/
├── fixtures/
│   ├── epub/            15 本最小 EPUB（由 tools/gen_fixtures.py 生成）
│   └── manifest.json    文件名、来源、许可与期望值
└── corpus/
    ├── epub/            2 本第三方公版 EPUB（含 Kobo 变体）
    └── manifest.json    来源、许可、SHA-256 与期望值
```

生成与检查：

```bash
python3 tools/gen_fixtures.py
python3 tools/corpus_check.py --require-manifest --require-probe
```

`--require-probe` 会调用 `tools/probe`，用真实内核解析磁盘上的 EPUB 并逐项对账。

`manifest.json` 记录每本书的：

- 文件名与相对路径；
- 生成方式（自建）与许可（Apache-2.0）；
- 期望的章节数 / 标题 / 目录条目数 / 资源数 / 告警。

## MoonBit 单元测试

单元测试不读这些文件，而是用 `src/epub/fixture.mbt` 在内存里构造 EPUB。
这样四端都能跑同一批断言：

```bash
moon test --target native
moon test --target js
moon test --target wasm
moon test --target wasm-gc
```

## 跨端一致性

`bash scripts/cross_target.sh` 会分别用 native / js / wasm-gc 运行
`apps/embed-demo`，再把输出逐字节比对。示例输出里包含分页结果、进度 JSON 和规则
命中统计，能覆盖大部分确定性逻辑。
