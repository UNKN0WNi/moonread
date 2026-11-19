#!/usr/bin/env python3
"""把本地 EPUB 渲染成一个单文件、可翻章的 HTML 阅读器。

这是一个**独立示范工具**：只用 Python 标准库（zipfile / xml.etree / re / json / html），
不依赖 moon 工具链，也不调用 MoonBit 内核。它演示的是「EPUB 的 OPF/NCX 结构如何
变成可阅读的章节」，方便你在浏览器里直观看到一本书的解析结果。

如果要验证 MoonBit 内核本身，请用 apps/epub-cli（见 README）。

用法：
    python3 tools/render_html.py <book.epub> [-o out.html]

不传 -o 时，输出文件写在 EPUB 同目录，文件名沿用书名并加 .html 后缀。
退出码 0 表示成功；解析失败会打印错误并以非 0 退出。
"""

from __future__ import annotations

import argparse
import html as htmlmod
import json
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {"opf": "http://www.idpf.org/2007/opf", "dc": "http://purl.org/dc/elements/1.1/"}
NCXNS = {"ncx": "http://www.daisy.org/z3986/2005/ncx/"}


def parse_epub(epub_path: Path):
    """解析 EPUB，返回 (title, author, chapters, toc, total_chars)。"""
    with zipfile.ZipFile(epub_path) as z:
        names = set(z.namelist())

        # ---- OPF：书名、作者、spine 阅读顺序 ----
        opf_name = next((n for n in z.namelist() if n.endswith(".opf")), None)
        if opf_name is None:
            raise ValueError("EPUB 中没有 .opf 文件")
        base = opf_name.rsplit("/", 1)[0] if "/" in opf_name else ""

        def resolve(href):
            if not href:
                return href
            clean = href.split("#")[0]
            return (base + "/" + clean) if base else clean

        root = ET.fromstring(z.read(opf_name).decode("utf-8", errors="replace"))
        manifest = {
            it.get("id"): it.get("href")
            for it in root.findall(".//opf:manifest/opf:item", NS)
        }
        spine_ids = [it.get("idref") for it in root.findall(".//opf:spine/opf:itemref", NS)]
        spine_hrefs = [resolve(manifest[i]) for i in spine_ids if i in manifest]
        title = root.findtext(".//dc:title", default="（无标题）", namespaces=NS).strip()
        author = root.findtext(".//dc:creator", default="", namespaces=NS).strip()

        # ---- NCX：目录（层级 + 锚点）----
        toc = []
        ncx_name = next((n for n in z.namelist() if n.endswith(".ncx")), None)
        if ncx_name:
            nbase = ncx_name.rsplit("/", 1)[0] if "/" in ncx_name else ""

            def nresolve(src):
                clean = src.split("#")[0]
                return (nbase + "/" + clean) if nbase else clean

            nroot = ET.fromstring(z.read(ncx_name).decode("utf-8", errors="replace"))
            navmap = nroot.find("ncx:navMap", NCXNS)

            def walk(np, level):
                lbl = np.findtext("ncx:navLabel/ncx:text", default="", namespaces=NCXNS).strip()
                c = np.find("ncx:content", NCXNS)
                src = c.get("src") if c is not None else ""
                toc.append({"level": level, "title": lbl, "href": nresolve(src)})
                for ch in np.findall("ncx:navPoint", NCXNS):
                    walk(ch, level + 1)

            if navmap is not None:
                for np in navmap.findall("ncx:navPoint", NCXNS):
                    walk(np, 0)

        href_to_idx = {h: i for i, h in enumerate(spine_hrefs)}
        for t in toc:
            t["idx"] = href_to_idx.get(t["href"], None)

        # ---- 正文提取：去脚本/样式，取标题与段落 ----
        def clean_text(frag):
            frag = re.sub(r"(?is)<br\s*/?>", "", frag)
            frag = re.sub(r"(?s)<[^>]+>", "", frag)
            frag = htmlmod.unescape(frag)
            frag = frag.replace("\xa0", " ")
            return re.sub(r"[ \t]+", " ", frag).strip()

        def extract(xhtml):
            s = re.sub(r"(?is)<head.*?</head>", "", xhtml)
            s = re.sub(r"(?is)<script.*?</script>", "", s)
            s = re.sub(r"(?is)<style.*?</style>", "", s)
            m = re.search(r"(?is)<body[^>]*>(.*)</body>", s)
            body = m.group(1) if m else s
            ch_title = ""
            hm = re.search(r"(?is)<h[1-3][^>]*>(.*?)</h[1-3]>", body)
            if hm:
                ch_title = clean_text(hm.group(1))
                body = body[: hm.start()] + body[hm.end() :]
            paras = []
            for pm in re.finditer(r"(?is)<p[^>]*>(.*?)</p>", body):
                t = clean_text(pm.group(1))
                if t:
                    paras.append(t)
            if not paras:
                paras = [p for p in re.split(r"\n{2,}", clean_text(body)) if p]
            return ch_title, paras

        chapters = []
        total_chars = 0
        for i, h in enumerate(spine_hrefs):
            if h not in names:
                chapters.append({"title": "第 %d 章" % (i + 1), "paras": []})
                continue
            x = z.read(h).decode("utf-8", errors="replace")
            ch_title, paras = extract(x)
            if not ch_title:
                ch_title = next(
                    (t["title"] for t in toc if t["href"] == h and t["title"]),
                    "第 %d 章" % (i + 1),
                )
            total_chars += sum(len(p) for p in paras)
            chapters.append({"title": ch_title, "paras": paras})

    # 用目录标题补齐泛化/空的章节标题
    toc_title_by_idx = {}
    for t in toc:
        if t.get("idx") is not None and t["title"]:
            toc_title_by_idx.setdefault(t["idx"], t["title"])
    for i, c in enumerate(chapters):
        if (not c["title"] or re.match(r"^第 \d+ 章$", c["title"])) and i in toc_title_by_idx:
            c["title"] = toc_title_by_idx[i]

    return title, author, chapters, toc, total_chars


