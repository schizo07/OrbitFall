#!/bin/sh
# usage: run_env.sh <script> [model ...]
cd "$(dirname "$0")" && /Applications/Blender.app/Contents/MacOS/Blender -b --python "$1.py" -- "${@:2}" 2>&1 | grep -E "RENDERED|TRIS|Error|Traceback|File |line|EXPORTED"
