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
        with_cover, broken_idref):
    ver = "3.0" if epub3 else "2.0"
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<package xmlns="http://www.idpf.org/2007/opf" version="{ver}" unique-identifier="uid">',
        '  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">',
        '    <dc:identifier id="uid">urn:uuid:moonread-sample</dc:identifier>',
        f"    <dc:title>{title}</dc:title>",
        f"    <dc:creator>{creator}</dc:creator>",
        f"    <dc:language>{lang}</dc:language>",
    ]
    if epub3:
        lines.append('    <meta property="dcterms:modified">2026-11-19T00:00:00Z</meta>')
    if with_cover:
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
    if with_cover:
        lines.append(
            '    <item id="cover-img" href="cover.png" media-type="image/png" properties="cover-image"/>'
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
    if broken_idref:
        lines.append('    <itemref idref="ghost"/>')
    lines += ["  </spine>", "</package>"]
    return "\n".join(lines) + "\n"


def nav_xhtml(chapters):
    items = "\n".join(f'<li><a href="{c}.xhtml">{t}</a></li>' for c, t in chapters)
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\n'
        "<head><title>目录</title></head>\n<body>\n"
        '<nav epub:type="toc" id="toc">\n<h1>目录</h1>\n<ol>\n'
        + items
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
        broken_idref=False,
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
            z.writestr("OEBPS/nav.xhtml", nav_xhtml(chapters))
        if s["with_ncx"] and not malformed:
            z.writestr("OEBPS/toc.ncx", ncx_xml(title, chapters))
        for cid, t in chapters:
            z.writestr(f"OEBPS/{cid}.xhtml", chapter_xhtml(t))
        if s["with_css"]:
            z.writestr("OEBPS/style.css", CSS)
        if s["with_cover"]:
            z.writestr("OEBPS/cover.png", PNG_1PX)
        if mimetype_last:
            z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)


def expect_for(name, s):
    chapters = s["chapters"]
    res = 1
    if s["with_nav"]:
        res += 1
    if s["with_ncx"]:
        res += 1
    if s["with_css"]:
        res += 1
    if s["with_cover"]:
        res += 1
    toc = len(chapters) if s["with_nav"] or s["with_ncx"] else 0
    return {
        "title": "" if name == "entity-title" else s["title"],
        "chapters": 0 if name in ("malformed-opf", "zero-chapters") else len(chapters),
        "toc_items": 0 if name == "malformed-opf" else toc,
        "resources": 0 if name == "malformed-opf" else res,
    }


def main() -> int:
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
