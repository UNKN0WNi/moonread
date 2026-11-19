# 开发指南

本文记录在当前 MoonBit 工具链（`moon 0.1.20261117`）下开发本项目时必须遵守的写法。
新代码提交前先跑 `bash scripts/ci.sh`。

## 1. 环境与命令

```bash
source scripts/toolchain-env.sh
moon fmt
moon check --deny-warn
moon test --target native
moon test --target js
moon test --target wasm
moon test --target wasm-gc
bash scripts/cross_target.sh
python3 tools/validate_json.py
python3 tools/corpus_check.py --require-manifest --skip-missing-books
```

`scripts/toolchain-env.sh` 解析顺序：`MOON` 环境变量 → `PATH` 中已有的 `moon` →
`MOON_BIN_DIR` → 常用安装目录 → 工作区受管目录。脚本内部调用会设置
`TOOLCHAIN_ENV_QUIET=1`，避免刷屏。

## 2. MoonBit 写法约定

| 约定 | 例子 | 说明 |
|---|---|---|
| 布尔值小写 | `true` / `false` | 不接受 `True` / `False` |
| 匿名函数用 `fn` | `fn(x) { x }` | 不写 `fun(...)` |
| 错误传播显式展开 | `match f() { Ok(v) => v, Err(e) => return Err(e) }` | 当前工具链不接受 `expr?` |
| 错误入口声明 | `fn main raise` | 允许错误向上传播 |
| 元组用 `.0` / `.1` | `kv.0`、`kv.1` | 不支持 `(String, String)[0]` |
| 字面量避免科学计数法 | `0.000000001` | `1e-9` 无法解析 |
| `panic()` 不传参数 | `panic()` | `panic("msg")` 会报参数个数错误 |
| `guard` / `ref` 不当标识符 | 改用 `attempt` / `r` | 保留字 / 保留警告 |
| 派生用 `derive(Debug)` | `#derive(Debug, Eq)` | `derive(Show)` 已弃用 |
| 调试字符串用 `@debug.to_string` | 不写 `value.to_string()`（复合类型） | `Show` 正逐步迁移到 `Debug` |
| 顶层数组显式注解 | `let fields : ReadOnlyArray[String] = [...]` | 避免 `unannotated_toplevel_array` 警告 |

## 3. 包清单

当前工具链使用 `moon.pkg`（DSL 形式），不是 JSON：

```moonbit
// 包清单：imports 列出本包依赖的其他包，路径为「模块名/目录」。
import {
  "moonread/moonread/src/util",
  "moonread/moonread/src/jsonio",
}
```

可执行包额外写：

```moonbit
pkgtype(kind: "executable")
```

不要写 `package` 行；包名由目录决定。本地 workspace 依赖仍需写版本号，见
`src/zipio/fzip_adapter.mbt.example`。

## 4. 测试约定

- 黑盒测试 `*_test.mbt` 必须用 `@pkg.fn` 限定调用；
- `assert_true(..., msg=...)` 所在函数若可能失败，签名要写 `-> Unit raise`；
- 测试不要依赖文件系统，EPUB 语料用 `src/epub/fixture.mbt` 在内存构造；
- 四端测试数量应一致；当前为每端 98 项。

## 5. 修改配置 / 规则

1. 改 `schema/*.schema.json` 的字段定义与 `description`；
2. 同步 `src/config/config.mbt` 里的 `*_fields` 或 `src/rules/load.mbt` 的动作表；
3. 在 `examples/*.json` 里用 `_comment` / `_how_to_customize` 写人话说明；
4. 运行 `python3 tools/validate_json.py`，它会做 schema ↔ 实现 ↔ 示例三方对账。

以 `_` 开头的键会被运行时忽略，因此可以安全地作为配置注释使用。

## 6. 提交前检查清单

- [ ] `moon fmt --check` 通过
- [ ] `moon check --target <每个 target> --deny-warn` 零警告
- [ ] 四端测试通过
- [ ] `bash scripts/cross_target.sh` 输出一致
- [ ] JSON / 语料自检通过
- [ ] 没有引入新的外部依赖；若引入，更新 `moon.mod` 与 CI
