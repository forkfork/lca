#!/usr/bin/env python3
"""Render the real gallery ANSI output as a shareable color contact sheet."""
import re
import sys
import subprocess
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent.parent
activity = '--activity' in sys.argv
expressive = '--expressive' in sys.argv
worlds = '--worlds' in sys.argv
text = subprocess.check_output(['lua5.5', str(root / 'scripts/river-gallery.lua'), '96', '--color'] + (['--activity'] if activity else ['--expressive'] if expressive else ['--worlds'] if worlds else []), text=True)
lines = text.splitlines()
cell_w, cell_h, margin = 11, 22, 32
image = Image.new('RGB', (96 * cell_w + margin * 2, len(lines) * cell_h + margin * 2), '#131820')
draw = ImageDraw.Draw(image)
font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 15)
ansi = re.compile(r'\x1b\[([\d;]*)m')
for row, line in enumerate(lines):
    color = (178, 189, 204)
    column = position = 0
    while position < len(line):
        match = ansi.match(line, position)
        if match:
            values = match.group(1).split(';')
            color = tuple(map(int, values[2:])) if values[:2] == ['38', '2'] else (178, 189, 204)
            position = match.end()
            continue
        char = line[position]
        x, y = margin + column * cell_w, margin + row * cell_h
        code = ord(char) - 0x2800
        if 0 <= code <= 255:
            for bit, (dx, dy) in enumerate(((0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3))):
                if code & (1 << bit):
                    px, py = x + 3 + dx * 5, y + 3 + dy * 5
                    draw.ellipse((px - 0.9, py - 0.9, px + 0.9, py + 0.9), fill=color)
        else:
            draw.text((x, y + 1), char, fill=color, font=font)
        position += 1
        column += 1
out = root / ('docs/previews/river-activity.png' if activity else 'docs/previews/river-expressive.png' if expressive else 'docs/previews/river-worlds.png' if worlds else 'docs/previews/river-gallery.png')
image.save(out)
print(out)
