#!/usr/bin/env python3
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED, ZIP_DEFLATED
p = Path(__file__).resolve().parents[1]/'Tests/Fixtures'
p.mkdir(exist_ok=True)
chapter = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>正文</title></head><body>
<h1>测试章节</h1><p>中文阅读位置：你好，世界。</p><p>Before  <em>nested</em>  after\n text.</p><p>Unicode 😀 𝄞 café。</p>
<pre>one  two\nthree</pre>%s</body></html>'''
with ZipFile(p/'sample.epub','w') as z:
    z.writestr('mimetype','application/epub+zip',compress_type=ZIP_STORED)
    z.writestr('META-INF/container.xml','''<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>''',compress_type=ZIP_DEFLATED)
    z.writestr('EPUB/package.opf','''<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">simple-reader-fixture</dc:identifier><dc:title>同步测试图书</dc:title><dc:creator>Simple Reader</dc:creator><dc:language>zh</dc:language><meta property="dcterms:modified">2026-10-06T00:00:00Z</meta></metadata><manifest><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/><item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>''',compress_type=ZIP_DEFLATED)
    for i in [1,2]:
        text = chapter % ''.join(f'<p>第{i}章第{n}段。这是一段用于翻页、改变字号和恢复阅读位置的测试正文。Reading across pages should persist the visible text position.</p>' for n in range(80))
        z.writestr(f'EPUB/chapter{i}.xhtml',text,compress_type=ZIP_DEFLATED)
        (p/f'chapter{i}.xhtml').write_text(text)
    z.writestr('EPUB/nav.xhtml','''<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">第一章</a></li><li><a href="chapter2.xhtml">第二章</a></li></ol></nav></body></html>''',compress_type=ZIP_DEFLATED)
(p/'catalog.xml').write_text('''<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom" xml:base="/opds/"><title>Calibre</title><link rel="next" href="?page=2"/><link rel="search" href="search?q={searchTerms}" type="application/atom+xml"/><entry><id>book-1</id><title>中文 EPUB</title><author><name>作者一</name></author><author><name>作者二</name></author><link rel="http://opds-spec.org/acquisition" href="../books/sample.epub" type="application/epub+zip"/><link rel="http://opds-spec.org/image/thumbnail" href="cover/1.jpg"/></entry><entry><id>category</id><title>作者</title><link href="authors" type="application/atom+xml;profile=opds-catalog"/></entry></feed>''')
print('Generated redistributable fixtures')
