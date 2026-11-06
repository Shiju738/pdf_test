# Makes a book-like PDF for test/jump_benchmark_test.dart:
#   python3 tool/make_bench_pdf.py /tmp/book.pdf 100
# A book-like PDF: N pages, each with text and a noisy image (so it's big and
# doesn't compress), objects laid out page by page like most exporters do.
import os, random, sys, zlib
N = int(sys.argv[2]) if len(sys.argv) > 2 else 40
# "balanced": a page tree of 10 pages per node, with the tree's nodes written
# at the end of the file (as pdfTeX does). Default "flat": one /Kids array.
TREE = sys.argv[3] if len(sys.argv) > 3 else "flat"
random.seed(1)
objs = {}
def add(n, body): objs[n] = body
# 1 catalog, 2 pages, 3 font; then per page: page, content, image
kids = []
for i in range(N):
    p, c, im = 4 + i*3, 5 + i*3, 6 + i*3
    kids.append(p)
    w = h = 130
    raw = os.urandom(w*h*3)  # ~97 KB of incompressible bytes
    data = zlib.compress(raw, 1)
    add(im, b"<< /Type /XObject /Subtype /Image /Width %d /Height %d /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length %d >>\nstream\n" % (w, h, len(data)) + data + b"\nendstream")
    text = b"".join(b"BT /F1 11 Tf 50 %d Td (Page %d line %d of a long book with words) Tj ET\n" % (760 - 14*k, i+1, k) for k in range(40))
    content = text + b"q 300 0 0 300 150 100 cm /Im0 Do Q\n"
    add(c, b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
    parent = 2 if TREE == "flat" else 10000 + i // 10
    add(p, b"<< /Type /Page /Parent %d 0 R" % parent + b" /MediaBox [0 0 612 792] /Contents %d 0 R /Resources << /Font << /F1 3 0 R >> /XObject << /Im0 %d 0 R >> >> >>" % (c, im))
add(1, b"<< /Type /Catalog /Pages 2 0 R >>")
if TREE == "flat":
    add(2, b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % k for k in kids) + b"] /Count %d >>" % N)
else:
    nodes = []
    for g in range(0, N, 10):
        node = 10000 + g // 10
        nodes.append(node)
        group = kids[g:g + 10]
        add(node, b"<< /Type /Pages /Parent 2 0 R /Kids [" + b" ".join(b"%d 0 R" % k for k in group) + b"] /Count %d >>" % len(group))
    add(2, b"<< /Type /Pages /Kids [" + b" ".join(b"%d 0 R" % k for k in nodes) + b"] /Count %d >>" % N)
add(3, b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
for n in sorted(objs, key=lambda n: (n > 3, n >= 10000, n)):
    offsets[n] = len(out)
    out += b"%d 0 obj\n" % n + objs[n] + b"\nendobj\n"
xref = len(out)
size = max(objs) + 1
out += b"xref\n0 %d\n0000000000 65535 f \n" % size
for n in range(1, size):
    out += (b"%010d 00000 n \n" % offsets[n]) if n in offsets else b"0000000000 65535 f \n"
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (size, xref)
open(sys.argv[1], "wb").write(out)
print(len(out), "bytes,", N, "pages")
