#!/usr/bin/env python3
"""把内存 fixture 生成器（src/epub/fixture.mbt）落成磁盘上的 .epub / .cbz。

：自建最小 EPUB ≥15，许可 Apache-2.0（自建）。
`tools/gen_fixtures.py` 与 `src/epub/fixture.mbt::all_fixtures()` 必须产出
**同样的期望值**；期望值写在 tests/fixtures/manifest.json 里，供
tools/corpus_check.py 对账。

EPUB 规范硬性要求：
  - `mimetype` 必须是第一个条目，且 **STORED**（不压缩）；
  - 其余条目用 DEFLATE。
Python 的 zipfile 可以逐条目指定 compress_type，天然满足——
这正是指出的 fzip 限制（level 对所有条目统一生效）在
**写入侧**的绕法。本项目首发只读，写侧只在测试资产里需要。
"""

from __future__ import annotations

import html
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "fixtures" / "epub"

CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""


def chapter_xhtml(title: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh">\n'
        "<head><title>{t}</title>\n"
        '<link rel="stylesheet" type="text/css" href="style.css"/>\n'
        "</head>\n"
        "<body>\n"
        "<h1>{t}</h1>\n"
        "<p>Hello from MoonBit.</p>\n"
        "<p>第二段用于撑出分页所需的块高度。</p>\n"
        "</body>\n"
        "</html>\n"
    ).format(t=title)


CSS = (
    "body { margin: 0; padding: 1em; }\n"
    "h1 { font-size: 1.6em; page-break-before: always; }\n"
    "p { line-height: 1.6; text-align: justify; }\n"
)


def opf(title, creator, lang, chapters, epub3, with_nav, with_ncx, with_css,
        with_cover, broken_idref, rich_metadata=False, internal_entities=False,
        variant=""):
    ver = "3.0" if epub3 else "2.0"
    lines = ['<?xml version="1.0" encoding="utf-8"?>']
    if internal_entities:
        # EPUB 3.3 合法：DOCTYPE 内部子集声明内部实体（非外部实体）。
        lines += [
            '<!DOCTYPE package [',
            f'  <!ENTITY book.title "{title}">',
            f'  <!ENTITY book.lang "{lang}">',
            ']>',
        ]
    lang_attr = ' xml:lang="zh-Hant"' if variant == "package-lang" else ""
    lines += [
        f'<package xmlns="http://www.idpf.org/2007/opf" version="{ver}"{lang_attr} unique-identifier="uid">',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '    <dc:identifier id="uid">urn:uuid:moonread-sample</dc:identifier>',
    ]
    if internal_entities:
        # 合法 EPUB 3.3：标题文本与属性都引用内部实体。
        lines.append(
            '    <dc:title id="title-main" xml:lang="&book.lang;">&book.title;</dc:title>'
        )
    elif rich_metadata:
        # EPUB 3.3 合法写法：首个 dc:title 是主标题，其余按 xml:lang 区分；
        # creator 角色用 <meta refines> 表达，不丢插画师/别名/file-as 语义。
        lines += [
            f'    <dc:title id="title-main" xml:lang="en">{title}</dc:title>',
            '    <dc:title id="title-alt" xml:lang="ja">副題サンプル</dc:title>',
            f'    <dc:creator id="creator-main">{creator}</dc:creator>',
            '    <dc:creator id="creator-ill">Illustrator</dc:creator>',
            '    <meta refines="#creator-main" property="role" scheme="marc:relators">aut</meta>',
            '    <meta refines="#creator-ill" property="role" scheme="marc:relators">ill</meta>',
            '    <meta refines="#creator-main" property="alternate-script" xml:lang="ja">著者サンプル</meta>',
            '    <meta refines="#creator-main" property="file-as">MOONBIT, </meta>',
        ]
    else:
        lines += [
            f"    <dc:title>{title}</dc:title>",
            f"    <dc:creator>{creator}</dc:creator>",
        ]
    lines.append(f"    <dc:language>{lang}</dc:language>")
    if variant == "multivalue-dc":
        lines += [
            '    <dc:publisher>P1</dc:publisher><dc:publisher>P2</dc:publisher>',
            '    <dc:description>D1</dc:description><dc:description>D2</dc:description>',
            '    <dc:date>2026-01-01</dc:date><dc:date>2026-02-02</dc:date>',
            '    <dc:source>S1</dc:source><dc:source>S2</dc:source>',
            '    <dc:type>Text</dc:type><dc:coverage>World</dc:coverage>',
            '    <dc:relation>R</dc:relation><dc:format>application/xhtml+xml</dc:format>',
        ]
    if epub3:
        lines.append('    <meta property="dcterms:modified">2026-11-19T00:00:00Z</meta>')
    if with_cover or variant == "cover-legacy":
        lines.append('    <meta name="cover" content="cover-img"/>')
    lines += ["  </metadata>", "  <manifest>"]
    if with_nav:
        lines.append(
            '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
        )
    for cid, _t in chapters:
        lines.append(
            f'    <item id="{cid}" href="{cid}.xhtml" media-type="application/xhtml+xml"/>'
        )
    if with_css:
        lines.append('    <item id="css" href="style.css" media-type="text/css"/>')
    if variant == "cover-legacy":
        lines += [
            '    <item id="other-img" href="other.png" media-type="image/png"/>',
            '    <item id="cover-img" href="cover.png" media-type="image/png"/>',
        ]
    if with_cover:
        lines.append(
            '    <item id="cover-img" href="cover.png" media-type="image/png" properties="cover-image"/>'
        )
    if variant == "fallback":
        lines.append(
            '    <item id="foreign" href="foreign.jpg" media-type="image/jpeg" fallback="ch1"/>'
        )
    if variant == "svg":
        lines.append(
            '    <item id="svg" href="page.svg" media-type="image/svg+xml"/>'
        )
    if with_ncx:
        lines.append(
            '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>'
        )
    lines += ["  </manifest>", "  <spine>"]
    if with_ncx:
        lines.append('    <itemref idref="ncx" linear="no"/>')
    for cid, _t in chapters:
        lines.append(f'    <itemref idref="{cid}"/>')
    if variant == "fallback":
        lines.append('    <itemref idref="foreign"/>')
    if variant == "svg":
        lines.append('    <itemref idref="svg"/>')
    if broken_idref:
        lines.append('    <itemref idref="ghost"/>')
    lines += ["  </spine>", "</package>"]
    return "\n".join(lines) + "\n"


def nav_xhtml(chapters, rich_metadata=False, variant=""):
    if variant == "nav-multivalue":
        items = "\n".join(f'<li><a href="{c}.xhtml">{t}</a></li>' for c, t in chapters)
        return (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
            "<head><title>目录</title></head><body>\n"
            '<nav epub:type="landmarks"><ol><li><a href="ch1.xhtml">地标项</a></li></ol></nav>\n'
            '<nav epub:type="toc landmarks"><h1>目录</h1><ol>\n'
            + items
            + "\n</ol></nav>\n</body></html>\n"
        )
    if rich_metadata:
        # EPUB 3.3 合法：span 分组标题（无 href）+ 嵌套 ol，hidden 空值分支。
        items = "\n".join(f'<li><a href="{c}.xhtml">{t}</a></li>' for c, t in chapters)
        c0 = chapters[0][0] if chapters else "ch1"
        body = (
            '<li><span>分组：样例章</span>\n<ol>\n'
            + items
            + f'\n<li hidden=""><a href="{c0}.xhtml">隐藏分支</a></li>'
            + "\n</ol></li>"
        )
    else:
        body = "\n".join(f'<li><a href="{c}.xhtml">{t}</a></li>' for c, t in chapters)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
        "<head><title>目录</title></head>\n<body>\n"
        '<nav epub:type="toc" id="toc">\n<h1>目录</h1>\n<ol>\n'
        + body
        + "\n</ol>\n</nav>\n</body>\n</html>\n"
    )


