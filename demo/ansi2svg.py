#!/usr/bin/env python3
"""Render ANSI-coloured terminal text (stdin) as a terminal-window SVG (stdout).

    ansi2svg.py [--title TEXT]

Handles the SGR codes cc-hud emits: reset, bold, 30-37/90-97, 38;5;n,
38;2;r;g;b and 48;5;n. Wide glyphs (emoji) take two cells and are placed
cell by cell, so a font with different emoji widths cannot shift the columns.
"""
import html
import re
import sys
import unicodedata

CW, LH, PAD, TOP = 8.4, 20, 18, 44  # cell width, line height, padding, title bar
FG, BG = "#d6d6d6", "#1e1f22"
BASE = {  # Dark-terminal palette (index 0-15)
    0: "#3b3d42", 1: "#e06c75", 2: "#98c379", 3: "#e5c07b", 4: "#61afef",
    5: "#c678dd", 6: "#56b6c2", 7: "#d6d6d6", 8: "#7f848e", 9: "#ff7b85",
    10: "#b5e890", 11: "#ffd68a", 12: "#8cc8ff", 13: "#e3a0f5", 14: "#7fd8e2",
    15: "#f2f2f2",
}


def xterm256(n):
    if n < 16:
        return BASE[n]
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (lv[n // 36], lv[n // 6 % 6], lv[n % 6])
    g = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (g, g, g)


def cells(ch):
    if ch == "️" or unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in "WF" else 1


def parse(line):
    """Yield (text, fg, bg, bold) runs."""
    fg, bg, bold = None, None, False
    for part in re.split(r"(\x1b\[[0-9;]*m)", line):
        m = re.fullmatch(r"\x1b\[([0-9;]*)m", part)
        if not m:
            if part:
                yield part, fg, bg, bold
            continue
        codes = [int(c) if c else 0 for c in m.group(1).split(";")]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                fg, bg, bold = None, None, False
            elif c == 1:
                bold = True
            elif 30 <= c <= 37:
                fg = BASE[c - 30]
            elif 90 <= c <= 97:
                fg = BASE[c - 90 + 8]
            elif c in (38, 48) and i + 1 < len(codes):
                if codes[i + 1] == 5:
                    col, i = xterm256(codes[i + 2]), i + 2
                else:
                    col, i = "#%02x%02x%02x" % tuple(codes[i + 2:i + 5]), i + 4
                if c == 38:
                    fg = col
                else:
                    bg = col
            i += 1


def main():
    title = sys.argv[sys.argv.index("--title") + 1] if "--title" in sys.argv else ""
    lines = sys.stdin.read().rstrip("\n").split("\n")
    out, width = [], 0
    for row, line in enumerate(lines):
        y = TOP + PAD + row * LH
        col = 0
        for text, fg, bg, bold in parse(line):
            # Group narrow chars into one <text>; place each wide char on its own.
            buf, start = "", col
            chars = list(text)
            for k, ch in enumerate(chars + ["\0"]):
                w = cells(ch) if ch != "\0" else -1
                # VS16 asks for emoji presentation: two cells, as in a terminal.
                if w == 1 and k + 1 < len(chars) and chars[k + 1] == "\ufe0f":
                    w = 2
                if ch == "\ufe0f":
                    continue  # drawn with the glyph it modifies
                if w == 2 or ch == "\0":
                    if buf:
                        out.append((start, y, buf, fg, bg, bold, col - start))
                    if w == 2:
                        vs = "\ufe0f" if k + 1 < len(chars) and chars[k + 1] == "\ufe0f" else ""
                        out.append((col, y, ch + vs, fg, bg, bold, 2))
                        col += 2
                    buf, start = "", col
                else:
                    if not buf:
                        start = col
                    buf += ch
                    col += w
            width = max(width, col)
    W = int(PAD * 2 + width * CW)
    H = int(TOP + PAD * 2 + len(lines) * LH - 6)
    svg = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">',
        f'<rect width="{W}" height="{H}" rx="10" fill="{BG}"/>',
        '<circle cx="20" cy="18" r="6" fill="#ff5f57"/><circle cx="40" cy="18" r="6" fill="#febc2e"/>'
        '<circle cx="60" cy="18" r="6" fill="#28c840"/>',
        f'<text x="{W / 2}" y="22" fill="#8b8d93" font-size="12" text-anchor="middle" '
        f'font-family="ui-sans-serif, system-ui, sans-serif">{html.escape(title)}</text>',
        '<g font-family="ui-monospace, SFMono-Regular, Menlo, Consolas, \'DejaVu Sans Mono\', monospace" '
        'font-size="14" xml:space="preserve">',
    ]
    for c, y, text, fg, bg, bold, n in out:
        x = PAD + c * CW
        if bg:
            svg.append(f'<rect x="{x:.1f}" y="{y - 14}" width="{n * CW:.1f}" height="{LH}" fill="{bg}"/>')
        attrs = f'x="{x:.1f}" y="{y}" fill="{fg or FG}"'
        if len(text) > 1:  # pin the run to its cells, whatever the viewer's font
            attrs += f' textLength="{n * CW:.1f}" lengthAdjust="spacing"'
        if bold:
            attrs += ' font-weight="bold"'
        svg.append(f"<text {attrs}>{html.escape(text)}</text>")
    svg.append("</g></svg>")
    print("\n".join(svg))


if __name__ == "__main__":
    main()
