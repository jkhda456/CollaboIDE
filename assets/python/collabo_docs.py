#!/usr/bin/env python3
"""Collabo IDE - document tool module (fixed base module).

Reads and edits the well-known office document formats through the same tool
contract as `collabo_tools.py`:

  describe:
    python collabo_docs.py describe
      -> stdout(JSON): {"module","version","tools":[<OpenAI tool schema>...]}
  call:
    python collabo_docs.py call <tool_name>
      <- stdin(JSON): tool arguments (object)
      -> stdout(JSON): {"ok":true,"result":...} | {"ok":false,"error":"..."}

Environment:
  COLLABO_WORKSPACE : workspace root. When set, access outside it is blocked.

Design notes
------------
* **Standard library only** (zipfile + xml.etree). No pip install is required,
  so the tools work with any interpreter the user picked. python-docx/openpyxl
  would be nicer but cannot be assumed to exist.
* OOXML (docx/xlsx/pptx) and ODF (odt/ods/odp) are ZIP containers holding XML.
  Editing is **surgical**: only the XML part that actually changes is rewritten
  and every other zip entry is copied through byte-for-byte. That keeps styles,
  images, macros and anything this module does not understand intact.
* Replacing the text of a paragraph/cell/shape **collapses the runs inside it**
  (mixed bold/italic within that one paragraph becomes uniform). Formatting of
  every other paragraph is untouched. This is the honest trade-off of editing
  without a full word-processing engine, and it is documented in each tool.
* ODF is currently read-only.
"""

import copy
import difflib
import json
import os
import re
import shutil
import sys
import tempfile
import zipfile
import xml.etree.ElementTree as ET

MODULE_NAME = "collabo_docs"
MODULE_VERSION = "0.1.0"

WORKSPACE = os.environ.get("COLLABO_WORKSPACE") or ""

# Guards. Office files are zips; a malicious or broken one should not hang us.
MAX_FILE_BYTES = 64 << 20      # 64MB container
MAX_PART_BYTES = 32 << 20      # 32MB for a single XML part
MAX_TEXT_CHARS = 200_000       # text returned to the LLM in one call
MAX_ROWS = 2000                # spreadsheet rows per sheet
MAX_COLS = 200                 # spreadsheet columns per row

# --- namespaces -------------------------------------------------------------

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
A = "http://schemas.openxmlformats.org/drawingml/2006/main"
S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
PML = "http://schemas.openxmlformats.org/presentationml/2006/main"
PKG_REL = "http://schemas.openxmlformats.org/package/2006/relationships"
OFF_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
CP = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
DC = "http://purl.org/dc/elements/1.1/"
ODF_TEXT = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
ODF_TABLE = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"

# Keep the conventional prefixes when a part is written back out. Without this
# ElementTree renames them to ns0/ns1 — still valid XML, but a needlessly huge
# diff for anyone inspecting the file afterwards, and further from what Word /
# Excel / PowerPoint themselves write.
#
# Spreadsheet parts use the namespace **without a prefix** (`<worksheet xmlns=…>`),
# which is what Excel emits — so it is registered as the default (empty prefix).
for _prefix, _uri in (
    ("w", W), ("a", A), ("p", PML), ("", S), ("r", OFF_REL),
    ("cp", CP), ("dc", DC), ("text", ODF_TEXT), ("table", ODF_TABLE),
):
    try:
        ET.register_namespace(_prefix, _uri)
    except Exception:  # pragma: no cover - registration never fails in practice
        pass

XML_DECL = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'


class ToolError(Exception):
    """An error to return to the user/LLM as a failed tool result."""


_TOOLS = {}


def tool(name, description, parameters):
    """Register a tool. `parameters` is a JSON Schema (object)."""

    def deco(func):
        _TOOLS[name] = {
            "schema": {
                "type": "function",
                "function": {
                    "name": name,
                    "description": description,
                    "parameters": parameters,
                },
            },
            "func": func,
        }
        return func

    return deco


# --- path safety (same rules as the base module) ----------------------------

def _resolve(path):
    """Resolve to a real absolute path and confine it to the workspace.

    Fails safe: with no workspace set, every file operation is blocked.
    """
    if not path or not isinstance(path, str):
        raise ToolError("'path' is required.")
    target = os.path.realpath(os.path.abspath(os.path.expanduser(path)))
    if not WORKSPACE:
        raise ToolError("No workspace is set; file operations are blocked.")
    root = os.path.realpath(os.path.abspath(WORKSPACE))
    nroot = os.path.normcase(root)
    ntarget = os.path.normcase(target)
    try:
        common = os.path.commonpath([nroot, ntarget])
    except ValueError:
        common = ""  # e.g. different drives on Windows
    if common != nroot:
        raise ToolError("Path is outside the workspace: %s" % path)
    return target


def _diff(before, after, path):
    """Unified diff of the extracted text (what the user can actually see)."""
    lines = list(
        difflib.unified_diff(
            before.splitlines(keepends=True),
            after.splitlines(keepends=True),
            fromfile=path,
            tofile=path,
            n=2,
        )
    )
    out = "".join(lines)
    return out[:20000] + "\n… (diff truncated)" if len(out) > 20000 else out


# --- container helpers ------------------------------------------------------

FORMATS = {
    ".docx": "docx", ".docm": "docx",
    ".xlsx": "xlsx", ".xlsm": "xlsx",
    ".pptx": "pptx", ".pptm": "pptx",
    ".odt": "odt", ".ods": "ods", ".odp": "odp",
}


def _format_of(path):
    fmt = FORMATS.get(os.path.splitext(path)[1].lower())
    if not fmt:
        raise ToolError(
            "Unsupported document format: %s (supported: %s)"
            % (os.path.splitext(path)[1] or "?", ", ".join(sorted(FORMATS)))
        )
    return fmt


def _open_zip(path):
    if not os.path.isfile(path):
        raise ToolError("No such file: %s" % path)
    size = os.path.getsize(path)
    if size > MAX_FILE_BYTES:
        raise ToolError(
            "Document is too large (%dMB > %dMB)." % (size >> 20, MAX_FILE_BYTES >> 20)
        )
    try:
        return zipfile.ZipFile(path, "r")
    except zipfile.BadZipFile:
        raise ToolError("Not a valid document container (zip): %s" % path)


def _read_part(zf, name):
    """Read one XML part as text, or None when it is absent."""
    try:
        info = zf.getinfo(name)
    except KeyError:
        return None
    if info.file_size > MAX_PART_BYTES:
        raise ToolError("Document part is too large: %s" % name)
    return zf.read(name).decode("utf-8", "replace")


def _parse(xml_text, name):
    try:
        return ET.fromstring(xml_text)
    except ET.ParseError as e:
        raise ToolError("Could not parse %s: %s" % (name, e))


def _serialize(root):
    return XML_DECL + ET.tostring(root, encoding="unicode")


def _rewrite_zip(path, replacements, additions=None, removals=None):
    """Rewrite the container.

    * `replacements`: part name -> new text (str) or bytes.
    * `additions`:    brand-new parts (same shape). Appended after the originals.
    * `removals`:     part names to drop.

    Everything else is copied through unchanged, in the original order, with the
    original compression type. The new file is written next to the original and
    then moved into place, so an interrupted run cannot leave a half-written
    document behind.
    """
    removals = set(removals or ())
    src = _open_zip(path)
    tmp_fd, tmp_path = tempfile.mkstemp(
        dir=os.path.dirname(path) or ".", suffix=".tmp"
    )
    os.close(tmp_fd)

    def _payload(data):
        return data if isinstance(data, bytes) else data.encode("utf-8")

    try:
        with src, zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as out:
            for info in src.infolist():
                if info.filename in removals:
                    continue
                data = replacements.get(info.filename)
                payload = _payload(data) if data is not None else src.read(info)
                # Keep per-entry metadata (mtime/compression). Stored entries
                # must stay stored — e.g. the mimetype entry of ODF files.
                new_info = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                new_info.compress_type = info.compress_type
                new_info.external_attr = info.external_attr
                new_info.internal_attr = info.internal_attr
                new_info.create_system = info.create_system
                out.writestr(new_info, payload)
            for name, data in (additions or {}).items():
                out.writestr(name, _payload(data))
        shutil.copystat(path, tmp_path)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


# --- docx -------------------------------------------------------------------

DOC_PART = "word/document.xml"


def _w(tag):
    return "{%s}%s" % (W, tag)


def _para_text(para):
    """Visible text of a `w:p` (tabs and breaks included, like Word shows it)."""
    out = []
    for node in para.iter():
        if node.tag == _w("t"):
            out.append(node.text or "")
        elif node.tag == _w("tab"):
            out.append("\t")
        elif node.tag in (_w("br"), _w("cr")):
            out.append("\n")
    return "".join(out)


def _docx_paragraphs(root):
    return list(root.iter(_w("p")))


def _set_para_text(para, text):
    """Replace a paragraph's text, keeping the first run's formatting.

    The first `w:t` takes the new text and every other `w:t` in the paragraph is
    emptied — that is what collapses mixed formatting inside this one paragraph.
    A paragraph with no run yet gets one built from scratch.
    """
    ts = [n for n in para.iter() if n.tag == _w("t")]
    if not ts:
        run = ET.SubElement(para, _w("r"))
        t = ET.SubElement(run, _w("t"))
        ts = [t]
    first = ts[0]
    first.text = text
    # Leading/trailing spaces survive only with xml:space="preserve".
    first.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
    for extra in ts[1:]:
        extra.text = ""


def _docx_read(zf):
    xml = _read_part(zf, DOC_PART)
    if xml is None:
        raise ToolError("Not a Word document (missing %s)." % DOC_PART)
    root = _parse(xml, DOC_PART)
    paras = _docx_paragraphs(root)
    return root, [_para_text(p) for p in paras]


# --- pptx -------------------------------------------------------------------

def _a(tag):
    return "{%s}%s" % (A, tag)


def _slide_parts(zf):
    """Slide parts in slide order (slide1, slide2, … — not zip order)."""
    names = [
        n for n in zf.namelist()
        if re.match(r"^ppt/slides/slide\d+\.xml$", n)
    ]

    def index_of(name):
        m = re.search(r"slide(\d+)\.xml$", name)
        return int(m.group(1)) if m else 0

    return sorted(names, key=index_of)


def _pptx_texts(root):
    """All `a:t` nodes of a slide in document order."""
    return [n for n in root.iter(_a("t"))]


# --- xlsx -------------------------------------------------------------------

def _s(tag):
    return "{%s}%s" % (S, tag)


CELL_RE = re.compile(r"^([A-Za-z]+)(\d+)$")


def _col_index(ref):
    """'B2' -> 2 (1-based column). Used to keep cells in order when inserting."""
    m = CELL_RE.match(ref or "")
    if not m:
        raise ToolError("Invalid cell reference: %s" % ref)
    col = 0
    for ch in m.group(1).upper():
        col = col * 26 + (ord(ch) - 64)
    return col


def _row_index(ref):
    m = CELL_RE.match(ref or "")
    if not m:
        raise ToolError("Invalid cell reference: %s" % ref)
    return int(m.group(2))


def _shared_strings(zf):
    xml = _read_part(zf, "xl/sharedStrings.xml")
    if xml is None:
        return []
    root = _parse(xml, "xl/sharedStrings.xml")
    out = []
    for si in root.iter(_s("si")):
        out.append("".join(t.text or "" for t in si.iter(_s("t"))))
    return out


def _sheet_map(zf):
    """Sheet name -> part name, in workbook order.

    Resolved through the workbook relationships so it works with files whose
    sheet parts are not named sheet1.xml, sheet2.xml … in order.
    """
    wb = _read_part(zf, "xl/workbook.xml")
    if wb is None:
        raise ToolError("Not an Excel workbook (missing xl/workbook.xml).")
    rels_xml = _read_part(zf, "xl/_rels/workbook.xml.rels") or ""
    rel_target = {}
    if rels_xml:
        rels = _parse(rels_xml, "xl/_rels/workbook.xml.rels")
        for rel in rels.iter("{%s}Relationship" % PKG_REL):
            target = rel.get("Target") or ""
            if target.startswith("/"):
                target = target[1:]
            elif not target.startswith("xl/"):
                target = "xl/" + target
            rel_target[rel.get("Id")] = target.replace("\\", "/")

    root = _parse(wb, "xl/workbook.xml")
    out = {}
    for i, sheet in enumerate(root.iter(_s("sheet")), start=1):
        name = sheet.get("name") or ("Sheet%d" % i)
        rid = sheet.get("{%s}id" % OFF_REL)
        part = rel_target.get(rid) or ("xl/worksheets/sheet%d.xml" % i)
        out[name] = part
    if not out:
        raise ToolError("The workbook has no sheets.")
    return out


