# Real brand marks for every tile that names a vendor (round 3). The SVGs live in ../logos/ with
# their sources in ../logos/SOURCES.md; they are inlined so the mockups stay file:// and offline.
# One tile shape everywhere: a rounded square at the list size (34 pt, r9), the diagram size
# (40 pt, r10), or the header size (52 pt, r13). The mark is drawn in its official color on a white
# tile, or on a brand-tinted tile where the brand's own icon is one (Soniox's blue square) or where a
# second product shares a mark (ChatGPT's black, Claude Code's near-black).
import os
import re

LOGOS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "logos")


def _svg(fname, fill=None):
    s = open(os.path.join(LOGOS, fname)).read()
    s = re.sub(r"<title>.*?</title>", "", s)
    # Strip size and role from the <svg> tag only (the Soniox icon's own rect keeps its size).
    s = re.sub(r"<svg[^>]*>", lambda m: re.sub(r'\s(role|width|height)="[^"]*"', "", m.group(0)), s, count=1)
    s = s.replace("<svg", '<svg aria-hidden="true" focusable="false"', 1)
    if fill:
        s = s.replace("<path", f'<path fill="{fill}"')
    return s.strip()


# key: (file, mark color, tile class). Colors: Simple Icons' brand hex, except OpenAI, whose brand
# page specifies a black or white mark (Simple Icons' last OpenAI hex, #412991, is a retired purple).
BRANDS = {
    "chatgpt": ("openai.svg", "#FFFFFF", "on-black", "ChatGPT"),
    "openai": ("openai.svg", "#000000", "on-white", "OpenAI"),
    "codex": ("openai.svg", "#000000", "on-white", "Codex"),
    "claude": ("claude.svg", "#D97757", "on-white", "Claude"),
    "claudecode": ("claude.svg", "#D97757", "on-ink", "Claude Code"),
    "cursor": ("cursor.svg", "#000000", "on-white", "Cursor"),
    "gemini": ("googlegemini.svg", "#8E75B2", "on-white", "Gemini"),
    "meta": ("meta.svg", "#0467DF", "on-white", "Meta"),
    "icloud": ("icloud.svg", "#3693F3", "on-white", "iCloud Drive"),
    "soniox": ("soniox-icon-blue-white.svg", None, "full", "Soniox"),
}


def brand_tile(key, cls=""):
    f, color, kind, name = BRANDS[key]
    return f'<span class="itile brand {kind} {key} {cls}" aria-hidden="true">{_svg(f, color)}</span>'


def folder_tile(keys, cls=""):
    # A group of apps (the Mac tools): their marks, small, in one tile of the same size.
    # "more" is our own plus glyph: "and others".
    inner = "".join('<span class="mini more"><i data-i="plus"></i></span>' if k == "more" else
                    f'<span class="mini {BRANDS[k][2]}">{_svg(BRANDS[k][0], BRANDS[k][1])}</span>' for k in keys)
    return f'<span class="itile folder n{len(keys)} {cls}" aria-hidden="true">{inner}</span>'


def stack(keys, cls=""):
    return '<span class="stack">' + "".join(brand_tile(k, cls) for k in keys) + "</span>"