def ncx_xml(title, chapters):
    pts = []
    for i, (c, t) in enumerate(chapters, start=1):
        pts.append(
            f'    <navPoint id="np{i}" playOrder="{i}">\n'
            f"      <navLabel><text>{t}</text></navLabel>\n"
            f'      <content src="{c}.xhtml"/>\n'
            f"    </navPoint>"
        )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\n'
        "  <head>\n"
        '    <meta name="dtb:uid" content="urn:uuid:moonread-sample"/>\n'
        '    <meta name="dtb:depth" content="1"/>\n'
        "  </head>\n"
        f"  <docTitle><text>{title}</text></docTitle>\n"
        "  <navMap>\n" + "\n".join(pts) + "\n  </navMap>\n</ncx>\n"
    )


# 1x1 PNG（自建资产，Apache-2.0）
PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
    "1f15c4890000000d4944415478da63fcffff3f0300070301ff9d07ded9"
    "0000000049454e44ae426082"
)


def specs():
    """与 src/epub/fixture.mbt::all_fixtures() 一一对应。"""
    two = [("ch1", "第一章"), ("ch2", "第二章")]
    five = [(f"c{i}", f"第{i}章") for i in range(1, 6)]
    thirty = [(f"c{i}", f"第{i}章") for i in range(1, 31)]
    base = dict(
        title="MoonRead 样例", creator="MOONBIT", lang="zh", chapters=two,
        epub3=True, with_nav=True, with_ncx=False, with_css=True, with_cover=False,
        broken_idref=False, rich_metadata=False, internal_entities=False,
        variant="",
    )
    out = []

    def add(name, **over):
        s = dict(base)
        s.update(over)
        out.append((name, s))

    add("epub3-basic")
    add("epub2-ncx", epub3=False, with_ncx=True, with_nav=False)
    add("zero-chapters", chapters=[])
    add("thirty-chapters", chapters=thirty)
    add("no-nav", with_nav=False)
    add("mimetype-last", with_nav=True)
    add("broken-idref", broken_idref=True)
    add("encrypted", with_nav=True)
    add("with-cover", with_cover=True)
    add("no-css", with_css=False)
    add("entity-title", title="带实体 &lt;标记&gt; 的书")
    add("five-both-toc", chapters=five, with_ncx=True)
    add("missing-creator-lang", creator="", lang="")
    add("no-container", with_nav=True)
    add("malformed-opf", with_nav=True)
    add("rich-metadata", title="Rich Metadata Sample", rich_metadata=True)
    add("internal-entities", title="内部实体书名：月亮与六便士", internal_entities=True)
    for variant in ("fallback", "svg", "nav-multivalue", "cover-legacy",
                    "package-lang", "multivalue-dc"):
        add("semantic-" + variant, variant=variant)
    return out


