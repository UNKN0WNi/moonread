#!/usr/bin/env python3
"""严格 JSON 自检。

做四件事：
  1. 仓库内所有 .json 必须能被 json.load 通过（排除注释、尾随逗号等宽松写法）；
  2. 有 JSON Schema 的文件必须通过 schema 校验；
  3. Schema 与 MoonBit 实现的字段表不得漂移
     —— 与 src/config/config.mbt 的 known_field_paths()、
        src/rules/load.mbt 的 supported_action_types() 对账（解析源码文本，不依赖 moon）；
  4. examples/*.json 必须能被 schema 校验，且不含 schema 未声明的字段。

退出码非 0 即 CI 失败。
"""

from __future__ import annotations

import ast
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SKIP_DIRS = {".git", "_target", "node_modules", "__pycache__"}


def iter_json_files():
    for p in ROOT.rglob("*.json"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        yield p


def load_strict(path: Path):
    """严格解析：拒绝重复键、NaN/Infinity。"""
    text = path.read_text(encoding="utf-8")

    def reject_duplicates(pairs):
        seen = set()
        for k, _ in pairs:
            if k in seen:
                raise ValueError(f"重复键 {k!r}")
            seen.add(k)
        return dict(pairs)

    def reject_const(s):
        raise ValueError(f"非法常量 {s!r}")

    return json.loads(
        text,
        object_pairs_hook=reject_duplicates,
        parse_constant=reject_const,
    )


def check_all_parseable():
    errors = []
    files = list(iter_json_files())
    for p in files:
        try:
            load_strict(p)
        except Exception as e:  # noqa: BLE001
            errors.append(f"{rel(p)}: {e}")
    return files, errors


def rel(p: Path) -> str:
    return str(p.relative_to(ROOT))


def check_schema_contracts():
    """schema/*.json 自身必须是合法的 draft 2020-12 风格声明。"""
    errors = []
    for p in sorted((ROOT / "schema").glob("*.schema.json")):
        doc = load_strict(p)
        if doc.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
            errors.append(f"{rel(p)}: $schema 不是 draft/2020-12")
        if "$id" not in doc:
            errors.append(f"{rel(p)}: 缺少 $id")
        # 所有 object 必须声明 additionalProperties，避免悄悄接受未知字段。
        for path, node in walk(doc):
            if node.get("type") == "object" and "additionalProperties" not in node:
                if "$defs" not in path and path != ():
                    errors.append(f"{rel(p)} {fmt_path(path)}: object 未声明 additionalProperties")
    return errors


def walk(node, prefix=()):
    if isinstance(node, dict):
        yield prefix, node
        for k, v in node.items():
            if isinstance(v, (dict, list)):
                yield from walk(v, prefix + (k,))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            if isinstance(v, (dict, list)):
                yield from walk(node and v, prefix + (i,))


def fmt_path(path):
    return ".".join(str(x) for x in path)


def extract_moonbit_consts(path: Path, name: str):
    """从 .mbt 源码里抠出 `const name = [ ... ]` 的字符串列表。"""
    text = path.read_text(encoding="utf-8")
    m = re.search(rf"const\s+{re.escape(name)}\s*=\s*\[(.*?)\n\]", text, re.S)
    if not m:
        m = re.search(rf"const\s+{re.escape(name)}\s*=\s*\[(.*?)\]", text, S:=re.S)
    if not m:
        return None
    body = "[" + m.group(1) + "]"
    body = re.sub(r"//[^\n]*", "", body)
    try:
        return ast.literal_eval(body)
    except Exception:  # noqa: BLE001
        return None


def check_config_schema_drift():
    """config.schema.json 的 properties 必须与 config.mbt 的字段表一致。"""
    errors = []
    schema = load_strict(ROOT / "schema" / "config.schema.json")
    mbt = ROOT / "src" / "config" / "config.mbt"
    if not mbt.exists():
        return [f"{rel(mbt)} 不存在"]
    text = mbt.read_text(encoding="utf-8")

    def field_list(const_name):
        m = re.search(
            rf"(?:const|let)\s+{const_name}\s*(?::\s*[^=\n]+)?=\s*\[(.*?)\]",
            text,
            re.S,
        )
        if not m:
            return None
        try:
            return ast.literal_eval("[" + re.sub(r"//[^\n]*", "", m.group(1)) + "]")
        except Exception:  # noqa: BLE001
            return None

    props = schema.get("properties", {})
    for key, node in props.items():
        if key in ("$schema", "version") or node.get("type") != "object":
            continue
        const_name = {
            "theme": "theme_fields",
            "typography": "typography_fields",
            "page": "page_fields",
            "behavior": "behavior_fields",
            "storage": "storage_fields",
        }.get(key)
        if const_name is None:
            continue
        impl = field_list(const_name)
        if impl is None:
            errors.append(f"config.mbt 里找不到 {const_name}")
            continue
        spec = {k for k in node.get("properties", {}) if not k.startswith("_")}
        impl_set = set(impl)
        if spec != impl_set:
            only_schema = sorted(spec - impl_set)
            only_impl = sorted(impl_set - spec)
            errors.append(
                f"$.{key} 字段漂移：只在 schema 有 {only_schema}；只在实现有 {only_impl}"
            )

    top = field_list("top_fields")
    if top is not None:
        spec = {k for k in props if not k.startswith("_")}
        impl = set(top)
        if spec != impl:
            errors.append(
                f"$ 顶层字段漂移：只在 schema 有 {sorted(spec - impl)}；"
                f"只在实现有 {sorted(impl - spec)}"
            )
    return errors


def check_rules_schema_drift():
    errors = []
    schema = load_strict(ROOT / "schema" / "rules.schema.json")
    action_enum = (
        schema.get("$defs", {}).get("action", {}).get("properties", {}).get("type", {}).get("enum", [])
    )
    mbt = ROOT / "src" / "rules" / "load.mbt"
    text = mbt.read_text(encoding="utf-8") if mbt.exists() else ""
    m = re.search(r"pub fn supported_action_types\(\)[^{]*\{\s*\[(.*?)\]", text, re.S)
    impl = []
    if m:
        impl = re.findall(r'"([^"]+)"', m.group(1))
    if not impl:
        errors.append("rules/load.mbt 里没解析出 supported_action_types()")
    elif set(action_enum) != set(impl):
        errors.append(
            f"动作类型漂移：只在 schema 有 {sorted(set(action_enum) - set(impl))}；"
            f"只在实现有 {sorted(set(impl) - set(action_enum))}"
        )
    return errors


def check_examples():
    """examples/*.json 必须通过对应 schema 校验（需要 jsonschema 包）。"""
    errors = []
    try:
        import jsonschema  # type: ignore
    except ImportError:
        return ["未安装 jsonschema，跳过 schema 校验（CI 里应 pip install jsonschema）"]

    pairs = [
        ("examples/config.json", "schema/config.schema.json"),
        ("examples/rules.json", "schema/rules.schema.json"),
    ]
    for inst_rel_p, sch_rel_p in pairs:
        ip = ROOT / inst_rel_p
        sp = ROOT / sch_rel_p
        if not ip.exists() or not sp.exists():
            errors.append(f"缺少文件：{inst_rel_p} 或 {sch_rel_p}")
            continue
        try:
            jsonschema.validate(load_strict(ip), load_strict(sp))
        except Exception as e:  # noqa: BLE001
            errors.append(f"{inst_rel_p} 未通过 {sch_rel_p}：{e}")
    return errors


def main() -> int:
    print("== 1. 所有 .json 严格解析 ==")
    files, errors = check_all_parseable()
    print(f"  共 {len(files)} 个文件")
    for e in errors:
        print(f"  FAIL {e}")

    print("== 2. schema 自身约束 ==")
    e2 = check_schema_contracts()
    for e in e2:
        print(f"  FAIL {e}")

    print("== 3. config schema 与实现字段表对账 ==")
    e3 = check_config_schema_drift()
    for e in e3:
        print(f"  FAIL {e}")

    print("== 4. rules schema 与实现动作表对账 ==")
    e4 = check_rules_schema_drift()
    for e in e4:
        print(f"  FAIL {e}")

    print("== 5. examples 通过 schema 校验 ==")
    e5 = check_examples()
    for e in e5:
        print(f"  FAIL {e}")

    all_err = errors + e2 + e3 + e4 + e5
    if all_err:
        print(f"\n共 {len(all_err)} 项失败")
        return 1
    print("\n全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
