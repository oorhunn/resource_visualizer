#!/bin/sh
# Records the README GIFs from live data into docs/media/. The recorder is compiled only here,
# so it never ships in the app. It busy-loops half the cores for a few seconds to show load.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
build="$root/.build/readme-media"

swift build --package-path "$root" --scratch-path "$build" -Xswiftc -DREADME_MEDIA
"$(swift build --package-path "$root" --scratch-path "$build" --show-bin-path)/ResourceVisualizer" \
    --readme-media "$root/docs/media"