def _cell_value(cell, shared):
    """Displayed value of a `c` element (shared string, inline or literal)."""
    kind = cell.get("t")
    if kind == "s":
        v = cell.find(_s("v"))
        try:
            return shared[int(v.text)] if v is not None and v.text else ""
        except (ValueError, IndexError):
            return ""
    if kind == "inlineStr":
        is_el = cell.find(_s("is"))
        if is_el is None:
            return ""
        return "".join(t.text or "" for t in is_el.iter(_s("t")))
    v = cell.find(_s("v"))
    return (v.text or "") if v is not None else ""


def _sheet_rows(root, shared):
    """[(row_number, [(ref, value), …]), …] within the row/column guards."""
    rows = []
    for row in root.iter(_s("row")):
        if len(rows) >= MAX_ROWS:
            break
        cells = []
        for cell in row.iter(_s("c")):
            if len(cells) >= MAX_COLS:
                break
            value = _cell_value(cell, shared)
            if value != "":
                cells.append((cell.get("r") or "", value))
        if cells:
            rows.append((row.get("r") or "", cells))
    return rows


def _find_or_make_cell(sheet_root, ref):
    """Get the `c` element for `ref`, creating the row/cell when missing.

    Rows and cells are kept in ascending order — Excel refuses to open a sheet
    whose cells are out of order.
    """
    sheet_data = sheet_root.find(_s("sheetData"))
    if sheet_data is None:
        sheet_data = ET.SubElement(sheet_root, _s("sheetData"))
    want_row = _row_index(ref)
    want_col = _col_index(ref)

    target_row = None
    for row in sheet_data.findall(_s("row")):
        try:
            num = int(row.get("r") or "0")
        except ValueError:
            continue
        if num == want_row:
            target_row = row
            break
        if num > want_row:
            target_row = ET.Element(_s("row"))
            target_row.set("r", str(want_row))
            sheet_data.insert(list(sheet_data).index(row), target_row)
            break
    if target_row is None:
        target_row = ET.SubElement(sheet_data, _s("row"))
        target_row.set("r", str(want_row))

    for cell in target_row.findall(_s("c")):
        cref = cell.get("r") or ""
        if cref.upper() == ref.upper():
            return cell
        if _col_index(cref) > want_col:
            new_cell = ET.Element(_s("c"))
            new_cell.set("r", ref.upper())
            target_row.insert(list(target_row).index(cell), new_cell)
            return new_cell
    new_cell = ET.SubElement(target_row, _s("c"))
    new_cell.set("r", ref.upper())
    return new_cell


def _set_cell_text(cell, text):
    """Write a literal string into a cell (as an inline string).

    Inline strings avoid touching the shared-string table, where one entry can
    be referenced by many cells — editing it would silently change them too.
    """
    for child in list(cell):
        cell.remove(child)
    cell.set("t", "inlineStr")
    is_el = ET.SubElement(cell, _s("is"))
    t_el = ET.SubElement(is_el, _s("t"))
    t_el.text = text
    t_el.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")


# --- ODF (read-only) --------------------------------------------------------

def _odf_paragraphs(zf):
    xml = _read_part(zf, "content.xml")
    if xml is None:
        raise ToolError("Not an OpenDocument file (missing content.xml).")
    root = _parse(xml, "content.xml")
    out = []
    for para in root.iter("{%s}p" % ODF_TEXT):
        out.append("".join(para.itertext()))
    return out


# --- shared ------------------------------------------------------------------

def _clip_text(text):
    if len(text) <= MAX_TEXT_CHARS:
        return text, False
    return text[:MAX_TEXT_CHARS], True


def _extract_text(path, fmt):
    """Whole-document plain text — used for before/after diffs."""
    zf = _open_zip(path)
    with zf:
        if fmt == "docx":
            _, paras = _docx_read(zf)
            return "\n".join(paras)
        if fmt == "pptx":
            chunks = []
            for i, part in enumerate(_slide_parts(zf), start=1):
                root = _parse(_read_part(zf, part), part)
                chunks.append("# slide %d" % i)
                chunks.extend(t.text or "" for t in _pptx_texts(root))
            return "\n".join(chunks)
        if fmt == "xlsx":
            shared = _shared_strings(zf)
            chunks = []
            for name, part in _sheet_map(zf).items():
                xml = _read_part(zf, part)
                if xml is None:
                    continue
                chunks.append("# %s" % name)
                for _, cells in _sheet_rows(_parse(xml, part), shared):
                    chunks.append(
                        "\t".join("%s=%s" % (ref, val) for ref, val in cells)
                    )
            return "\n".join(chunks)
        return "\n".join(_odf_paragraphs(zf))


def _core_properties(zf):
    xml = _read_part(zf, "docProps/core.xml")
    if xml is None:
        return {}
    root = _parse(xml, "docProps/core.xml")
    out = {}
    for tag, key in (
        ("{%s}title" % DC, "title"),
        ("{%s}creator" % DC, "creator"),
        ("{%s}subject" % DC, "subject"),
        ("{%s}lastModifiedBy" % CP, "last_modified_by"),
    ):
        node = root.find(tag)
        if node is not None and node.text:
            out[key] = node.text
    return out


# --- tools ------------------------------------------------------------------

@tool(
    "document_info",
    "Inspect a document (docx/xlsx/pptx/odt/ods/odp): format, structure counts "
    "and core properties. Use this before reading or editing to learn what "
    "addresses (paragraph index / sheet+cell / slide) exist.",
    {
        "type": "object",
        "properties": {"path": {"type": "string", "description": "Document path."}},
        "required": ["path"],
    },
)
def _tool_document_info(args):
    path = _resolve(args.get("path"))
    fmt = _format_of(path)
    zf = _open_zip(path)
    with zf:
        info = {
            "path": path,
            "format": fmt,
            "size": os.path.getsize(path),
            "parts": len(zf.namelist()),
            "properties": _core_properties(zf),
            "editable": fmt in ("docx", "xlsx", "pptx"),
        }
        if fmt == "docx":
            _, paras = _docx_read(zf)
            info["paragraphs"] = len(paras)
        elif fmt == "pptx":
            info["slides"] = len(_slide_parts(zf))
        elif fmt == "xlsx":
            info["sheets"] = list(_sheet_map(zf).keys())
        else:
            info["paragraphs"] = len(_odf_paragraphs(zf))
            info["note"] = "OpenDocument files are read-only in this module."
    return info


@tool(
    "read_document",
    "Read the text of a document (docx/xlsx/pptx/odt/ods/odp) with the "
    "addresses needed to edit it: docx -> paragraph index, xlsx -> sheet+cell "
    "reference, pptx -> slide and text index. Long documents are truncated.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Document path."},
            "sheet": {
                "type": "string",
                "description": "xlsx only: read just this sheet (default: all).",
            },
            "slide": {
                "type": "integer",
                "description": "pptx only: read just this 1-based slide.",
            },
        },
        "required": ["path"],
    },
)
def _tool_read_document(args):
    path = _resolve(args.get("path"))
    fmt = _format_of(path)
    zf = _open_zip(path)
    with zf:
        if fmt == "docx":
            _, paras = _docx_read(zf)
            body, clipped = _clip_text("\n".join(paras))
            return {
                "format": fmt,
                "paragraphs": [
                    {"index": i, "text": t} for i, t in enumerate(paras)
                ][:MAX_ROWS],
                "text": body,
                "truncated": clipped or len(paras) > MAX_ROWS,
            }

        if fmt == "pptx":
            want = args.get("slide")
            slides = []
            for i, part in enumerate(_slide_parts(zf), start=1):
                if want and int(want) != i:
                    continue
                root = _parse(_read_part(zf, part), part)
                slides.append({
                    "slide": i,
                    "texts": [
                        {"index": j, "text": t.text or ""}
                        for j, t in enumerate(_pptx_texts(root))
                    ],
                })
            return {"format": fmt, "slides": slides}

        if fmt == "xlsx":
            shared = _shared_strings(zf)
            want = args.get("sheet")
            sheets = []
            for name, part in _sheet_map(zf).items():
                if want and want != name:
                    continue
                xml = _read_part(zf, part)
                if xml is None:
                    continue
                rows = _sheet_rows(_parse(xml, part), shared)
                sheets.append({
                    "name": name,
                    "rows": [
                        {"row": rnum, "cells": [
                            {"ref": ref, "value": val} for ref, val in cells
                        ]}
                        for rnum, cells in rows
                    ],
                })
            if want and not sheets:
                raise ToolError("No such sheet: %s" % want)
            return {"format": fmt, "sheets": sheets}

        paras = _odf_paragraphs(zf)
        body, clipped = _clip_text("\n".join(paras))
        return {
            "format": fmt,
            "paragraphs": [{"index": i, "text": t} for i, t in enumerate(paras)],
            "text": body,
            "truncated": clipped,
            "note": "OpenDocument files are read-only in this module.",
        }


@tool(
    "edit_document",
    "Replace text in a document (docx/xlsx/pptx). Every other part of the file "
    "(styles, images, other paragraphs) is preserved. NOTE: the replaced "
    "paragraph/shape keeps only its first run's formatting, so mixed formatting "
    "inside that one paragraph is flattened. Read the document first to get the "
    "addresses.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Document path."},
            "edits": {
                "type": "array",
                "description": (
                    "One or more edits to apply in order. Each item addresses ONE "
                    "place and carries its new text. Give only the fields for this "
                    "document's format: "
                    "docx -> {\"paragraph\": 0, \"text\": \"...\"}; "
                    "xlsx -> {\"sheet\": \"Sheet1\", \"cell\": \"B2\", \"text\": \"...\"}; "
                    "pptx -> {\"slide\": 1, \"index\": 0, \"text\": \"...\"}. "
                    "Get the addresses from read_document."
                ),
                "items": {
                    "type": "object",
                    "description": "One edit: an address plus the new text.",
                    "properties": {
                        "text": {
                            "type": "string",
                            "description": "The new text for this place (required). "
                                           "It replaces what is there now.",
                        },
                        "paragraph": {
                            "type": "integer",
                            "description": "docx only: 0-based paragraph index from "
                                           "read_document.",
                        },
                        "sheet": {
                            "type": "string",
                            "description": "xlsx only: sheet name (default: the "
                                           "first sheet).",
                        },
                        "cell": {
                            "type": "string",
                            "description": "xlsx only: cell reference such as B2. "
                                           "The cell is created if it does not exist.",
                        },
                        "slide": {
                            "type": "integer",
                            "description": "pptx only: 1-based slide number.",
                        },
                        "index": {
                            "type": "integer",
                            "description": "pptx only: 0-based index of the text run "
                                           "on that slide, from read_document.",
                        },
                    },
                    "required": ["text"],
                },
            },
        },
        "required": ["path", "edits"],
    },
)
def _tool_edit_document(args):
    path = _resolve(args.get("path"))
    fmt = _format_of(path)
    # 배열/각 항목이 JSON 문자열로 오는 경우까지 받아 준다(모델이 자주 그런다).
    edits = [_as_object(e, "edits[]") for e in _as_array(args.get("edits"), "edits")]
    if not edits:
        raise ToolError("'edits' must be a non-empty array.")
    if fmt not in ("docx", "xlsx", "pptx"):
        raise ToolError("Editing %s files is not supported yet (read-only)." % fmt)

    before = _extract_text(path, fmt)
    zf = _open_zip(path)
    applied = 0
    with zf:
        replacements = {}
        if fmt == "docx":
            root, _ = _docx_read(zf)
            paras = _docx_paragraphs(root)
            for edit in edits:
                idx = edit.get("paragraph")
                if not isinstance(idx, int):
                    raise ToolError("docx edits need an integer 'paragraph'.")
                if idx < 0 or idx >= len(paras):
                    raise ToolError(
                        "No paragraph %d (the document has %d)." % (idx, len(paras))
                    )
                _set_para_text(paras[idx], str(edit.get("text", "")))
                applied += 1
            replacements[DOC_PART] = _serialize(root)

        elif fmt == "pptx":
            parts = _slide_parts(zf)
            roots = {}
            for edit in edits:
                slide = edit.get("slide")
                index = edit.get("index")
                if not isinstance(slide, int) or not isinstance(index, int):
                    raise ToolError("pptx edits need integer 'slide' and 'index'.")
                if slide < 1 or slide > len(parts):
                    raise ToolError(
                        "No slide %d (the deck has %d)." % (slide, len(parts))
                    )
                part = parts[slide - 1]
                if part not in roots:
                    roots[part] = _parse(_read_part(zf, part), part)
                texts = _pptx_texts(roots[part])
                if index < 0 or index >= len(texts):
                    raise ToolError(
                        "No text %d on slide %d (it has %d)."
                        % (index, slide, len(texts))
                    )
                texts[index].text = str(edit.get("text", ""))
                applied += 1
            for part, root in roots.items():
                replacements[part] = _serialize(root)

        else:  # xlsx
            sheets = _sheet_map(zf)
            roots = {}
            for edit in edits:
                name = edit.get("sheet") or next(iter(sheets))
                ref = edit.get("cell")
                if not ref:
                    raise ToolError("xlsx edits need a 'cell' reference (e.g. B2).")
                part = sheets.get(name)
                if part is None:
                    raise ToolError("No such sheet: %s" % name)
                if part not in roots:
                    xml = _read_part(zf, part)
                    if xml is None:
                        raise ToolError("Missing sheet part: %s" % part)
                    roots[part] = _parse(xml, part)
                cell = _find_or_make_cell(roots[part], str(ref))
                if cell.find(_s("f")) is not None:
                    raise ToolError(
                        "%s!%s holds a formula; refusing to overwrite it." % (name, ref)
                    )
                _set_cell_text(cell, str(edit.get("text", "")))
                applied += 1
            for part, root in roots.items():
                replacements[part] = _serialize(root)

    _rewrite_zip(path, replacements)
    after = _extract_text(path, fmt)
    return {
        "path": path,
        "format": fmt,
        "edits_applied": applied,
        "parts_rewritten": sorted(replacements.keys()),
        "diff": _diff(before, after, path),
    }


