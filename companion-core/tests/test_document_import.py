from __future__ import annotations

import io
import json
import unittest
import zipfile

from pypdf import PdfWriter

from spring_haven_core.document_import import (
    DocumentImportError,
    extract_document,
    extract_web_document,
)


class DocumentImportTests(unittest.TestCase):
    def test_text_decoding_supports_utf8_and_utf16(self):
        utf8 = extract_document("小玲.md", "薄荷需要散射光。".encode("utf-8"))
        utf16 = extract_document("小奈.txt", "餐垫在右边抽屉。".encode("utf-16"))
        self.assertEqual(utf8["text"], "薄荷需要散射光。")
        self.assertEqual(utf16["text"], "餐垫在右边抽屉。")

    def test_html_discards_non_visible_content_and_keeps_title(self):
        source = b"""
            <html><head><title>Plant Notes</title><style>.x{display:none}</style></head>
            <body><h1>Mint</h1><script>secret()</script><p>Keep the soil moist.</p></body></html>
        """
        result = extract_web_document(
            "https://example.test/plants", "text/html; charset=utf-8", source
        )
        self.assertEqual(result["title"], "Plant Notes")
        self.assertIn("Keep the soil moist.", result["text"])
        self.assertNotIn("secret", result["text"])
        self.assertNotIn("display:none", result["text"])

    def test_json_and_json_lines_are_normalized(self):
        value = extract_document(
            "facts.json", json.dumps({"角色": "小玲"}, ensure_ascii=False).encode()
        )
        lines = extract_document(
            "facts.jsonl", b'{"name":"ling"}\nnot-json\n{"name":"nai"}'
        )
        self.assertIn('"角色": "小玲"', value["text"])
        self.assertIn("not-json", lines["text"])
        self.assertEqual(lines["text"].count("name"), 2)

    def test_docx_is_extracted_without_office_dependency(self):
        document_xml = """<?xml version="1.0" encoding="UTF-8"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body><w:p><w:r><w:t>第一段</w:t></w:r></w:p>
          <w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body>
        </w:document>""".encode("utf-8")
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("word/document.xml", document_xml)
        result = extract_document("设定.docx", buffer.getvalue())
        self.assertEqual(result["text"], "第一段\n第二段")

    def test_pdf_without_extractable_text_is_rejected_cleanly(self):
        buffer = io.BytesIO()
        writer = PdfWriter()
        writer.add_blank_page(width=100, height=100)
        writer.write(buffer)
        with self.assertRaisesRegex(DocumentImportError, "no extractable text"):
            extract_document("scan.pdf", buffer.getvalue())

    def test_invalid_type_empty_and_oversized_documents_are_rejected(self):
        with self.assertRaisesRegex(DocumentImportError, "unsupported"):
            extract_document("archive.exe", b"content")
        with self.assertRaisesRegex(DocumentImportError, "must contain"):
            extract_document("empty.txt", b"")
        with self.assertRaisesRegex(DocumentImportError, "must contain"):
            extract_document("large.txt", b"x" * 20_000_001)


if __name__ == "__main__":
    unittest.main()
