#!/usr/bin/env python3
"""Remove only a named generated directory inside a component's build tree."""
import pathlib, shutil, sys
component = pathlib.Path(sys.argv[1]).resolve()
path = pathlib.Path(sys.argv[2])
root = component / "build"
if path.is_symlink() or (path.resolve() != root and root not in path.resolve().parents):
    raise SystemExit("Refusing cleanup outside the component build tree")
if path.exists():
    shutil.rmtree(path)
