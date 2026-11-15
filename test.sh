#!/bin/bash
# Runs the unit tests. Without full Xcode the Swift Testing macro plugin is
# not located reliably, so its Command Line Tools path is passed explicitly.
set -euo pipefail
cd "$(dirname "$0")"
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [ -d "$PLUGINS" ] && ! xcode-select -p | grep -q Xcode; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
