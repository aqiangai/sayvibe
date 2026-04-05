#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SVG="${SOURCE_SVG:-${ROOT_DIR}/assets/logo/ltr-logo.svg}"
ICONSET_DIR="${ICONSET_DIR:-${ROOT_DIR}/ios/SayVibe/Assets.xcassets/AppIcon.appiconset}"

if [[ ! -f "${SOURCE_SVG}" ]]; then
  echo "Logo source not found: ${SOURCE_SVG}" >&2
  exit 1
fi

mkdir -p "${ICONSET_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

qlmanage -t -s 1024 -o "${TMP_DIR}" "${SOURCE_SVG}" >/dev/null 2>&1

BASE_PNG="${TMP_DIR}/$(basename "${SOURCE_SVG}").png"
if [[ ! -f "${BASE_PNG}" ]]; then
  echo "Failed to render png from svg. Please ensure macOS Quick Look can open: ${SOURCE_SVG}" >&2
  exit 1
fi

render_icon() {
  local size="$1"
  local name="$2"
  sips -z "${size}" "${size}" "${BASE_PNG}" --out "${ICONSET_DIR}/${name}" >/dev/null
}

render_icon 40 "icon-20@2x.png"
render_icon 60 "icon-20@3x.png"
render_icon 58 "icon-29@2x.png"
render_icon 87 "icon-29@3x.png"
render_icon 80 "icon-40@2x.png"
render_icon 120 "icon-40@3x.png"
render_icon 120 "icon-60@2x.png"
render_icon 180 "icon-60@3x.png"
render_icon 1024 "icon-1024.png"

cat > "${ICONSET_DIR}/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "icon-20@2x.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "20x20"
    },
    {
      "filename" : "icon-20@3x.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "20x20"
    },
    {
      "filename" : "icon-29@2x.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "29x29"
    },
    {
      "filename" : "icon-29@3x.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "29x29"
    },
    {
      "filename" : "icon-40@2x.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "40x40"
    },
    {
      "filename" : "icon-40@3x.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "40x40"
    },
    {
      "filename" : "icon-60@2x.png",
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60"
    },
    {
      "filename" : "icon-60@3x.png",
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60"
    },
    {
      "filename" : "icon-1024.png",
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "AppIcon generated in: ${ICONSET_DIR}"
