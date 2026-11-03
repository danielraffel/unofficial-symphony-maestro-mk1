#!/usr/bin/env python3
"""Assemble a static Pages artifact locally. Does not deploy or change DNS."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
site = root / 'website'
out = site / 'dist'
out.mkdir(exist_ok=True)
for name in ('index.html', 'gallery.js'):
    shutil.copy2(site / name, out / name)
for source, name in ((site / 'images', 'images'), (root / 'docs/screenshots', 'screenshots')):
    shutil.copytree(source, out / name, dirs_exist_ok=True)
(out / '.nojekyll').touch()
print(out)