@tool(
    "replace_in_document",
    "Find and replace text across a Word document or PowerPoint deck "
    "(docx/pptx). Matching is done per text run, so a phrase split across "
    "formatting boundaries may not match — use edit_document for those. For "
    "spreadsheets use edit_document with a cell reference.",
    {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Document path."},
            "find": {"type": "string", "description": "Text to look for."},
            "replace": {"type": "string", "description": "Replacement text."},
            "count": {
                "type": "integer",
                "description": "Maximum replacements (default: all).",
            },
        },
        "required": ["path", "find", "replace"],
    },
)
def _tool_replace_in_document(args):
    path = _resolve(args.get("path"))
    fmt = _format_of(path)
    find = args.get("find")
    replace = args.get("replace")
    if not find:
        raise ToolError("'find' is required.")
    if replace is None:
        raise ToolError("'replace' is required.")
    if fmt not in ("docx", "pptx"):
        raise ToolError(
            "replace_in_document supports docx and pptx; use edit_document for %s."
            % fmt
        )
    limit = args.get("count")
    limit = int(limit) if isinstance(limit, int) and limit > 0 else None

    before = _extract_text(path, fmt)
    done = 0
    zf = _open_zip(path)
    with zf:
        replacements = {}
        if fmt == "docx":
            root, _ = _docx_read(zf)
            nodes = [n for n in root.iter(_w("t"))]
        else:
            root = None
            nodes = []
            roots = {}
            for part in _slide_parts(zf):
                roots[part] = _parse(_read_part(zf, part), part)
                nodes.extend((part, n) for n in _pptx_texts(roots[part]))

        if fmt == "docx":
            for node in nodes:
                if limit is not None and done >= limit:
                    break
                text = node.text or ""
                if find not in text:
                    continue
                room = None if limit is None else limit - done
                new_text = text.replace(find, replace) if room is None \
                    else text.replace(find, replace, room)
                done += text.count(find) if room is None else min(text.count(find), room)
                node.text = new_text
            replacements[DOC_PART] = _serialize(root)
        else:
            touched = set()
            for part, node in nodes:
                if limit is not None and done >= limit:
                    break
                text = node.text or ""
                if find not in text:
                    continue
                room = None if limit is None else limit - done
                node.text = text.replace(find, replace) if room is None \
                    else text.replace(find, replace, room)
                done += text.count(find) if room is None else min(text.count(find), room)
                touched.add(part)
            for part in touched:
                replacements[part] = _serialize(roots[part])

    if done == 0:
        return {"path": path, "replacements": 0, "note": "No match; file unchanged."}

    _rewrite_zip(path, replacements)
    after = _extract_text(path, fmt)
    return {
        "path": path,
        "format": fmt,
        "replacements": done,
        "diff": _diff(before, after, path),
    }


# ============================================================================
# Advanced operations
#
# These live behind ONE tool (`document_advanced`) with an `action` argument
# instead of one tool per operation. A local/small model has to read every tool
# schema on every request, so twenty extra top-level tools would crowd out the
# ones it needs. Here it sees a single schema, and can ask for the details of a
# specific action with action="actions" when it actually needs them.
# ============================================================================

_ACTIONS = {}


def action(name, formats, summary, args_doc):
    """Register a sub-command. `args_doc` is a short {arg: description} map."""

    def deco(func):
        _ACTIONS[name] = {
            "name": name,
            "formats": formats,
            "summary": summary,
            "args": args_doc,
            "func": func,
        }
        return func

    return deco


def _parent_map(root):
    """ElementTree has no parent pointers; build the map we need to insert/remove."""
    return {child: parent for parent in root.iter() for child in parent}


def _as_object(value, name, default=None):
    """객체를 기대하는 인자를 받아 준다.

    **LLM 이 객체 대신 JSON 문자열을 넘기는 일이 잦다**(`"{\\"slide\\": 1}"`).
    그래서 문자열이면 **한 번만** 파싱해 본다. 실패하면 예외를 밖으로 던지지 않고
    타입이 맞지 않는다는 도구 오류로 돌려준다 — 모델이 그 메시지를 보고 형태를
    고쳐 다시 부를 수 있다.
    """
    if value is None:
        return {} if default is None else default
    if isinstance(value, dict):
        return value
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return {} if default is None else default
        try:
            parsed = json.loads(text)
        except ValueError:
            raise ToolError(
                "'%s' must be an object, not a string. Send it as JSON, e.g. "
                '{"slide": 1, "shape": 0}.' % name
            )
        if isinstance(parsed, dict):
            return parsed
        raise ToolError(
            "'%s' must be an object; got %s." % (name, type(parsed).__name__)
        )
    raise ToolError("'%s' must be an object; got %s." % (name, type(value).__name__))


def _as_array(value, name, default=None):
    """배열을 기대하는 인자를 받아 준다([_as_object] 와 같은 이유·규칙).

    항목이 하나뿐일 때 배열로 감싸지 않고 **객체 하나만** 보내는 모델도 잦다
    (`edits: {...}`). 뜻이 분명하므로 1개짜리 배열로 본다.
    """
    if value is None:
        return [] if default is None else default
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        return [value]
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return [] if default is None else default
        try:
            parsed = json.loads(text)
        except ValueError:
            raise ToolError(
                "'%s' must be an array, not a string. Send it as JSON, e.g. "
                '[["a", "b"], ["c", "d"]].' % name
            )
        if isinstance(parsed, list):
            return parsed
        if isinstance(parsed, dict):
            return [parsed]
        raise ToolError(
            "'%s' must be an array; got %s." % (name, type(parsed).__name__)
        )
    raise ToolError("'%s' must be an array; got %s." % (name, type(value).__name__))


def _need(args, key, kind=None):
    if key not in args or args[key] is None:
        raise ToolError("'%s' is required for this action." % key)
    value = args[key]
    if kind is int and not isinstance(value, int):
        raise ToolError("'%s' must be an integer." % key)
    if kind is str and not isinstance(value, str):
        raise ToolError("'%s' must be a string." % key)
    return value


# --- structure --------------------------------------------------------------

@action(
    "structure",
    "docx/xlsx/pptx/odf",
    "Outline of the document: docx headings+tables, xlsx sheets+size, pptx slides+shapes.",
    {},
)
def _act_structure(path, fmt, zf, args):
    if fmt == "docx":
        root, _ = _docx_read(zf)
        items = []
        for i, para in enumerate(_docx_paragraphs(root)):
            text = _para_text(para)
            style = None
            ppr = para.find(_w("pPr"))
            if ppr is not None:
                st = ppr.find(_w("pStyle"))
                if st is not None:
                    style = st.get(_w("val"))
            if style or text.strip():
                items.append({
                    "paragraph": i,
                    "style": style,
                    "heading": _heading_level(style),
                    "text": text[:120],
                })
        tables = []
        for ti, tbl in enumerate(root.iter(_w("tbl"))):
            rows = tbl.findall(_w("tr"))
            cols = len(rows[0].findall(_w("tc"))) if rows else 0
            tables.append({"table": ti, "rows": len(rows), "cols": cols})
        return {"format": fmt, "outline": items[:MAX_ROWS], "tables": tables}

    if fmt == "pptx":
        slides = []
        for i, part in enumerate(_slide_parts(zf), start=1):
            root = _parse(_read_part(zf, part), part)
            shapes = [
                {"index": j, "text": (t.text or "")[:80]}
                for j, t in enumerate(_pptx_texts(root))
            ]
            slides.append({"slide": i, "part": part, "shapes": shapes})
        return {"format": fmt, "slides": slides}

    if fmt == "xlsx":
        shared = _shared_strings(zf)
        sheets = []
        for name, part in _sheet_map(zf).items():
            xml = _read_part(zf, part)
            rows = _sheet_rows(_parse(xml, part), shared) if xml else []
            last_col = 0
            for _, cells in rows:
                for ref, _v in cells:
                    last_col = max(last_col, _col_index(ref))
            sheets.append({
                "name": name, "part": part,
                "rows": len(rows), "columns": last_col,
            })
        return {"format": fmt, "sheets": sheets}

    return {"format": fmt, "paragraphs": len(_odf_paragraphs(zf)),
            "note": "OpenDocument files are read-only in this module."}


def _heading_level(style):
    """'Heading2' / 'heading 2' -> 2. Anything else -> None."""
    if not style:
        return None
    m = re.match(r"^heading\s*([1-9])$", style.strip(), re.IGNORECASE)
    return int(m.group(1)) if m else None


# --- docx: paragraphs & headings --------------------------------------------

def _new_paragraph(text, style=None):
    para = ET.Element(_w("p"))
    if style:
        ppr = ET.SubElement(para, _w("pPr"))
        st = ET.SubElement(ppr, _w("pStyle"))
        st.set(_w("val"), style)
    run = ET.SubElement(para, _w("r"))
    t = ET.SubElement(run, _w("t"))
    t.text = text or ""
    t.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
    return para