def write_epub(path: Path, name: str, s, *, omit_container=False, mimetype_last=False,
               malformed=False, encrypted=False):
    title = s["title"]
    chapters = s["chapters"]
    opf_body = (
        '<?xml version="1.0"?>\n<package version="3.0"\n<broken>'
        if malformed
        else opf(**{k: v for k, v in s.items() if k != "title"}, title=title)
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, "w") as z:
        if not mimetype_last:
            z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        if not omit_container:
            z.writestr("META-INF/container.xml", CONTAINER)
        if encrypted:
            z.writestr(
                "META-INF/encryption.xml",
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<encryption xmlns="https://www.w3.org/2001/04/xmlenc#"\n'
                '           xmlns:epub="http://www.idpf.org/2007/ops">\n'
                '  <EncryptedModule catalog="true" '
                'NameSpace="urn:oasis:names:tc:opendocument:xmlns:container">\n'
                '    <EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#rsa-oaep-mgf1p"/>\n'
                "  </EncryptedModule>\n</encryption>\n",
            )
        z.writestr("OEBPS/content.opf", opf_body)
        if s["with_nav"] and not malformed:
            z.writestr(
                "OEBPS/nav.xhtml",
                nav_xhtml(chapters, s.get("rich_metadata", False), s.get("variant", "")),
            )
        if s["with_ncx"] and not malformed:
            z.writestr("OEBPS/toc.ncx", ncx_xml(title, chapters))
        for cid, t in chapters:
            z.writestr(f"OEBPS/{cid}.xhtml", chapter_xhtml(t))
        if s["with_css"]:
            z.writestr("OEBPS/style.css", CSS)
        if s["with_cover"] or s.get("variant") == "cover-legacy":
            z.writestr("OEBPS/cover.png", PNG_1PX)
        if s.get("variant") == "cover-legacy":
            z.writestr("OEBPS/other.png", PNG_1PX)
        if s.get("variant") == "fallback":
            z.writestr("OEBPS/foreign.jpg", "JPEG-BYTES-PLACEHOLDER")
        if s.get("variant") == "svg":
            z.writestr("OEBPS/page.svg", '<svg xmlns="http://www.w3.org/2000/svg"/>')
        if mimetype_last:
            z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)


def expect_for(name, s):
    chapters = s["chapters"]
    # resources = OPF manifest 的 item 数：章节 + nav + NCX + CSS + 封面。
    # 旧实现把章节数误写成常量 1，导致 manifest 与内核实际值差 1..N。
    res = len(chapters)
    if s["with_nav"]:
        res += 1
    if s["with_ncx"]:
        res += 1
    if s["with_css"]:
        res += 1
    if s["with_cover"]:
        res += 1
    variant = s.get("variant", "")
    chapter_count = len(chapters)
    if variant in ("fallback", "svg"):
        res += 1
        chapter_count += 1
    if variant == "cover-legacy":
        res += 2
    toc = len(chapters) if s["with_nav"] or s["with_ncx"] else 0
    if name == "rich-metadata":
        # nav: 1 个 span 分组 + N 章 + 1 个 hidden 分支。
        toc = 1 + len(chapters) + 1
    broken = name == "malformed-opf"
    exp = {
        # 内核会解码 XML 实体；损坏 OPF 打不开，标题为空。
        "title": "" if broken else html.unescape(s["title"]),
        "chapters": 0 if broken or name == "zero-chapters" else chapter_count,
        "toc_items": 0 if broken else toc,
        "resources": 0 if broken else res,
    }
    if variant == "cover-legacy":
        exp["cover"] = "OEBPS/cover.png"
    if variant == "package-lang":
        exp["title_lang"] = "zh-Hant"
    if variant == "multivalue-dc":
        exp["publishers"] = ["P1", "P2"]
    return exp


def main() -> int:
    manifest_only = "--manifest-only" in sys.argv[1:]
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {
        "$schema": "https://moonread.dev/schema/fixtures-manifest.json",
        "version": 1,
        "license": "Apache-2.0",
        "source": "本仓库自建（tools/gen_fixtures.py 与 src/epub/fixture.mbt）",
        "note": "期望值必须与 src/epub/fixture.mbt::all_fixtures() 一致；不一致即为缺陷。",
        "books": [],
    }
    for name, s in specs():
        p = OUT / f"{name}.epub"
        if not manifest_only:
            write_epub(
                p,
                name,
                s,
                omit_container=(name == "no-container"),
                mimetype_last=(name == "mimetype-last"),
                malformed=(name == "malformed-opf"),
                encrypted=(name == "encrypted"),
            )
        manifest["books"].append(
            {
                "file": f"epub/{name}.epub",
                "name": name,
                "license": "Apache-2.0",
                "source": "self-generated",
                "expect": expect_for(name, s),
            }
        )
    (OUT.parent / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"生成 {len(manifest['books'])} 本 fixture -> {OUT}")
    print("写 manifest -> tests/fixtures/manifest.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
