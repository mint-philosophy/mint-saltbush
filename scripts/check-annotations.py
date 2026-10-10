"""Print each annotation as MuPDF sees it, with the text under its quads.

Usage: python3 check-annotations.py <file.pdf>
Used to confirm that highlights written by Folio render in other engines.
"""
import sys

import pymupdf

doc = pymupdf.open(sys.argv[1])
for page in doc:
    for annot in page.annots():
        kind = annot.type[1]
        text = ""
        if annot.vertices:
            quads = [pymupdf.Quad(annot.vertices[i:i + 4]) for i in range(0, len(annot.vertices), 4)]
            bands = [pymupdf.Rect(q.rect.x0, q.rect.y0 + q.rect.height * 0.2, q.rect.x1, q.rect.y1 - q.rect.height * 0.2)
                     for q in quads]
            text = " ".join(page.get_textbox(r).strip() for r in bands)
        print(f"page {page.number + 1} {kind} note={annot.info.get('content') or '-'} colour={annot.colors.get('stroke')}")
        if text:
            print("   text:", " ".join(text.split())[:90] + "…")