@action(
    "insert_paragraph",
    "docx",
    "Insert a new paragraph. Use heading=1..6 to make it a heading.",
    {"index": "(int, optional) insert before this 0-based paragraph; omit or -1 = append at the end",
     "text": "(string) paragraph text",
     "heading": "(int, optional) 1..6 to style it as a heading"},
)
def _act_insert_paragraph(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    paras = _docx_paragraphs(root)
    text = str(args.get("text", ""))
    level = args.get("heading")
    style = "Heading%d" % int(level) if isinstance(level, int) and 1 <= level <= 6 else None
    node = _new_paragraph(text, style)

    index = args.get("index", -1)
    if not isinstance(index, int) or index < 0 or index >= len(paras):
        body = root.find(_w("body"))
        if body is None:
            raise ToolError("Malformed document (no w:body).")
        # sectPr must stay last in the body.
        sect = body.find(_w("sectPr"))
        if sect is not None:
            body.insert(list(body).index(sect), node)
        else:
            body.append(node)
        at = len(paras)
    else:
        parents = _parent_map(root)
        ref = paras[index]
        parent = parents[ref]
        parent.insert(list(parent).index(ref), node)
        at = index
    return {"paragraph": at, "parts": {DOC_PART: _serialize(root)}}


@action(
    "delete_paragraph",
    "docx",
    "Delete paragraphs by index (inclusive range).",
    {"index": "(int) 0-based paragraph index",
     "to": "(int, optional) last index of an inclusive range"},
)
def _act_delete_paragraph(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    paras = _docx_paragraphs(root)
    start = _need(args, "index", int)
    end = args.get("to", start)
    if not isinstance(end, int):
        raise ToolError("'to' must be an integer.")
    if start < 0 or end >= len(paras) or end < start:
        raise ToolError(
            "Bad range %s..%s (the document has %d paragraphs)."
            % (start, end, len(paras))
        )
    parents = _parent_map(root)
    for para in paras[start:end + 1]:
        parents[para].remove(para)
    return {"deleted": end - start + 1, "parts": {DOC_PART: _serialize(root)}}


@action(
    "set_heading",
    "docx",
    "Turn an existing paragraph into a heading (level 1..6) or back to body text (level 0).",
    {"index": "(int) 0-based paragraph index",
     "level": "(int) 1..6, or 0 to make it body text"},
)
def _act_set_heading(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    paras = _docx_paragraphs(root)
    index = _need(args, "index", int)
    level = _need(args, "level", int)
    if index < 0 or index >= len(paras):
        raise ToolError("No paragraph %d (the document has %d)." % (index, len(paras)))
    if level < 0 or level > 6:
        raise ToolError("'level' must be 0..6.")
    para = paras[index]
    ppr = para.find(_w("pPr"))
    if ppr is None:
        ppr = ET.Element(_w("pPr"))
        para.insert(0, ppr)   # pPr must be the first child of w:p
    st = ppr.find(_w("pStyle"))
    if level == 0:
        if st is not None:
            ppr.remove(st)
    else:
        if st is None:
            st = ET.SubElement(ppr, _w("pStyle"))
        st.set(_w("val"), "Heading%d" % level)
    return {"paragraph": index, "level": level,
            "parts": {DOC_PART: _serialize(root)}}


# --- docx: tables -----------------------------------------------------------

def _new_table(rows, cols, data):
    tbl = ET.Element(_w("tbl"))
    pr = ET.SubElement(tbl, _w("tblPr"))
    borders = ET.SubElement(pr, _w("tblBorders"))
    for edge in ("top", "left", "bottom", "right", "insideH", "insideV"):
        b = ET.SubElement(borders, _w(edge))
        b.set(_w("val"), "single")
        b.set(_w("sz"), "4")
        b.set(_w("color"), "auto")
    grid = ET.SubElement(tbl, _w("tblGrid"))
    for _ in range(cols):
        ET.SubElement(grid, _w("gridCol")).set(_w("w"), "2400")
    for r in range(rows):
        tr = ET.SubElement(tbl, _w("tr"))
        for c in range(cols):
            tc = ET.SubElement(tr, _w("tc"))
            tc_pr = ET.SubElement(tc, _w("tcPr"))
            ET.SubElement(tc_pr, _w("tcW")).set(_w("w"), "2400")
            text = ""
            try:
                text = str(data[r][c])
            except (IndexError, TypeError):
                text = ""
            tc.append(_new_paragraph(text))
    return tbl


@action(
    "insert_table",
    "docx",
    "Insert a table. `data` is a 2D array of strings (rows x cols).",
    {"index": "(int, optional) insert before this 0-based paragraph; omit = append at the end",
     "rows": "(int, optional) row count (default: number of rows in data)",
     "cols": "(int, optional) column count (default: longest row of data)",
     "data": "(array of arrays of strings, optional) cell texts, row by row"},
)
def _act_insert_table(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    data = [_as_array(r, "data[]") for r in _as_array(args.get("data"), "data")]
    rows = args.get("rows") or len(data)
    cols = args.get("cols") or (max((len(r) for r in data if isinstance(r, list)), default=0))
    if not rows or not cols:
        raise ToolError("A table needs at least one row and one column.")
    if rows > 200 or cols > 50:
        raise ToolError("Table is too large (max 200 rows x 50 columns).")
    tbl = _new_table(int(rows), int(cols), data)

    paras = _docx_paragraphs(root)
    index = args.get("index")
    body = root.find(_w("body"))
    if isinstance(index, int) and 0 <= index < len(paras):
        parents = _parent_map(root)
        ref = paras[index]
        parent = parents[ref]
        at = list(parent).index(ref)
        parent.insert(at, tbl)
        # Word wants a paragraph after a table; keep the reference paragraph there.
    else:
        sect = body.find(_w("sectPr")) if body is not None else None
        if body is None:
            raise ToolError("Malformed document (no w:body).")
        pos = list(body).index(sect) if sect is not None else len(list(body))
        body.insert(pos, tbl)
        body.insert(pos + 1, _new_paragraph(""))   # 표 뒤에는 문단이 있어야 한다
    return {"rows": int(rows), "cols": int(cols),
            "parts": {DOC_PART: _serialize(root)}}


@action(
    "set_table_cell",
    "docx",
    "Write text into one table cell (0-based table/row/col; see action=structure).",
    {"table": "(int) 0-based table index (see action=structure)",
     "row": "(int) 0-based row index",
     "col": "(int) 0-based column index",
     "text": "(string) cell text"},
)
def _act_set_table_cell(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    tables = list(root.iter(_w("tbl")))
    ti = _need(args, "table", int)
    ri = _need(args, "row", int)
    ci = _need(args, "col", int)
    if ti < 0 or ti >= len(tables):
        raise ToolError("No table %d (the document has %d)." % (ti, len(tables)))
    rows = tables[ti].findall(_w("tr"))
    if ri < 0 or ri >= len(rows):
        raise ToolError("No row %d (the table has %d)." % (ri, len(rows)))
    cells = rows[ri].findall(_w("tc"))
    if ci < 0 or ci >= len(cells):
        raise ToolError("No column %d (the row has %d)." % (ci, len(cells)))
    cell = cells[ci]
    para = cell.find(_w("p"))
    if para is None:
        para = _new_paragraph("")
        cell.append(para)
    _set_para_text(para, str(args.get("text", "")))
    return {"table": ti, "row": ri, "col": ci,
            "parts": {DOC_PART: _serialize(root)}}


# --- docx: images -----------------------------------------------------------

IMAGE_TYPES = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".gif": "image/gif", ".bmp": "image/bmp", ".tif": "image/tiff",
    ".tiff": "image/tiff", ".webp": "image/webp",
}
EMU_PER_CM = 360000


def _image_size(data):
    """(width, height) in pixels, or None. Header-only parsing, no dependencies."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return (int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big"))
        if data[:3] == b"GIF":
            return (int.from_bytes(data[6:8], "little"), int.from_bytes(data[8:10], "little"))
        if data[:2] == b"\xff\xd8":  # JPEG: walk the markers to a SOF segment
            i = 2
            while i + 9 < len(data):
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                              0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    return (int.from_bytes(data[i + 7:i + 9], "big"),
                            int.from_bytes(data[i + 5:i + 7], "big"))
                i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    except Exception:
        return None
    return None


def _next_rel_id(rels_root):
    used = {r.get("Id") for r in rels_root}
    n = 1
    while ("rId%d" % n) in used:
        n += 1
    return "rId%d" % n


def _drawing_xml(rel_id, cx, cy, name):
    """`w:drawing` for an inline picture (namespaces declared inline)."""
    wp = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
    pic = "http://schemas.openxmlformats.org/drawingml/2006/picture"
    return (
        '<w:drawing xmlns:w="%s" xmlns:wp="%s" xmlns:a="%s" xmlns:pic="%s" xmlns:r="%s">'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="%d" cy="%d"/>'
        '<wp:docPr id="1" name="%s"/>'
        '<a:graphic><a:graphicData uri="%s">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="%s"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="%s"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="%d" cy="%d"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>'
        % (W, wp, A, pic, OFF_REL, cx, cy, name, pic, name, rel_id, cx, cy)
    )


@action(
    "insert_image",
    "docx",
    "Insert an image (png/jpg/gif/bmp/tiff/webp) as its own paragraph.",
    {"image": "(string) path of the image file (inside the workspace)",
     "index": "(int, optional) insert before this 0-based paragraph; omit = append at the end",
     "width_cm": "(number, optional) display width in cm (default 10; height keeps the aspect ratio)"},
)
def _act_insert_image(path, fmt, zf, args):
    _only(fmt, "docx")
    img_path = _resolve(_need(args, "image", str))
    ext = os.path.splitext(img_path)[1].lower()
    if ext not in IMAGE_TYPES:
        raise ToolError("Unsupported image type: %s" % (ext or "?"))
    if not os.path.isfile(img_path):
        raise ToolError("No such image: %s" % img_path)
    blob = open(img_path, "rb").read()
    if len(blob) > MAX_PART_BYTES:
        raise ToolError("Image is too large (%dMB)." % (len(blob) >> 20))

    width_cm = args.get("width_cm") or 10
    try:
        width_cm = float(width_cm)
    except (TypeError, ValueError):
        raise ToolError("'width_cm' must be a number.")
    size = _image_size(blob)
    ratio = (size[1] / size[0]) if size and size[0] else 0.75
    cx = int(width_cm * EMU_PER_CM)
    cy = int(cx * ratio)

    # 1) media part
    media_name = "word/media/collabo_%s%s" % (
        re.sub(r"[^A-Za-z0-9_-]", "_", os.path.splitext(os.path.basename(img_path))[0])[:40],
        ext,
    )
    existing = set(zf.namelist())
    n = 2
    base_media = media_name
    while media_name in existing:
        media_name = "%s_%d%s" % (os.path.splitext(base_media)[0], n, ext)
        n += 1

    # 2) relationship in word/_rels/document.xml.rels
    rels_part = "word/_rels/document.xml.rels"
    rels_xml = _read_part(zf, rels_part)
    if rels_xml is None:
        rels_root = ET.fromstring('<Relationships xmlns="%s"/>' % PKG_REL)
    else:
        rels_root = _parse(rels_xml, rels_part)
    rel_id = _next_rel_id(rels_root)
    rel = ET.SubElement(rels_root, "{%s}Relationship" % PKG_REL)
    rel.set("Id", rel_id)
    rel.set("Type", "%s/image" % OFF_REL)
    rel.set("Target", media_name[len("word/"):])

    # 3) content type for the extension (Default entry)
    ct_part = "[Content_Types].xml"
    ct_xml = _read_part(zf, ct_part)
    ct_replacement = None
    if ct_xml is not None:
        ct_root = _parse(ct_xml, ct_part)
        ct_ns = "http://schemas.openxmlformats.org/package/2006/content-types"
        has = any(
            (d.get("Extension") or "").lower() == ext[1:]
            for d in ct_root.iter("{%s}Default" % ct_ns)
        )
        if not has:
            d = ET.SubElement(ct_root, "{%s}Default" % ct_ns)
            d.set("Extension", ext[1:])
            d.set("ContentType", IMAGE_TYPES[ext])
            ct_replacement = _serialize(ct_root)

    # 4) the paragraph that shows it
    root, _ = _docx_read(zf)
    para = ET.Element(_w("p"))
    run = ET.SubElement(para, _w("r"))
    run.append(ET.fromstring(_drawing_xml(rel_id, cx, cy, os.path.basename(img_path))))
    paras = _docx_paragraphs(root)
    index = args.get("index")
    if isinstance(index, int) and 0 <= index < len(paras):
        parents = _parent_map(root)
        ref = paras[index]
        parent = parents[ref]
        parent.insert(list(parent).index(ref), para)
    else:
        body = root.find(_w("body"))
        if body is None:
            raise ToolError("Malformed document (no w:body).")
        sect = body.find(_w("sectPr"))
        if sect is not None:
            body.insert(list(body).index(sect), para)
        else:
            body.append(para)

    parts = {DOC_PART: _serialize(root)}
    if rels_xml is not None:
        parts[rels_part] = _serialize(rels_root)
    if ct_replacement:
        parts[ct_part] = ct_replacement
    additions = {media_name: blob}
    if rels_xml is None:
        additions[rels_part] = _serialize(rels_root)
    return {
        "image": media_name, "width_cm": width_cm,
        "parts": parts, "additions": additions,
    }


# --- 빈 문서 만들기 -----------------------------------------------------------
#
# OOXML 은 "빈 파일" 이라도 최소 골격이 있어야 Office 가 연다. 특히 pptx 는
# presentation → slideMaster → slideLayout → theme 가 관계(rels)로 이어져 있어야
# 하고, theme 의 fmtScheme 은 항목이 정확히 3개씩 필요하다. 그래서 아래 템플릿이
# 길다 — 대신 여기만 맞으면 그 뒤 편집 액션은 전부 그대로 쓸 수 있다.
#
# 기존 파일이 있다면 `copy_to` 가 더 안전하다(마스터·레이아웃·테마·스타일을 그대로
# 물려받는다). 이 액션은 참고할 파일이 아예 없을 때를 위한 것이다.

_RELS_NS = 'xmlns="%s"' % PKG_REL
_CT_NS = 'xmlns="http://schemas.openxmlformats.org/package/2006/content-types"'
_OOX = "application/vnd.openxmlformats-officedocument"

_DEFAULT_CT = (
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-'
    'package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
)


def _docx_template(title):
    doc = (
        '<w:document xmlns:w="%s"><w:body>'
        '<w:p><w:r><w:t xml:space="preserve"></w:t></w:r></w:p>'
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
        '</w:sectPr></w:body></w:document>' % W
    )
    # Heading1~3 을 정의해 둔다 — set_heading 이 지정하는 스타일이 실제로 보이려면
    # 이 정의가 있어야 한다(없으면 본문처럼 보인다).
    heads = "".join(
        '<w:style w:type="paragraph" w:styleId="Heading%d">'
        '<w:name w:val="heading %d"/><w:basedOn w:val="Normal"/>'
        '<w:pPr><w:outlineLvl w:val="%d"/><w:spacing w:before="%d" w:after="120"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="%d"/></w:rPr></w:style>'
        % (i, i, i - 1, 240, 36 - (i - 1) * 4)
        for i in (1, 2, 3)
    )
    styles = (
        '<w:styles xmlns:w="%s">'
        '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
        '<w:name w:val="Normal"/></w:style>%s</w:styles>' % (W, heads)
    )
    return {
        "[Content_Types].xml": XML_DECL + '<Types %s>%s'
        '<Override PartName="/word/document.xml" ContentType="%s.wordprocessingml.document.main+xml"/>'
        '<Override PartName="/word/styles.xml" ContentType="%s.wordprocessingml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>' % (_CT_NS, _DEFAULT_CT, _OOX, _OOX),
        "_rels/.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/'
        'relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "word/_rels/document.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/styles" Target="styles.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "word/document.xml": XML_DECL + doc,
        "word/styles.xml": XML_DECL + styles,
        "docProps/core.xml": _core_xml(title),
    }


def _core_xml(title):
    return XML_DECL + (
        '<cp:coreProperties xmlns:cp="%s" xmlns:dc="%s">'
        '<dc:title>%s</dc:title><dc:creator>Collabo IDE</dc:creator>'
        '</cp:coreProperties>' % (CP, DC, _xml_escape(title))
    )


def _xml_escape(text):
    return (str(text).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _xlsx_template(title, sheet_name):
    styles = (
        '<styleSheet xmlns="%s">'
        '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill>'
        '<fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
        '</styleSheet>' % S
    )
    return {
        "[Content_Types].xml": XML_DECL + '<Types %s>%s'
        '<Override PartName="/xl/workbook.xml" ContentType="%s.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="%s.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="%s.spreadsheetml.styles+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>' % (_CT_NS, _DEFAULT_CT, _OOX, _OOX, _OOX),
        "_rels/.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/'
        'relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "xl/workbook.xml": XML_DECL + '<workbook xmlns="%s" xmlns:r="%s"><sheets>'
        '<sheet name="%s" sheetId="1" r:id="rId1"/></sheets></workbook>'
        % (S, OFF_REL, _xml_escape(sheet_name)),
        "xl/_rels/workbook.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="%s/styles" Target="styles.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL, OFF_REL),
        "xl/worksheets/sheet1.xml": XML_DECL +
        '<worksheet xmlns="%s"><sheetData/></worksheet>' % S,
        "xl/styles.xml": XML_DECL + styles,
        "docProps/core.xml": _core_xml(title),
    }


def _pptx_template(title):
    empty_tree = (
        '<p:cSld><p:spTree>'
        '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
        '<p:grpSpPr/>'
        '</p:spTree></p:cSld>'
    )
    ns = 'xmlns:a="%s" xmlns:r="%s" xmlns:p="%s"' % (A, OFF_REL, PML)
    clr_map = ('<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" '
               'accent2="accent2" accent3="accent3" accent4="accent4" '
               'accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>')
    # 테마: 색/글꼴/서식. fmtScheme 의 각 목록은 **정확히 3개**여야 한다.
    accents = ("4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47")
    theme = (
        '<a:theme xmlns:a="%s" name="Office"><a:themeElements>'
        '<a:clrScheme name="Office">'
        '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>'
        '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
        '<a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>'
        '%s'
        '<a:hlink><a:srgbClr val="0563C1"/></a:hlink>'
        '<a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>'
        '<a:fontScheme name="Office">'
        '<a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
        '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>'
        '</a:fontScheme>'
        '<a:fmtScheme name="Office">'
        '<a:fillStyleLst>%s</a:fillStyleLst>'
        '<a:lnStyleLst>%s</a:lnStyleLst>'
        '<a:effectStyleLst>%s</a:effectStyleLst>'
        '<a:bgFillStyleLst>%s</a:bgFillStyleLst>'
        '</a:fmtScheme></a:themeElements></a:theme>'
        % (
            A,
            "".join('<a:accent%d><a:srgbClr val="%s"/></a:accent%d>' % (i + 1, c, i + 1)
                    for i, c in enumerate(accents)),
            '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' * 3,
            ('<a:ln w="6350" cap="flat" cmpd="sng" algn="ctr">'
             '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
             '<a:prstDash val="solid"/></a:ln>') * 3,
            '<a:effectStyle><a:effectLst/></a:effectStyle>' * 3,
            '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>' * 3,
        )
    )
    return {
        "[Content_Types].xml": XML_DECL + '<Types %s>%s'
        '<Override PartName="/ppt/presentation.xml" ContentType="%s.presentationml.presentation.main+xml"/>'
        '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="%s.presentationml.slideMaster+xml"/>'
        '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="%s.presentationml.slideLayout+xml"/>'
        '<Override PartName="/ppt/slides/slide1.xml" ContentType="%s.presentationml.slide+xml"/>'
        '<Override PartName="/ppt/theme/theme1.xml" ContentType="%s.theme+xml"/>'
        '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
        '</Types>' % (_CT_NS, _DEFAULT_CT, _OOX, _OOX, _OOX, _OOX, _OOX),
        "_rels/.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/officeDocument" Target="ppt/presentation.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/'
        'relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "ppt/presentation.xml": XML_DECL +
        '<p:presentation %s>'
        '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
        '<p:sldIdLst><p:sldId id="256" r:id="rId2"/></p:sldIdLst>'
        '<p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/>'
        '</p:presentation>' % ns,
        "ppt/_rels/presentation.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/slideMaster" Target="slideMasters/slideMaster1.xml"/>'
        '<Relationship Id="rId2" Type="%s/slide" Target="slides/slide1.xml"/>'
        '<Relationship Id="rId3" Type="%s/theme" Target="theme/theme1.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL, OFF_REL, OFF_REL),
        "ppt/slideMasters/slideMaster1.xml": XML_DECL +
        '<p:sldMaster %s>%s%s'
        '<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>'
        '</p:sldMaster>' % (ns, empty_tree, clr_map),
        "ppt/slideMasters/_rels/slideMaster1.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '<Relationship Id="rId2" Type="%s/theme" Target="../theme/theme1.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL, OFF_REL),
        "ppt/slideLayouts/slideLayout1.xml": XML_DECL +
        '<p:sldLayout %s type="blank" preserve="1">%s'
        '<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>' % (ns, empty_tree),
        "ppt/slideLayouts/_rels/slideLayout1.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "ppt/slides/slide1.xml": XML_DECL +
        '<p:sld %s>%s<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>'
        % (ns, empty_tree),
        "ppt/slides/_rels/slide1.xml.rels": XML_DECL + '<Relationships %s>'
        '<Relationship Id="rId1" Type="%s/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '</Relationships>' % (_RELS_NS, OFF_REL),
        "ppt/theme/theme1.xml": XML_DECL + theme,
        "docProps/core.xml": _core_xml(title),
    }


@action(
    "create",
    "docx/xlsx/pptx",
    "Create a new empty document at `path` (format comes from the extension). "
    "If you have an existing file to start from, prefer copy_to — it keeps that "
    "file's styles, layouts and theme.",
    {"title": "(string, optional) document title stored in the file properties",
     "sheet": "(string, optional) xlsx only: name of the first sheet (default Sheet1)",
     "overwrite": "(boolean, optional) true to replace an existing file (default false)"},
)
def _act_create(path, fmt, zf, args):
    if fmt not in ("docx", "xlsx", "pptx"):
        raise ToolError("Creating %s files is not supported (docx/xlsx/pptx only)." % fmt)
    if os.path.exists(path) and not args.get("overwrite"):
        raise ToolError(
            "%s already exists (pass overwrite=true to replace it)." % path
        )
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)

    title = str(args.get("title") or os.path.splitext(os.path.basename(path))[0])
    if fmt == "docx":
        parts = _docx_template(title)
    elif fmt == "xlsx":
        parts = _xlsx_template(title, str(args.get("sheet") or "Sheet1"))
    else:
        parts = _pptx_template(title)

    tmp_fd, tmp_path = tempfile.mkstemp(dir=parent or ".", suffix=".tmp")
    os.close(tmp_fd)
    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as out:
            # [Content_Types].xml 이 첫 항목이어야 한다(패키지 규약).
            out.writestr("[Content_Types].xml", parts.pop("[Content_Types].xml"))
            for name, data in parts.items():
                out.writestr(name, data)
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return {"created": path, "format": fmt, "size": os.path.getsize(path)}


# 대상 파일이 아직 없는 상태로 부르는 액션들(디스패처가 zip 을 열지 않는다).
_CREATE_ACTIONS = ("create",)


# --- 복사본 만들기 -----------------------------------------------------------

@action(
    "copy_to",
    "docx/xlsx/pptx/odf",
    "Copy this document to a new path and keep working on the copy. Templates, "
    "masters, layouts, themes and styles all come along — this is the reliable "
    "way to start a new document from an existing one.",
    {"to": "(string) destination path (inside the workspace; parent folders are created)",
     "overwrite": "(boolean, optional) true to replace an existing file (default false)"},
)
def _act_copy_to(path, fmt, zf, args):
    dest = _resolve(_need(args, "to", str))
    if os.path.isdir(dest):
        raise ToolError("'to' is a directory: %s" % dest)
    if os.path.exists(dest) and not args.get("overwrite"):
        raise ToolError(
            "%s already exists (pass overwrite=true to replace it)." % dest
        )
    parent = os.path.dirname(dest)
    if parent and not os.path.isdir(parent):
        os.makedirs(parent, exist_ok=True)
    # zf 는 열려 있는 원본 — 내용은 그대로 복사한다(파트를 다시 쓰지 않는다).
    shutil.copy2(path, dest)
    return {"copied_to": dest, "format": _format_of(dest)}


# --- pptx: slides -----------------------------------------------------------

PRES_PART = "ppt/presentation.xml"
PRES_RELS = "ppt/_rels/presentation.xml.rels"


@action(
    "add_slide",
    "pptx",
    "Add a slide by duplicating an existing one (keeps its layout and styling); "
    "then edit its texts with edit_document.",
    {"copy_of": "(int, optional) 1-based slide to duplicate (default: the last one)"},
)
def _act_add_slide(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    if not parts:
        raise ToolError("The deck has no slides to copy.")
    src_no = args.get("copy_of") or len(parts)
    if not isinstance(src_no, int) or src_no < 1 or src_no > len(parts):
        raise ToolError("No slide %s (the deck has %d)." % (src_no, len(parts)))
    src_part = parts[src_no - 1]

    used = {int(re.search(r"slide(\d+)\.xml$", n).group(1)) for n in parts}
    new_no = max(used) + 1
    new_part = "ppt/slides/slide%d.xml" % new_no

    additions = {new_part: zf.read(src_part)}
    src_rels = "ppt/slides/_rels/%s.rels" % os.path.basename(src_part)
    if src_rels in zf.namelist():
        additions["ppt/slides/_rels/slide%d.xml.rels" % new_no] = zf.read(src_rels)

    # presentation rels: point a new rId at the new part
    rels_xml = _read_part(zf, PRES_RELS)
    if rels_xml is None:
        raise ToolError("Malformed deck (missing %s)." % PRES_RELS)
    rels_root = _parse(rels_xml, PRES_RELS)
    rel_id = _next_rel_id(rels_root)
    rel = ET.SubElement(rels_root, "{%s}Relationship" % PKG_REL)
    rel.set("Id", rel_id)
    rel.set("Type", "%s/slide" % OFF_REL)
    rel.set("Target", "slides/slide%d.xml" % new_no)

    # presentation.xml: append to the slide id list
    pres_xml = _read_part(zf, PRES_PART)
    if pres_xml is None:
        raise ToolError("Malformed deck (missing %s)." % PRES_PART)
    pres_root = _parse(pres_xml, PRES_PART)
    lst = pres_root.find("{%s}sldIdLst" % PML)
    if lst is None:
        lst = ET.SubElement(pres_root, "{%s}sldIdLst" % PML)
    ids = [int(s.get("id") or 0) for s in lst]
    sld = ET.SubElement(lst, "{%s}sldId" % PML)
    sld.set("id", str(max(ids + [255]) + 1))   # slide ids start at 256
    sld.set("{%s}id" % OFF_REL, rel_id)

    parts_out = {PRES_RELS: _serialize(rels_root), PRES_PART: _serialize(pres_root)}
    ct = _content_types_with_slide(zf, new_part)
    if ct:
        parts_out["[Content_Types].xml"] = ct
    return {"slide": len(parts) + 1, "part": new_part,
            "parts": parts_out, "additions": additions}


def _content_types_with_slide(zf, part_name, remove=False):
    """Add/remove the Override entry for a slide part. None when nothing changed."""
    ct_part = "[Content_Types].xml"
    xml = _read_part(zf, ct_part)
    if xml is None:
        return None
    ns = "http://schemas.openxmlformats.org/package/2006/content-types"
    root = _parse(xml, ct_part)
    name = "/" + part_name
    found = [o for o in root.iter("{%s}Override" % ns) if o.get("PartName") == name]
    if remove:
        if not found:
            return None
        for o in found:
            root.remove(o)
        return _serialize(root)
    if found:
        return None
    o = ET.SubElement(root, "{%s}Override" % ns)
    o.set("PartName", name)
    o.set("ContentType",
          "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
    return _serialize(root)


@action(
    "delete_slide",
    "pptx",
    "Delete a slide (1-based).",
    {"slide": "(int) 1-based slide number"},
)
def _act_delete_slide(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    no = _need(args, "slide", int)
    if no < 1 or no > len(parts):
        raise ToolError("No slide %d (the deck has %d)." % (no, len(parts)))
    part = parts[no - 1]
    target = "slides/" + os.path.basename(part)

    rels_root = _parse(_read_part(zf, PRES_RELS) or "", PRES_RELS)
    rel_id = None
    for rel in list(rels_root):
        if (rel.get("Target") or "").replace("\\", "/").endswith(target):
            rel_id = rel.get("Id")
            rels_root.remove(rel)
    pres_root = _parse(_read_part(zf, PRES_PART) or "", PRES_PART)
    lst = pres_root.find("{%s}sldIdLst" % PML)
    if lst is not None and rel_id:
        for sld in list(lst):
            if sld.get("{%s}id" % OFF_REL) == rel_id:
                lst.remove(sld)

    removals = [part]
    rels_part = "ppt/slides/_rels/%s.rels" % os.path.basename(part)
    if rels_part in zf.namelist():
        removals.append(rels_part)
    parts_out = {PRES_RELS: _serialize(rels_root), PRES_PART: _serialize(pres_root)}
    ct = _content_types_with_slide(zf, part, remove=True)
    if ct:
        parts_out["[Content_Types].xml"] = ct
    return {"deleted": no, "parts": parts_out, "removals": removals}


# --- pptx: shapes (위치/크기/추가/삭제) ---------------------------------------

def _p(tag):
    return "{%s}%s" % (PML, tag)


SHAPE_TAGS = ("sp", "pic", "graphicFrame", "grpSp", "cxnSp")


def _shape_tree(root):
    csld = root.find(_p("cSld"))
    return csld.find(_p("spTree")) if csld is not None else None


def _pptx_shapes(root):
    """슬라이드의 최상위 셰이프들(문서 순서 = 인덱스)."""
    tree = _shape_tree(root)
    if tree is None:
        return []
    return [el for el in list(tree) if el.tag.split("}")[-1] in SHAPE_TAGS]


def _shape_name(el):
    for node in el.iter():
        if node.tag.endswith("}cNvPr"):
            return node.get("name") or ""
    return ""


def _shape_ph(el):
    """자리표시자 표시(`p:ph`). 자리표시자가 아니면 None."""
    for node in el.iter(_p("ph")):
        return node
    return None


# graphicFrame 안에 무엇이 들어 있는지는 graphicData 의 uri 로 갈린다.
_GRAPHIC_KINDS = {
    "http://schemas.openxmlformats.org/drawingml/2006/table": "table",
    "http://schemas.openxmlformats.org/drawingml/2006/chart": "chart",
    "http://schemas.openxmlformats.org/drawingml/2006/diagram": "diagram",
}


def _shape_type(el):
    """셰이프 종류를 사람이 쓰는 말로 돌려준다 — `(type, extra_fields)`.

    XML 태그(`kind`)만으로는 부족하다: **텍스트박스·도형·자리표시자가 모두 `sp`**
    라서 "타원을 옮겨라" 같은 요청에서 어느 인덱스가 무엇인지 알 수 없었다.
    (그래서 모델이 python-pptx 로 스크립트를 짜곤 했다 — §2026-08-18 로그.)
    """
    tag = el.tag.split("}")[-1]
    if tag == "pic":
        return "picture", {}
    if tag == "grpSp":
        return "group", {}
    if tag == "cxnSp":
        return "connector", {}
    if tag == "graphicFrame":
        for data in el.iter(_a("graphicData")):
            return _GRAPHIC_KINDS.get(data.get("uri") or "", "object"), {}
        return "object", {}

    # sp: 자리표시자 > 텍스트박스 > 일반 도형 순으로 본다.
    extra = {}
    geom = None
    for node in el.iter(_a("prstGeom")):
        geom = node.get("prst")
        break
    if geom:
        extra["geometry"] = geom      # ellipse / rect / roundRect …
    ph = _shape_ph(el)
    if ph is not None:
        extra["ph_type"] = ph.get("type") or "body"
        if ph.get("idx"):
            extra["ph_idx"] = ph.get("idx")
        return "placeholder", extra
    for node in el.iter(_p("cNvSpPr")):
        if node.get("txBox") == "1":
            return "textbox", extra
        break
    return "autoshape", extra


# --- 자리표시자의 상속 위치 ---------------------------------------------------
#
# 자리표시자는 슬라이드 XML 에 `a:xfrm` 이 없는 경우가 많다. 위치·크기를
# **레이아웃 → 마스터**에서 물려받기 때문이다. 그 상속을 따라가지 않으면
# list_shapes 가 제목·본문의 위치를 통째로 비워서 준다.

def _resolve_part(base_dir, target):
    """rels 의 상대 Target(`../slideLayouts/x.xml`)을 패키지 경로로 편다."""
    if target.startswith("/"):
        return target[1:]
    out = []
    for piece in (base_dir + "/" + target).replace("\\", "/").split("/"):
        if piece in ("", "."):
            continue
        if piece == "..":
            if out:
                out.pop()
        else:
            out.append(piece)
    return "/".join(out)


def _rels_of(zf, part):
    """`part` 의 관계 목록 → [(type, 대상 파트 경로)]. 외부 링크는 뺀다."""
    base_dir, _, base_name = part.rpartition("/")
    rels_name = "%s/_rels/%s.rels" % (base_dir, base_name)
    xml = _read_part(zf, rels_name)
    if xml is None:
        return []
    root = _parse(xml, rels_name)
    out = []
    for rel in root.iter("{%s}Relationship" % PKG_REL):
        if rel.get("TargetMode") == "External":
            continue
        out.append((rel.get("Type") or "",
                    _resolve_part(base_dir, rel.get("Target") or "")))
    return out


def _related_part(zf, part, suffix):
    for rel_type, target in _rels_of(zf, part):
        if rel_type.endswith(suffix):
            return target
    return None


# ctrTitle/title, subTitle/body 는 레이아웃에서 서로 대응된다.
_PH_ALIASES = {"ctrTitle": "title", "subTitle": "body"}


def _ph_key(ph):
    kind = ph.get("type") or "body"
    return _PH_ALIASES.get(kind, kind), ph.get("idx")


def _inherited_box(zf, slide_part, ph):
    """레이아웃 → 마스터를 따라가며 같은 자리표시자의 위치를 찾는다.

    idx 가 있으면 idx 로, 없으면 종류(title/body/…)로 맞춘다 — PowerPoint 의
    규칙을 실용적인 수준으로 옮긴 것이다. 못 찾으면 빈 dict.
    """
    want_type, want_idx = _ph_key(ph)
    part = _related_part(zf, slide_part, "/slideLayout")
    for _ in range(2):          # 레이아웃 → 마스터, 두 단계면 충분하다
        if not part:
            return {}
        xml = _read_part(zf, part)
        if xml is None:
            return {}
        root = _parse(xml, part)
        for el in _pptx_shapes(root):
            other = _shape_ph(el)
            if other is None:
                continue
            o_type, o_idx = _ph_key(other)
            same = (o_idx == want_idx) if want_idx else (o_type == want_type)
            if same:
                box = _shape_box(el)
                if box:
                    return box
        part = _related_part(zf, part, "/slideMaster")
    return {}


def _shape_text(el):
    return "".join(t.text or "" for t in el.iter(_a("t")))


def _shape_xfrm(el, create=False):
    """위치/크기를 담은 xfrm. graphicFrame 은 `p:xfrm`, 나머지는 `a:xfrm` 을 쓴다."""
    for node in el.iter():
        if node.tag in (_a("xfrm"), _p("xfrm")):
            return node
    if not create:
        return None
    spPr = None
    for node in el.iter():
        if node.tag in (_p("spPr"), _a("spPr")):
            spPr = node
            break
    if spPr is None:
        spPr = ET.SubElement(el, _p("spPr"))
    # xfrm 은 spPr 의 첫 자식이어야 한다(prstGeom 보다 앞).
    xfrm = ET.Element(_a("xfrm"))
    spPr.insert(0, xfrm)
    return xfrm


def _emu(value_cm):
    try:
        return int(round(float(value_cm) * EMU_PER_CM))
    except (TypeError, ValueError):
        raise ToolError("Position/size values must be numbers (in cm).")


def _cm(emu):
    try:
        return round(int(emu) / EMU_PER_CM, 2)
    except (TypeError, ValueError):
        return None


def _shape_box(el):
    xfrm = _shape_xfrm(el)
    if xfrm is None:
        return {}
    off = xfrm.find(_a("off"))
    ext = xfrm.find(_a("ext"))
    box = {}
    if off is not None:
        box["x_cm"] = _cm(off.get("x") or 0)
        box["y_cm"] = _cm(off.get("y") or 0)
    if ext is not None:
        box["width_cm"] = _cm(ext.get("cx") or 0)
        box["height_cm"] = _cm(ext.get("cy") or 0)
    return box


@action(
    "list_shapes",
    "pptx",
    "List the shapes of a slide: index, type (textbox/placeholder/autoshape/"
    "picture/table/chart/group/connector), name, text and position/size in cm. "
    "Placeholders usually inherit their position from the layout; it is resolved "
    "and marked with position_inherited. Use the index with set_shape_position / "
    "delete_shape.",
    {"slide": "(int) 1-based slide number"},
)
def _act_list_shapes(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    no = _need(args, "slide", int)
    if no < 1 or no > len(parts):
        raise ToolError("No slide %d (the deck has %d)." % (no, len(parts)))
    part = parts[no - 1]
    root = _parse(_read_part(zf, part), part)
    shapes = []
    for i, el in enumerate(_pptx_shapes(root)):
        kind, extra = _shape_type(el)
        item = {
            "shape": i,
            "type": kind,
            "kind": el.tag.split("}")[-1],   # XML 태그(하위 호환)
            "name": _shape_name(el),
            "text": _shape_text(el)[:120],
        }
        item.update(extra)
        box = _shape_box(el)
        if not box:
            # 슬라이드에 위치가 없는 자리표시자 → 레이아웃/마스터에서 물려받는다.
            ph = _shape_ph(el)
            if ph is not None:
                box = _inherited_box(zf, part, ph)
                if box:
                    box["position_inherited"] = True
        item.update(box)
        shapes.append(item)
    return {"slide": no, "shapes": shapes}


@action(
    "set_shape_position",
    "pptx",
    "Move and/or resize a shape (centimetres from the top-left of the slide). "
    "Omit a value to leave it unchanged. See action=list_shapes for indexes. "
    "Moving a placeholder writes an explicit position on the slide, which "
    "overrides the one inherited from the layout.",
    {"slide": "(int) 1-based slide number",
     "shape": "(int) 0-based shape index from list_shapes",
     "x_cm": "(number, optional) distance from the left edge, cm",
     "y_cm": "(number, optional) distance from the top edge, cm",
     "width_cm": "(number, optional) width in cm",
     "height_cm": "(number, optional) height in cm"},
)
def _act_set_shape_position(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    no = _need(args, "slide", int)
    idx = _need(args, "shape", int)
    if no < 1 or no > len(parts):
        raise ToolError("No slide %d (the deck has %d)." % (no, len(parts)))
    part = parts[no - 1]
    root = _parse(_read_part(zf, part), part)
    shapes = _pptx_shapes(root)
    if idx < 0 or idx >= len(shapes):
        raise ToolError("No shape %d on slide %d (it has %d)."
                        % (idx, no, len(shapes)))
    xfrm = _shape_xfrm(shapes[idx], create=True)
    off = xfrm.find(_a("off"))
    if off is None:
        off = ET.Element(_a("off"))
        off.set("x", "0")
        off.set("y", "0")
        xfrm.insert(0, off)
    ext = xfrm.find(_a("ext"))
    if ext is None:
        ext = ET.SubElement(xfrm, _a("ext"))
        ext.set("cx", "0")
        ext.set("cy", "0")
    if args.get("x_cm") is not None:
        off.set("x", str(_emu(args["x_cm"])))
    if args.get("y_cm") is not None:
        off.set("y", str(_emu(args["y_cm"])))
    if args.get("width_cm") is not None:
        ext.set("cx", str(_emu(args["width_cm"])))
    if args.get("height_cm") is not None:
        ext.set("cy", str(_emu(args["height_cm"])))
    return {"slide": no, "shape": idx, "box": _shape_box(shapes[idx]),
            "parts": {part: _serialize(root)}}


@action(
    "add_textbox",
    "pptx",
    "Add a text box to a slide at the given position (cm).",
    {"slide": "(int) 1-based slide number",
     "text": "(string) text to put in the box",
     "x_cm": "(number, optional) distance from the left edge, cm (default 2)",
     "y_cm": "(number, optional) distance from the top edge, cm (default 2)",
     "width_cm": "(number, optional) width in cm (default 10)",
     "height_cm": "(number, optional) height in cm (default 3)",
     "size_pt": "(number, optional) font size in points"},
)
def _act_add_textbox(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    no = _need(args, "slide", int)
    if no < 1 or no > len(parts):
        raise ToolError("No slide %d (the deck has %d)." % (no, len(parts)))
    part = parts[no - 1]
    root = _parse(_read_part(zf, part), part)
    tree = _shape_tree(root)
    if tree is None:
        raise ToolError("Malformed slide (no spTree).")

    # 셰이프 id 는 슬라이드 안에서 유일해야 한다.
    used = []
    for node in root.iter():
        if node.tag.endswith("}cNvPr"):
            try:
                used.append(int(node.get("id") or "0"))
            except ValueError:
                pass
    new_id = (max(used) if used else 1) + 1

    x = _emu(args.get("x_cm", 2))
    y = _emu(args.get("y_cm", 2))
    cx = _emu(args.get("width_cm", 10))
    cy = _emu(args.get("height_cm", 3))
    size = args.get("size_pt")
    rpr = ''
    if size is not None:
        try:
            rpr = ' sz="%d"' % int(float(size) * 100)  # 1/100 pt
        except (TypeError, ValueError):
            raise ToolError("'size_pt' must be a number.")

    xml = (
        '<p:sp xmlns:p="%s" xmlns:a="%s">'
        '<p:nvSpPr><p:cNvPr id="%d" name="TextBox %d"/>'
        '<p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
        '<p:spPr><a:xfrm><a:off x="%d" y="%d"/><a:ext cx="%d" cy="%d"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
        '<p:txBody><a:bodyPr wrap="square"><a:spAutoFit/></a:bodyPr><a:lstStyle/>'
        '<a:p><a:r><a:rPr lang="en-US"%s/><a:t></a:t></a:r></a:p>'
        '</p:txBody></p:sp>'
        % (PML, A, new_id, new_id, x, y, cx, cy, rpr)
    )
    sp = ET.fromstring(xml)
    # 텍스트는 XML 문자열로 끼워 넣지 않는다(이스케이프 문제) — 파싱 후 넣는다.
    for t in sp.iter(_a("t")):
        t.text = str(args.get("text", ""))
    tree.append(sp)
    return {"slide": no, "shape": len(_pptx_shapes(root)) - 1,
            "parts": {part: _serialize(root)}}


@action(
    "delete_shape",
    "pptx",
    "Delete a shape from a slide (see action=list_shapes for indexes).",
    {"slide": "(int) 1-based slide number",
     "shape": "(int) 0-based shape index from list_shapes"},
)
def _act_delete_shape(path, fmt, zf, args):
    _only(fmt, "pptx")
    parts = _slide_parts(zf)
    no = _need(args, "slide", int)
    idx = _need(args, "shape", int)
    if no < 1 or no > len(parts):
        raise ToolError("No slide %d (the deck has %d)." % (no, len(parts)))
    part = parts[no - 1]
    root = _parse(_read_part(zf, part), part)
    shapes = _pptx_shapes(root)
    if idx < 0 or idx >= len(shapes):
        raise ToolError("No shape %d on slide %d (it has %d)."
                        % (idx, no, len(shapes)))
    _shape_tree(root).remove(shapes[idx])
    return {"slide": no, "deleted_shape": idx, "parts": {part: _serialize(root)}}


# --- docx: 문단 서식 / 글자 서식 ----------------------------------------------

TWIPS_PER_CM = 1440 / 2.54  # 1 inch = 1440 twips (1/20 pt) = 2.54cm
ALIGNMENTS = {"left": "left", "center": "center", "right": "right",
              "justify": "both", "both": "both"}


def _ppr(para):
    """`w:pPr` 를 얻는다(없으면 만들어 첫 자식으로 넣는다 — 스키마상 필수 위치)."""
    ppr = para.find(_w("pPr"))
    if ppr is None:
        ppr = ET.Element(_w("pPr"))
        para.insert(0, ppr)
    return ppr


def _sub_or_new(parent, tag, before=None):
    el = parent.find(tag)
    if el is None:
        el = ET.SubElement(parent, tag)
    return el


@action(
    "set_paragraph_format",
    "docx",
    "Set paragraph layout: alignment, named style, spacing and indentation. "
    "Omit a value to leave it unchanged.",
    {"index": "(int) 0-based paragraph index",
     "alignment": "(string, optional) one of: left, center, right, justify",
     "style": "(string, optional) named style (e.g. Quote); use set_heading for headings",
     "space_before_pt": "(number, optional) space above the paragraph, points",
     "space_after_pt": "(number, optional) space below the paragraph, points",
     "indent_cm": "(number, optional) left indent, cm",
     "first_line_cm": "(number, optional) extra indent for the first line, cm"},
)
def _act_set_paragraph_format(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    paras = _docx_paragraphs(root)
    idx = _need(args, "index", int)
    if idx < 0 or idx >= len(paras):
        raise ToolError("No paragraph %d (the document has %d)." % (idx, len(paras)))
    ppr = _ppr(paras[idx])

    align = args.get("alignment")
    if align is not None:
        key = str(align).lower()
        if key not in ALIGNMENTS:
            raise ToolError("'alignment' must be one of: %s"
                            % ", ".join(sorted(ALIGNMENTS)))
        _sub_or_new(ppr, _w("jc")).set(_w("val"), ALIGNMENTS[key])

    style = args.get("style")
    if style is not None:
        _sub_or_new(ppr, _w("pStyle")).set(_w("val"), str(style))

    def _pt_twips(value):
        try:
            return str(int(round(float(value) * 20)))
        except (TypeError, ValueError):
            raise ToolError("Spacing must be a number (points).")

    if args.get("space_before_pt") is not None or args.get("space_after_pt") is not None:
        spacing = _sub_or_new(ppr, _w("spacing"))
        if args.get("space_before_pt") is not None:
            spacing.set(_w("before"), _pt_twips(args["space_before_pt"]))
        if args.get("space_after_pt") is not None:
            spacing.set(_w("after"), _pt_twips(args["space_after_pt"]))

    if args.get("indent_cm") is not None or args.get("first_line_cm") is not None:
        ind = _sub_or_new(ppr, _w("ind"))
        try:
            if args.get("indent_cm") is not None:
                ind.set(_w("left"),
                        str(int(round(float(args["indent_cm"]) * TWIPS_PER_CM))))
            if args.get("first_line_cm") is not None:
                ind.set(_w("firstLine"),
                        str(int(round(float(args["first_line_cm"]) * TWIPS_PER_CM))))
        except (TypeError, ValueError):
            raise ToolError("Indent values must be numbers (cm).")

    return {"paragraph": idx, "parts": {DOC_PART: _serialize(root)}}


@action(
    "set_text_format",
    "docx",
    "Set character formatting for a whole paragraph (bold/italic/underline, "
    "size, colour, font). Omit a value to leave it unchanged.",
    {"index": "(int) 0-based paragraph index",
     "bold": "(boolean, optional) true/false",
     "italic": "(boolean, optional) true/false",
     "underline": "(boolean, optional) true/false",
     "size_pt": "(number, optional) font size in points",
     "color": "(string, optional) hex RGB such as C00000",
     "font": "(string, optional) font name"},
)
def _act_set_text_format(path, fmt, zf, args):
    _only(fmt, "docx")
    root, _ = _docx_read(zf)
    paras = _docx_paragraphs(root)
    idx = _need(args, "index", int)
    if idx < 0 or idx >= len(paras):
        raise ToolError("No paragraph %d (the document has %d)." % (idx, len(paras)))
    para = paras[idx]
    runs = [r for r in para.iter(_w("r"))]
    if not runs:
        raise ToolError("Paragraph %d has no text to format." % idx)

    color = args.get("color")
    if color is not None:
        color = str(color).lstrip("#").upper()
        if not re.fullmatch(r"[0-9A-F]{6}", color):
            raise ToolError("'color' must be a 6-digit hex RGB, e.g. C00000.")

    for run in runs:
        rpr = run.find(_w("rPr"))
        if rpr is None:
            rpr = ET.Element(_w("rPr"))
            run.insert(0, rpr)   # rPr 는 w:r 의 첫 자식이어야 한다
        for key, tag in (("bold", "b"), ("italic", "i")):
            if args.get(key) is not None:
                el = _sub_or_new(rpr, _w(tag))
                el.set(_w("val"), "1" if args[key] else "0")
        if args.get("underline") is not None:
            el = _sub_or_new(rpr, _w("u"))
            el.set(_w("val"), "single" if args["underline"] else "none")
        if args.get("size_pt") is not None:
            try:
                half = str(int(round(float(args["size_pt"]) * 2)))
            except (TypeError, ValueError):
                raise ToolError("'size_pt' must be a number.")
            _sub_or_new(rpr, _w("sz")).set(_w("val"), half)
            _sub_or_new(rpr, _w("szCs")).set(_w("val"), half)
        if color is not None:
            _sub_or_new(rpr, _w("color")).set(_w("val"), color)
        if args.get("font") is not None:
            fonts = _sub_or_new(rpr, _w("rFonts"))
            for attr in ("ascii", "hAnsi", "eastAsia", "cs"):
                fonts.set(_w(attr), str(args["font"]))

    return {"paragraph": idx, "runs": len(runs),
            "parts": {DOC_PART: _serialize(root)}}


# --- xlsx: 열 너비 / 행 높이 --------------------------------------------------

@action(
    "set_column_width",
    "xlsx",
    "Set the width of a column (in characters, like Excel shows it).",
    {"sheet": "(string, optional) sheet name (default: the first sheet)",
     "column": "(string) column letter, e.g. B",
     "width": "(number) width in characters, as Excel shows it"},
)
def _act_set_column_width(path, fmt, zf, args):
    _only(fmt, "xlsx")
    sheets = _sheet_map(zf)
    name = args.get("sheet") or next(iter(sheets))
    part = sheets.get(name)
    if part is None:
        raise ToolError("No such sheet: %s" % name)
    letter = str(_need(args, "column", str)).strip().upper()
    if not re.fullmatch(r"[A-Z]+", letter):
        raise ToolError("'column' must be a column letter, e.g. B.")
    index = _col_index(letter + "1")
    try:
        width = float(_need(args, "width"))
    except (TypeError, ValueError):
        raise ToolError("'width' must be a number.")

    root = _parse(_read_part(zf, part), part)
    cols = root.find(_s("cols"))
    if cols is None:
        cols = ET.Element(_s("cols"))
        # `cols` 는 스키마상 `sheetData` **앞**에 와야 한다.
        data = root.find(_s("sheetData"))
        root.insert(list(root).index(data) if data is not None else len(root), cols)
    target = None
    for col in cols.findall(_s("col")):
        if col.get("min") == str(index) and col.get("max") == str(index):
            target = col
            break
    if target is None:
        target = ET.SubElement(cols, _s("col"))
        target.set("min", str(index))
        target.set("max", str(index))
    target.set("width", ("%g" % width))
    target.set("customWidth", "1")
    return {"sheet": name, "column": letter, "width": width,
            "parts": {part: _serialize(root)}}


@action(
    "set_row_height",
    "xlsx",
    "Set the height of a row (in points).",
    {"sheet": "(string, optional) sheet name (default: the first sheet)",
     "row": "(int) 1-based row number",
     "height": "(number) row height in points"},
)
def _act_set_row_height(path, fmt, zf, args):
    _only(fmt, "xlsx")
    sheets = _sheet_map(zf)
    name = args.get("sheet") or next(iter(sheets))
    part = sheets.get(name)
    if part is None:
        raise ToolError("No such sheet: %s" % name)
    row_no = _need(args, "row", int)
    try:
        height = float(_need(args, "height"))
    except (TypeError, ValueError):
        raise ToolError("'height' must be a number.")

    root = _parse(_read_part(zf, part), part)
    data = root.find(_s("sheetData"))
    if data is None:
        data = ET.SubElement(root, _s("sheetData"))
    target = None
    for row in data.findall(_s("row")):
        if (row.get("r") or "") == str(row_no):
            target = row
            break
    if target is None:
        # 빈 행이라도 높이는 줄 수 있다 — 순서를 지켜 끼운다.
        target = ET.Element(_s("row"))
        target.set("r", str(row_no))
        placed = False
        for row in data.findall(_s("row")):
            try:
                if int(row.get("r") or "0") > row_no:
                    data.insert(list(data).index(row), target)
                    placed = True
                    break
            except ValueError:
                continue
        if not placed:
            data.append(target)
    target.set("ht", ("%g" % height))
    target.set("customHeight", "1")
    return {"sheet": name, "row": row_no, "height": height,
            "parts": {part: _serialize(root)}}


# --- xlsx: rows & bulk cells -------------------------------------------------

def _shift_rows(sheet_root, start, delta):
    """Renumber rows >= start by `delta` (cell refs follow)."""
    for row in sheet_root.iter(_s("row")):
        try:
            num = int(row.get("r") or "0")
        except ValueError:
            continue
        if num < start:
            continue
        row.set("r", str(num + delta))
        for cell in row.iter(_s("c")):
            ref = cell.get("r") or ""
            m = CELL_RE.match(ref)
            if m:
                cell.set("r", "%s%d" % (m.group(1), int(m.group(2)) + delta))


@action(
    "insert_row",
    "xlsx",
    "Insert an empty row, shifting the rows below down. Formulas are NOT rewritten.",
    {"sheet": "(string, optional) sheet name (default: the first sheet)",
     "row": "(int) 1-based row number to insert at",
     "values": "(array of strings, optional) cell texts for the new row, starting at column A"},
)
def _act_insert_row(path, fmt, zf, args):
    _only(fmt, "xlsx")
    sheets = _sheet_map(zf)
    name = args.get("sheet") or next(iter(sheets))
    part = sheets.get(name)
    if part is None:
        raise ToolError("No such sheet: %s" % name)
    at = _need(args, "row", int)
    if at < 1:
        raise ToolError("'row' is 1-based.")
    root = _parse(_read_part(zf, part), part)
    _shift_rows(root, at, 1)
    values = _as_array(args.get("values"), "values")
    if values:
        for i, value in enumerate(values[:MAX_COLS]):
            ref = "%s%d" % (_col_name(i + 1), at)
            _set_cell_text(_find_or_make_cell(root, ref), str(value))
    return {"sheet": name, "row": at, "parts": {part: _serialize(root)}}


@action(
    "delete_row",
    "xlsx",
    "Delete a row, shifting the rows below up. Formulas are NOT rewritten.",
    {"sheet": "(string, optional) sheet name (default: the first sheet)",
     "row": "(int) 1-based row number"},
)
def _act_delete_row(path, fmt, zf, args):
    _only(fmt, "xlsx")
    sheets = _sheet_map(zf)
    name = args.get("sheet") or next(iter(sheets))
    part = sheets.get(name)
    if part is None:
        raise ToolError("No such sheet: %s" % name)
    at = _need(args, "row", int)
    root = _parse(_read_part(zf, part), part)
    data = root.find(_s("sheetData"))
    if data is None:
        raise ToolError("The sheet has no data.")
    for row in list(data.findall(_s("row"))):
        if (row.get("r") or "") == str(at):
            data.remove(row)
    _shift_rows(root, at + 1, -1)
    return {"sheet": name, "deleted_row": at, "parts": {part: _serialize(root)}}


def _col_name(index):
    """1 -> A, 27 -> AA."""
    out = ""
    while index > 0:
        index, rem = divmod(index - 1, 26)
        out = chr(65 + rem) + out
    return out


@action(
    "set_cells",
    "xlsx",
    "Write a rectangular block of values at once (much cheaper than one edit per cell).",
    {"sheet": "(string, optional) sheet name (default: the first sheet)",
     "start": "(string) top-left cell reference, e.g. A1",
     "values": "(array of arrays of strings) values row by row, filled right and down from start"},
)
def _act_set_cells(path, fmt, zf, args):
    _only(fmt, "xlsx")
    sheets = _sheet_map(zf)
    name = args.get("sheet") or next(iter(sheets))
    part = sheets.get(name)
    if part is None:
        raise ToolError("No such sheet: %s" % name)
    start = _need(args, "start", str)
    values = [_as_array(r, "values[]") for r in _as_array(args.get("values"), "values")]
    if not values:
        raise ToolError("'values' must be a non-empty 2D array.")
    row0 = _row_index(start)
    col0 = _col_index(start)
    root = _parse(_read_part(zf, part), part)
    written = 0
    for r, row_values in enumerate(values[:MAX_ROWS]):
        # 각 행은 위에서 _as_array 로 이미 정규화됐다(문자열로 온 행도 파싱 시도).
        for c, value in enumerate(row_values[:MAX_COLS]):
            ref = "%s%d" % (_col_name(col0 + c), row0 + r)
            cell = _find_or_make_cell(root, ref)
            if cell.find(_s("f")) is not None:
                raise ToolError("%s!%s holds a formula; refusing to overwrite it."
                                % (name, ref))
            _set_cell_text(cell, str(value))
            written += 1
    return {"sheet": name, "cells_written": written,
            "parts": {part: _serialize(root)}}


# --- dispatch ---------------------------------------------------------------

def _only(fmt, *allowed):
    if fmt not in allowed:
        raise ToolError(
            "This action supports %s, not %s." % (" / ".join(allowed), fmt)
        )


def _actions_catalog():
    return [
        {"action": a["name"], "formats": a["formats"],
         "summary": a["summary"], "args": a["args"]}
        for a in _ACTIONS.values()
    ]


@tool(
    "document_advanced",
    "Advanced document operations, grouped under one tool to keep the tool list "
    "small. Pick an `action` and pass its arguments in `args`. "
    "Call it with action=\"actions\" first to get the exact arguments of each "
    "action. Available: " + ", ".join(sorted(_ACTIONS)) + ".",
    {
        "type": "object",
        "properties": {
            "path": {
                "type": "string",
                "description": "Document to work on. For action=\"create\" this is "
                               "the file to be created (it must not exist yet).",
            },
            "action": {
                "type": "string",
                "description": "Sub-command to run. Use \"actions\" to get the exact "
                               "arguments of every action before calling one.",
                # enum 을 주면 모델이 없는 액션을 지어내지 않는다.
                "enum": ["actions"] + sorted(_ACTIONS),
            },
            "args": {
                "type": "object",
                "description": "Arguments for the chosen action, as a flat object — "
                               "e.g. {\"slide\": 1, \"shape\": 0, \"x_cm\": 3}. They go "
                               "in HERE, not next to \"path\"/\"action\". Each "
                               "action takes different keys; call action=\"actions\" "
                               "to see them with their types. Omit for actions that "
                               "take none (\"structure\", \"actions\").",
            },
        },
        "required": ["path", "action"],
    },
)
def _tool_document_advanced(args):
    name = args.get("action")
    if not name or name in ("actions", "help", "list"):
        return {"actions": _actions_catalog()}
    entry = _ACTIONS.get(name)
    if entry is None:
        raise ToolError(
            "Unknown action: %s (available: %s)" % (name, ", ".join(sorted(_ACTIONS)))
        )

    path = _resolve(args.get("path"))
    fmt = _format_of(path)
    # 모델이 객체 대신 JSON 문자열을 넘기는 경우가 많아 한 번 파싱해 준다.
    sub_args = _as_object(args.get("args"), "args")
    # 액션 인자를 `args` 에 넣지 않고 **최상위에 평평하게** 보내는 모델이 잦다
    #   {"action": "list_shapes", "path": "a.pptx", "slide": 1}
    # 스키마상 최상위 키는 path/action/args 뿐이고 액션 인자 39개 중 이 셋과
    # 겹치는 이름은 없다 → 남는 키는 액션 인자로 본다(반씩 나눠 보낸 경우도 붙는다).
    # 둘 다 있으면 **명시한 `args` 가 이긴다**.
    extras = {k: v for k, v in args.items() if k not in ("path", "action", "args")}
    flattened = bool(extras)
    if flattened:
        merged = dict(extras)
        merged.update(sub_args)
        sub_args = merged

    # 받아 주기는 하되 **다음엔 제대로 부르도록** 결과에 한 줄 남긴다
    # (조용히 고쳐 주기만 하면 모델은 계속 같은 형태로 부른다).
    def done(result):
        if flattened:
            result["hint"] = (
                "Arguments were sent at the top level (%s) and were accepted as "
                "`args`. Next time put action arguments inside `args`."
                % ", ".join(sorted(extras))
            )
        return result

    # 새로 만드는 액션은 대상 파일이 아직 없다 — 열지 않고 바로 넘긴다.
    if entry["name"] in _CREATE_ACTIONS:
        result = entry["func"](path, fmt, None, sub_args)
        result["action"] = entry["name"]
        result["path"] = path
        return done(result)

    # 원본을 바꾸지 않는 액션은 before/after 비교(전체 텍스트 추출)를 건너뛴다.
    read_only = entry["name"] in ("structure", "list_shapes", "copy_to")
    before = None if read_only else _extract_text(path, fmt)
    zf = _open_zip(path)
    with zf:
        result = entry["func"](path, fmt, zf, sub_args)
    if read_only:
        return done(result)

    parts = result.pop("parts", None) or {}
    additions = result.pop("additions", None)
    removals = result.pop("removals", None)
    if parts or additions or removals:
        _rewrite_zip(path, parts, additions=additions, removals=removals)
        after = _extract_text(path, fmt)
        result["diff"] = _diff(before, after, path)
    result["action"] = name
    result["path"] = path
    return done(result)


# --- entry point ------------------------------------------------------------

def _describe():
    return {
        "module": MODULE_NAME,
        "version": MODULE_VERSION,
        "tools": [t["schema"] for t in _TOOLS.values()],
    }


def _call(tool_name, args):
    entry = _TOOLS.get(tool_name)
    if entry is None:
        return {"ok": False, "error": "Unknown tool: %s" % tool_name}
    try:
        # 인자 전체가 JSON 문자열로 오는 경우(이중 인코딩)도 한 번 받아 준다.
        return {"ok": True, "result": entry["func"](_as_object(args, "arguments"))}
    except ToolError as e:
        return {"ok": False, "error": str(e)}
    except Exception as e:  # noqa: BLE001 - surface any tool error to the LLM
        return {"ok": False, "error": "%s: %s" % (type(e).__name__, e)}


def main(argv):
    if len(argv) < 2 or argv[1] not in ("describe", "call"):
        sys.stderr.write("usage: collabo_docs.py {describe|call <tool>}\n")
        return 2

    if argv[1] == "describe":
        sys.stdout.write(json.dumps(_describe(), ensure_ascii=False))
        return 0

    if len(argv) < 3:
        sys.stdout.write(json.dumps({"ok": False, "error": "Tool name is required."}))
        return 0
    raw = sys.stdin.read()
    try:
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        sys.stdout.write(json.dumps({"ok": False, "error": "Invalid argument JSON: %s" % e}))
        return 0
    sys.stdout.write(json.dumps(_call(argv[2], args), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
