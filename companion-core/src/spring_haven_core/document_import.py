from __future__ import annotations

import io
import json
import re
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from typing import Any
from xml.etree import ElementTree


SUPPORTED_DOCUMENT_EXTENSIONS = {
    ".txt",
    ".md",
    ".markdown",
    ".json",
    ".jsonl",
    ".csv",
    ".tsv",
    ".html",
    ".htm",
    ".docx",
    ".pdf",
}


class DocumentImportError(ValueError):
    """An uploaded knowledge document could not be safely converted to text."""


def extract_document(filename: str, content: bytes) -> dict[str, Any]:
    safe_name = Path(str(filename)).name
    extension = Path(safe_name).suffix.lower()
    if extension not in SUPPORTED_DOCUMENT_EXTENSIONS:
        raise DocumentImportError(f"unsupported document type: {extension or 'unknown'}")
    if not content or len(content) > 20_000_000:
        raise DocumentImportError("document must contain 1-20000000 bytes")

    if extension == ".pdf":
        text = _extract_pdf(content)
    elif extension == ".docx":
        text = _extract_docx(content)
    else:
        decoded = _decode_text(content)
        if extension in {".html", ".htm"}:
            text = _extract_html(decoded)
        elif extension == ".json":
            text = _format_json(decoded)
        elif extension == ".jsonl":
            text = _format_json_lines(decoded)
        else:
            text = decoded

    normalized = _normalize_text(text)
    if not normalized:
        raise DocumentImportError("document contains no extractable text")
    if len(normalized) > 1_000_000:
        raise DocumentImportError("extracted document exceeds 1000000 characters")
    return {
        "filename": safe_name,
        "title": Path(safe_name).stem[:200] or "Imported document",
        "text": normalized,
        "extension": extension,
        "character_count": len(normalized),
    }


def extract_web_document(url: str, content_type: str, content: bytes) -> dict[str, Any]:
    lowered = str(content_type).lower()
    extension = ".html" if "html" in lowered else ".json" if "json" in lowered else ".txt"
    result = extract_document("web-import" + extension, content)
    if extension == ".html":
        title = _html_title(_decode_text(content))
        if title:
            result["title"] = title[:200]
    result["source_uri"] = str(url)[:2_048]
    return result


def _decode_text(content: bytes) -> str:
    for encoding in ("utf-8-sig", "utf-16", "gb18030"):
        try:
            return content.decode(encoding)
        except UnicodeDecodeError:
            continue
    return content.decode("utf-8", errors="replace")


def _extract_pdf(content: bytes) -> str:
    try:
        from pypdf import PdfReader
    except ImportError as exc:
        raise DocumentImportError(
            "PDF support requires the pypdf dependency"
        ) from exc
    try:
        reader = PdfReader(io.BytesIO(content), strict=False)
        if reader.is_encrypted:
            try:
                reader.decrypt("")
            except Exception as exc:
                raise DocumentImportError("encrypted PDF is not supported") from exc
        return "\n\n".join((page.extract_text() or "").strip() for page in reader.pages)
    except DocumentImportError:
        raise
    except Exception as exc:
        raise DocumentImportError("PDF text extraction failed") from exc


def _extract_docx(content: bytes) -> str:
    try:
        with zipfile.ZipFile(io.BytesIO(content)) as archive:
            xml = archive.read("word/document.xml")
    except (KeyError, OSError, zipfile.BadZipFile) as exc:
        raise DocumentImportError("DOCX file is invalid") from exc
    try:
        root = ElementTree.fromstring(xml)
    except ElementTree.ParseError as exc:
        raise DocumentImportError("DOCX document XML is invalid") from exc
    namespace = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    paragraphs: list[str] = []
    for paragraph in root.iter(namespace + "p"):
        parts = [node.text or "" for node in paragraph.iter(namespace + "t")]
        line = "".join(parts).strip()
        if line:
            paragraphs.append(line)
    return "\n".join(paragraphs)


class _VisibleHtmlParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.title_parts: list[str] = []
        self._ignored_depth = 0
        self._in_title = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        lowered = tag.lower()
        if lowered in {"script", "style", "noscript", "svg"}:
            self._ignored_depth += 1
        if lowered == "title":
            self._in_title = True
        if lowered in {"p", "div", "section", "article", "br", "li", "tr", "h1", "h2", "h3"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        lowered = tag.lower()
        if lowered in {"script", "style", "noscript", "svg"} and self._ignored_depth:
            self._ignored_depth -= 1
        if lowered == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._ignored_depth:
            return
        cleaned = data.strip()
        if not cleaned:
            return
        self.parts.append(cleaned + " ")
        if self._in_title:
            self.title_parts.append(cleaned)


def _extract_html(value: str) -> str:
    parser = _VisibleHtmlParser()
    parser.feed(value)
    return "".join(parser.parts)


def _html_title(value: str) -> str:
    parser = _VisibleHtmlParser()
    parser.feed(value)
    return " ".join(parser.title_parts).strip()


def _format_json(value: str) -> str:
    try:
        parsed = json.loads(value)
    except ValueError:
        return value
    return json.dumps(parsed, ensure_ascii=False, indent=2)


def _format_json_lines(value: str) -> str:
    lines: list[str] = []
    for raw_line in value.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        try:
            lines.append(json.dumps(json.loads(line), ensure_ascii=False))
        except ValueError:
            lines.append(line)
    return "\n".join(lines)


def _normalize_text(value: str) -> str:
    normalized = str(value).replace("\x00", " ").replace("\r\n", "\n").replace("\r", "\n")
    normalized = re.sub(r"[ \t]+", " ", normalized)
    normalized = re.sub(r"\n[ \t]+", "\n", normalized)
    normalized = re.sub(r"\n{3,}", "\n\n", normalized)
    return normalized.strip()
