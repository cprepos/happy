"""Text the readAloud tool speaks word for word.

The text is usually the coding agent's latest message, which is markdown. Kokoro reads markup
out loud ("asterisk asterisk", "pipe"), so `strip_markdown` removes the markup and keeps every
word; `clip_for_speech` caps how much one call reads.
"""

from __future__ import annotations

import re

_FENCE_RE = re.compile(r"^\s*(```|~~~)")
_HRULE_RE = re.compile(r"^\s*([-*_])(\s*\1){2,}\s*$")
_HEADING_RE = re.compile(r"^(\s{0,3})#{1,6}\s+")
_QUOTE_RE = re.compile(r"^(\s*)(>\s?)+")
_LIST_RE = re.compile(r"^(\s*)([-*+]|\d{1,3}[.)])\s+")
_TABLE_RULE_RE = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
_IMAGE_RE = re.compile(r"!\[([^\]]*)\]\([^)]*\)")
_LINK_RE = re.compile(r"\[([^\]]+)\]\([^)]*\)")
_STRONG_RE = re.compile(r"\*\*|__")
# single * or _ around words; `_` needs a non-word on both sides so snake_case stays whole
_EM_STAR_RE = re.compile(r"(?<![\w*])\*(?=\S)(.+?)(?<=\S)\*(?![\w*])")
_EM_UNDER_RE = re.compile(r"(?<![\w_])_(?=\S)(.+?)(?<=\S)_(?![\w_])")
_BLANK_RUN_RE = re.compile(r"\n[ \t]*\n(?:[ \t]*\n)+")


def _inline(line: str) -> str:
    line = _IMAGE_RE.sub(r"\1", line)
    line = _LINK_RE.sub(r"\1", line)
    line = line.replace("`", "")
    line = _STRONG_RE.sub("", line)
    line = _EM_STAR_RE.sub(r"\1", line)
    return _EM_UNDER_RE.sub(r"\1", line)


def _table_row(line: str) -> str:
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    return ", ".join(c for c in cells if c)


def strip_markdown(text: str) -> str:
    """`text` without markdown markup; every word stays, and plain prose comes back unchanged.

    Code fences go but the code between them stays (backticks aside, it is read as written);
    links and images keep their label; table rows become comma-separated cells.
    """
    out: list[str] = []
    in_fence = False
    for line in text.split("\n"):
        if _FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            out.append(line.replace("`", ""))
            continue
        if _HRULE_RE.match(line) or ("|" in line and _TABLE_RULE_RE.match(line)):
            continue
        if line.lstrip().startswith("|"):
            line = _table_row(line)
        line = _HEADING_RE.sub(r"\1", line)
        line = _QUOTE_RE.sub(r"\1", line)
        line = _LIST_RE.sub(r"\1", line)
        out.append(_inline(line))
    return _BLANK_RUN_RE.sub("\n\n", "\n".join(out))


# A cut at a sentence end is preferred, unless it would drop more than this share of the cap.
_SENTENCE_CUT_MIN = 0.5
_SENTENCE_END_RE = re.compile(r"[.!?][\"')\]]*(?=\s)")


def clip_for_speech(text: str, max_chars: int) -> str:
    """`text` cut to at most `max_chars`, at the last sentence end or else the last space."""
    if len(text) <= max_chars:
        return text
    window = text[: max_chars + 1]  # a space right at the cap is a clean cut too
    ends = [m.end() for m in _SENTENCE_END_RE.finditer(window) if m.end() <= max_chars]
    if ends and ends[-1] >= max_chars * _SENTENCE_CUT_MIN:
        return text[: ends[-1]]
    space = max(window.rfind(" "), window.rfind("\n"))
    return text[: space if space > 0 else max_chars].rstrip()