def jdump(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).replace("</", "<\\/")


HTML_TEMPLATE = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>__TITLE__</title>
<style>
:root{
  --bg:#f4f1ea; --paper:#fffdf8; --ink:#2b2620; --muted:#8a8175;
  --line:#e6dfd2; --accent:#8a5a2b; --shadow:0 2px 16px rgba(60,45,25,.08);
}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{
  font-family:"Noto Serif SC","Songti SC","SimSun",Georgia,serif;
  background:var(--bg); color:var(--ink);
  display:flex; flex-direction:column; overflow:hidden;
}
#bar{
  flex:0 0 auto; display:flex; align-items:center; gap:14px;
  padding:10px 18px; background:var(--paper); border-bottom:1px solid var(--line);
  box-shadow:var(--shadow); z-index:5;
}
#bar .btn{
  border:1px solid var(--line); background:#fff; color:var(--ink);
  border-radius:8px; padding:6px 12px; cursor:pointer; font-size:13px;
  font-family:inherit; white-space:nowrap;
}
#bar .btn:hover{border-color:var(--accent); color:var(--accent)}
#bar .btn:disabled{opacity:.4; cursor:not-allowed}
#bar .spacer{flex:1}
#meta{text-align:center; min-width:0}
#meta .t{font-size:14px; font-weight:600; max-width:46vw; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; margin:0 auto}
#meta .a{font-size:11px; color:var(--muted); margin-top:2px}
#main{flex:1; display:flex; min-height:0}
#side{
  width:290px; flex:0 0 290px; background:var(--paper); border-right:1px solid var(--line);
  overflow-y:auto; padding:14px 8px 40px; transition:margin-left .2s;
}
#side.hide{margin-left:-290px}
#side h3{font-size:12px; color:var(--muted); letter-spacing:2px; margin:8px 12px 12px; font-weight:600}
.toc-item{
  display:block; width:100%; text-align:left; border:0; background:none; cursor:pointer;
  font-family:inherit; font-size:13px; line-height:1.5; color:var(--ink);
  padding:6px 12px; border-radius:6px;
}
.toc-item:hover{background:#f0e9db}
.toc-item.active{background:var(--accent); color:#fff}
.toc-item.lv1{padding-left:26px; color:#555; font-size:12px}
.toc-item.lv2{padding-left:40px; color:#777; font-size:12px}
#read{flex:1; overflow-y:auto; position:relative}
#page{
  max-width:760px; margin:0 auto; padding:48px 56px 120px;
  font-size:18px; line-height:2.0; letter-spacing:.02em;
}
#page h2{
  font-size:26px; line-height:1.5; text-align:center; margin:0 0 44px;
  font-weight:600; letter-spacing:.08em;
}
#page p{margin:0 0 1.05em; text-indent:2em; text-align:justify}
#page p.first{text-indent:0}
#nav{
  flex:0 0 auto; display:flex; align-items:center; justify-content:center; gap:18px;
  padding:10px; background:var(--paper); border-top:1px solid var(--line);
}
#nav .pos{font-size:12px; color:var(--muted); min-width:120px; text-align:center}
body.night{--bg:#1b1a18; --paper:#24221f; --ink:#d8d2c6; --muted:#8f887c; --line:#3a3731; --accent:#c99a5b}
body.night #bar .btn{background:#2c2925}
body.night .toc-item:hover{background:#33302a}
body.night #page{color:var(--ink)}
@media(max-width:820px){
  #side{position:absolute; z-index:4; height:100%}
  #page{padding:28px 22px 90px; font-size:17px}
  #meta .t{max-width:40vw}
}
</style>
</head>
<body>
<div id="bar">
  <button class="btn" id="tocBtn">目录</button>
  <div id="meta"><div class="t">__TITLE__</div><div class="a">__AUTHOR__</div></div>
  <div class="spacer"></div>
  <button class="btn" id="smaller">A−</button>
  <button class="btn" id="bigger">A＋</button>
  <button class="btn" id="night">夜间</button>
</div>
<div id="main">
  <aside id="side"><h3>目 录</h3><div id="tocList"></div></aside>
  <div id="read"><article id="page"></article></div>
</div>
<div id="nav">
  <button class="btn" id="prev">← 上一章</button>
  <span class="pos" id="pos"></span>
  <button class="btn" id="next">下一章 →</button>
</div>
<script>
var chapters = __CHAPTERS__;
var toc = __TOC__;
var idx = 0;
var read = document.getElementById('read');
var page = document.getElementById('page');
function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function render(){
  var c = chapters[idx];
  var html = '<h2>' + esc(c.title) + '</h2>';
  for (var i=0;i<c.paras.length;i++){
    html += '<p' + (i===0?' class="first"':'') + '>' + esc(c.paras[i]) + '</p>';
  }
  page.innerHTML = html;
  read.scrollTop = 0;
  document.getElementById('pos').textContent = (idx+1) + ' / ' + chapters.length + ' 章';
  document.getElementById('prev').disabled = idx<=0;
  document.getElementById('next').disabled = idx>=chapters.length-1;
  var nodes = document.querySelectorAll('.toc-item');
  for (var j=0;j<nodes.length;j++){
    nodes[j].classList.toggle('active', Number(nodes[j].dataset.idx)===idx);
  }
}
function goto(i){ if(i>=0 && i<chapters.length){ idx=i; render(); } }
function buildToc(){
  var box = document.getElementById('tocList');
  for (var i=0;i<toc.length;i++){
    var t = toc[i];
    if (t.idx===null || t.idx===undefined) continue;
    var b = document.createElement('button');
    b.className = 'toc-item' + (t.level>0?(' lv'+Math.min(t.level,2)):'');
    b.textContent = t.title || ('第 '+(t.idx+1)+' 章');
    b.dataset.idx = t.idx;
    b.onclick = (function(k){ return function(){ goto(k); }; })(t.idx);
    box.appendChild(b);
  }
}
document.getElementById('prev').onclick = function(){ goto(idx-1); };
document.getElementById('next').onclick = function(){ goto(idx+1); };
document.getElementById('tocBtn').onclick = function(){ document.getElementById('side').classList.toggle('hide'); };
document.getElementById('smaller').onclick = function(){
  var s = parseFloat(getComputedStyle(page).fontSize); if(s>14) page.style.fontSize=(s-2)+'px';
};
document.getElementById('bigger').onclick = function(){
  var s = parseFloat(getComputedStyle(page).fontSize); if(s<28) page.style.fontSize=(s+2)+'px';
};
document.getElementById('night').onclick = function(){ document.body.classList.toggle('night'); };
document.addEventListener('keydown', function(e){
  if(e.key==='ArrowLeft') goto(idx-1);
  if(e.key==='ArrowRight') goto(idx+1);
});
buildToc();
render();
</script>
</body>
</html>
'''


def render(epub_path: Path, out_path: Path) -> dict:
    title, author, chapters, toc, total_chars = parse_epub(epub_path)
    doc = (
        HTML_TEMPLATE.replace("__TITLE__", htmlmod.escape(title))
        .replace("__AUTHOR__", htmlmod.escape(author))
        .replace("__CHAPTERS__", jdump(chapters))
        .replace("__TOC__", jdump(toc))
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(doc, encoding="utf-8")
    return {
        "out": str(out_path),
        "bytes": out_path.stat().st_size,
        "chapters": len(chapters),
        "toc_items": len(toc),
        "body_chars": total_chars,
        "title": title,
        "author": author,
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="把本地 EPUB 渲染成单文件、可翻章的 HTML 阅读器（纯 Python 标准库）。"
    )
    parser.add_argument("epub", type=Path, help="输入 .epub 文件路径")
    parser.add_argument("-o", "--output", type=Path, help="输出 .html 路径；默认与 EPUB 同名同目录")
    args = parser.parse_args(argv)

    if not args.epub.is_file():
        print("错误：找不到 EPUB 文件：%s" % args.epub, file=sys.stderr)
        return 2
    out = args.output or args.epub.with_suffix(".html")

    try:
        info = render(args.epub, out)
    except (zipfile.BadZipFile, ValueError, ET.ParseError) as exc:
        print("错误：解析 EPUB 失败：%s" % exc, file=sys.stderr)
        return 3

    print("输出：%s" % info["out"])
    print("大小：%.2f MB" % (info["bytes"] / 1024 / 1024))
    print("书名：%s" % info["title"])
    print("作者：%s" % info["author"])
    print("章节：%d，目录项：%d，正文约 %d 字" % (
        info["chapters"], info["toc_items"], info["body_chars"]
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
