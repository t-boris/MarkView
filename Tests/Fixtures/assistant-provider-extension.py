#!/usr/bin/env python3
"""Local one-shot provider fixture, confined to its test root."""
import json
import os
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent
if not pathlib.Path.cwd().resolve().is_relative_to(root):
    raise SystemExit('refusing to run outside the fixture root')
with (root / 'children.pid').open('a', encoding='ascii') as output:
    output.write(str(os.getpid()) + '\n')
if len(sys.argv) < 2 or sys.argv[1] != '--fake-run':
    raise SystemExit('unexpected fixture arguments')
prompt = sys.stdin.read()
print(json.dumps({'answer': 'echo:' + prompt + '|' + ' '.join(sys.argv[2:]), 'tokens': 7}), flush=True)
