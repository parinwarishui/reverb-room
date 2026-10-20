#!/bin/bash
# Runs the unit tests. The Command Line Tools ship Swift Testing but SwiftPM
# doesn't search their framework folder, so point it there explicitly.
set -euo pipefail
cd "$(dirname "$0")"

DEV=/Library/Developer/CommandLineTools/Library/Developer
FLAGS=()
if [[ -d "$DEV/Frameworks/Testing.framework" ]]; then
  FLAGS=(-Xswiftc -F -Xswiftc "$DEV/Frameworks"
         -Xlinker -F -Xlinker "$DEV/Frameworks"
         -Xlinker -rpath -Xlinker "$DEV/Frameworks"
         -Xlinker -rpath -Xlinker "$DEV/usr/lib")
fi
exec swift test "${FLAGS[@]}" "$@"
