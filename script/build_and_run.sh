#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
xcodegen generate
build=(xcodebuild -project Glancemark.xcodeproj -scheme Glancemark -configuration Debug -derivedDataPath DerivedData -jobs 4)
app="$PWD/DerivedData/Build/Products/Debug/Glancemark.app"
verify_rich_resources() {
  local product source relative destination files
  test -s Sources/GlancemarkCore/Resources/Rich/Renderer.html || return 1
  test -s Sources/GlancemarkCore/Resources/Highlight/Highlighter.html || return 1
  files="$(find Sources/GlancemarkCore/Resources/Rich Sources/GlancemarkCore/Resources/Highlight -type f ! -name .DS_Store)" || return 1
  test -n "$files" || return 1
  for product in "$app" "$app/Contents/PlugIns/GlancemarkQuickLook.appex"; do
    destination="$product/Contents/Resources/Glancemark_GlancemarkCore.bundle/Contents/Resources"
    while IFS= read -r source; do
      relative="${source#Sources/GlancemarkCore/Resources/}"
      cmp -s "$source" "$destination/$relative" || return 1
    done <<< "$files"
  done
}
"${build[@]}" build
if ! verify_rich_resources; then
  echo "Refreshing stale embedded renderer resources with a clean build." >&2
  "${build[@]}" clean build
  verify_rich_resources || { echo "Embedded renderer resources do not match the source." >&2; exit 1; }
fi
case "${1:-run}" in
  --build) ;;
  run) open "$app" ;;
  --verify)
    open "$app"
    sleep 1
    pgrep -x Glancemark
    ;;
  --debug) lldb -- "$app/Contents/MacOS/Glancemark" ;;
  --logs|--telemetry)
    open "$app"
    /usr/bin/log stream --info --style compact --predicate 'process == "Glancemark"'
    ;;
  *) echo "Usage: $0 [--build|--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac
