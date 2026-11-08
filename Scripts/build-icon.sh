#!/bin/sh
set -eu
icon_source="${1:-Assets/HiDPI.png}"
icon_dir="build/HiDPI.iconset"
mkdir -p "$icon_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$icon_source" --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o build/HiDPI.icns
