#!/bin/sh
cd "$(dirname "$0")" && /Applications/Blender.app/Contents/MacOS/Blender -b --python "$1.py" 2>&1 | grep -E "PARTS|RENDERED|TRIS|Error|Traceback|File |line|EXPORTED|BOUNDS|MANIFEST|OVER|rror"
