#!/bin/bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd -P)
app_id=com.kiankonrad.glancemark
preview_id=$app_id.quicklook
profile=${GLANCEMARK_NOTARY_PROFILE:-}
identity=${GLANCEMARK_SIGNING_IDENTITY:-}

die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
  cat <<'HELP'
Usage:
  release_macos.sh archive VERSION BUILD arm64 NEW_STAGE_DIRECTORY
  release_macos.sh inspect-app APP VERSION BUILD arm64
  release_macos.sh package STAGE_DIRECTORY
  release_macos.sh probe-notary STAGE_DIRECTORY
  release_macos.sh submit STAGE_DIRECTORY
  release_macos.sh finalize STAGE_DIRECTORY
  release_macos.sh verify-installed STAGE_DIRECTORY INSTALLED_APP
  release_macos.sh verify-preview INSTALLED_APP
  release_macos.sh qa-kit STAGE_DIRECTORY NEW_KIT_DIRECTORY
  release_macos.sh cask-preview STAGE_DIRECTORY GITHUB_OWNER NEW_CASK_FILE
  release_macos.sh cask STAGE_DIRECTORY GITHUB_OWNER NEW_CASK_FILE

package requires GLANCEMARK_SIGNING_IDENTITY (Developer ID Application).
Notarization uses GLANCEMARK_NOTARY_PROFILE when set, or the saved Apple team API key.
cask-preview writes a local draft. cask requires the public download to match the final DMG.
HELP
}

plist() { /usr/bin/plutil -extract "$2" raw -o - "$1"; }
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
value() { [[ "$(plist "$1" "$2")" == "$3" ]] || die "Unexpected $2 in $1 (expected $3)"; }

validate_version() {
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Expected major.minor.patch version"
  [[ $2 =~ ^[1-9][0-9]*$ ]] || die "Expected positive integer build"
  case "$3" in
    arm64) archs=arm64 ;;
    *) die "Unsupported architecture: $3" ;;
  esac
}

check_app() {
  local app=$1 version=$2 build=$3 arch=$4 bundle file
  validate_version "$version" "$build" "$arch"
  local extension="$app/Contents/PlugIns/GlancemarkQuickLook.appex"
  [[ -d "$extension" ]] || die "Missing embedded Glancemark Quick Look extension"
  value "$app/Contents/Info.plist" CFBundleIdentifier "$app_id"
  value "$extension/Contents/Info.plist" CFBundleIdentifier "$preview_id"
  value "$extension/Contents/Info.plist" NSExtension.NSExtensionPointIdentifier com.apple.quicklook.preview
  value "$extension/Contents/Info.plist" NSExtension.NSExtensionAttributes.QLSupportedContentTypes.0 net.daringfireball.markdown
  for bundle in "$app" "$extension"; do
    file="$bundle/Contents/Info.plist"
    value "$file" CFBundleShortVersionString "$version"
    value "$file" CFBundleVersion "$build"
    value "$file" LSMinimumSystemVersion 27.0
    local actual expected binary
    binary="$bundle/Contents/MacOS/$(plist "$file" CFBundleExecutable)"
    # Use the stock macOS utility so a clean VM does not need Xcode or Command Line Tools.
    actual=$(LC_ALL=C /usr/bin/file -b "$binary" | /usr/bin/awk '/Mach-O 64-bit executable/ && ($NF == "arm64" || $NF == "x86_64") { print $NF }' | LC_ALL=C sort -u | paste -sd ' ' -)
    expected=$(printf '%s\n' "$archs" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)
    [[ "$actual" == "$expected" ]] || die "Unexpected architecture in $binary: $actual"
    printf '%s %s (%s), macOS 27.0+, %s\n' "$(plist "$file" CFBundleIdentifier)" "$version" "$build" "$actual"
  done
}

stage_setup() {
  [[ -d "$1" ]] || die "Release stage does not exist: $1"
  stage=$(cd "$1" && pwd -P)
  for name in version build arch commit; do [[ -s "$stage/$name.txt" ]] || die "Missing $name receipt"; done
  version=$(cat "$stage/version.txt")
  build=$(cat "$stage/build.txt")
  arch=$(cat "$stage/arch.txt")
  commit=$(cat "$stage/commit.txt")
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || die "Invalid source commit receipt"
  validate_version "$version" "$build" "$arch"
  filename="Glancemark_${version}_${arch}.dmg"
  pre_dmg="$stage/pre_notary/$filename"
  final_dmg="$stage/release/$filename"
}

verify_distribution_code() {
  local app=$1 bundle info
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
  for bundle in "$app" "$app/Contents/PlugIns/GlancemarkQuickLook.appex"; do
    info=$(/usr/bin/codesign -dvv "$bundle" 2>&1)
    grep -q '^Authority=Developer ID Application:' <<< "$info" || die "Missing Developer ID Application signature: $bundle"
    grep -Eq '^CodeDirectory.*flags=.*runtime' <<< "$info" || die "Missing Hardened Runtime: $bundle"
    grep -q '^Timestamp=' <<< "$info" || die "Missing secure timestamp: $bundle"
  done
  local outer_team inner_team
  outer_team=$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  inner_team=$(/usr/bin/codesign -dv "$app/Contents/PlugIns/GlancemarkQuickLook.appex" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ -n "$outer_team" && "$outer_team" == "$inner_team" ]] || die "App and preview signing teams differ"
}

notary() {
  if [[ -n "$profile" ]]; then
    /usr/bin/xcrun notarytool "$@" --keychain-profile "$profile"
    return
  fi
  local signed_team
  signed_team=$(/usr/bin/codesign -dv "$stage/dmg_root/Glancemark.app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [[ "$signed_team" =~ ^[A-Z0-9]{10}$ ]] || die "Could not resolve the Developer ID signing team"
  python3 - "$signed_team" "$@" <<'PYTHON'
import json
import os
from pathlib import Path
import stat
import sys

team_id, *command = sys.argv[1:]
registry = Path(os.environ.get("GLANCEMARK_APPLE_TEAM_REGISTRY", "~/.config/apple-dev/teams.json")).expanduser()
try:
    team = json.loads(registry.read_text())["teams"][team_id]
    key = Path(team["privateKey"]).expanduser()
    if not key.is_file() or stat.S_IMODE(key.stat().st_mode) & 0o077:
        raise ValueError()
    authentication = ["--key", str(key), "--key-id", team["keyId"], "--issuer", team["issuerId"]]
except (KeyError, OSError, ValueError):
    sys.exit("No usable saved notary credential for the signed app team. Set an authorized Keychain profile or configure the saved Apple team API key.")
os.execv("/usr/bin/xcrun", ["xcrun", "notarytool", *command, *authentication])
PYTHON
}

verify_dmg() (
  local image=$1 mount
  /usr/bin/hdiutil verify "$image"
  /usr/bin/codesign --verify --strict --verbose=2 "$image"
  /usr/bin/xcrun stapler validate -v "$image"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$image"
  mount=$(mktemp -d "${TMPDIR:-/tmp}/glancemark-dmg.XXXXXX")
  trap '/usr/bin/hdiutil detach "$mount" >/dev/null 2>&1 || true; rmdir "$mount" 2>/dev/null || true' EXIT
  /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$image"
  check_app "$mount/Glancemark.app" "$version" "$build" "$arch"
  verify_distribution_code "$mount/Glancemark.app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$mount/Glancemark.app"
  [[ "$(readlink "$mount/Applications")" == /Applications ]] || die "Missing Applications shortcut"
  /usr/bin/hdiutil detach "$mount"
)

case "${1:-}" in
  -h|--help|help) usage ;;
  archive)
    [[ $# == 5 ]] || die "Usage: release_macos.sh archive VERSION BUILD ARCH NEW_STAGE_DIRECTORY"
    validate_version "$2" "$3" "$4"
    [[ ! -e "$5" && ! -L "$5" ]] || die "Stage path already exists: $5"
    [[ -z "$(git -C "$root" status --porcelain)" ]] || die "Release archives require a clean checkout"
    commit=$(git -C "$root" rev-parse HEAD)
    mkdir -- "$5"
    stage=$(cd "$5" && pwd -P)
    mkdir "$stage/source"
    printf '%s\n' "$2" > "$stage/version.txt"
    printf '%s\n' "$3" > "$stage/build.txt"
    printf '%s\n' "$4" > "$stage/arch.txt"
    printf '%s\n' "$commit" > "$stage/commit.txt"
    /usr/bin/xcodebuild -version > "$stage/xcode.txt"
    git -C "$root" archive --output="$stage/source.tar" "$commit"
    tar -xf "$stage/source.tar" -C "$stage/source"
    rm -- "$stage/source.tar"
    (
      cd "$stage/source"
      xcodegen generate
      lock=Glancemark.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
      mkdir -p "$lock"
      cp Package.resolved "$lock/Package.resolved"
      /usr/bin/xcodebuild archive -project Glancemark.xcodeproj -scheme Glancemark -configuration Release \
        -destination 'generic/platform=macOS' -archivePath "$stage/Glancemark.xcarchive" \
        -derivedDataPath "$stage/DerivedData" -clonedSourcePackagesDirPath "$stage/SourcePackages" \
        -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
        "ARCHS=$archs" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO \
        "MARKETING_VERSION=$2" "CURRENT_PROJECT_VERSION=$3"
      python3 -c 'import json, sys
def pins(path):
    with open(path) as f:
        return {p["identity"]: (p["location"], p["state"]) for p in json.load(f)["pins"]}
if pins(sys.argv[1]) != pins(sys.argv[2]):
    sys.exit("Resolved dependency pins changed during archive")' Package.resolved "$lock/Package.resolved"
    ) 2>&1 | tee "$stage/archive.log"
    check_app "$stage/Glancemark.xcarchive/Products/Applications/Glancemark.app" "$2" "$3" "$4"
    printf 'Unsigned release archive: %s\n' "$stage/Glancemark.xcarchive"
    ;;
  inspect-app)
    [[ $# == 5 ]] || die "Usage: release_macos.sh inspect-app APP VERSION BUILD ARCH"
    check_app "$2" "$3" "$4" "$5"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$2"
    ;;
  package)
    [[ $# == 2 && "$identity" == 'Developer ID Application: '* ]] || die "package requires the Developer ID Application identity name"
    stage_setup "$2"
    [[ ! -e "$stage/pre_notary" && ! -e "$stage/dmg_root" ]] || die "Packaging directory already exists"
    source="$stage/Glancemark.xcarchive/Products/Applications/Glancemark.app"
    check_app "$source" "$version" "$build" "$arch"
    # Current app has one nested executable, the Quick Look extension.
    # Stop if the build adds other nested code that needs an explicit signing order.
    extras=$(find "$source/Contents" \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' -o -name '*.dylib' \) ! -path "$source/Contents/PlugIns/GlancemarkQuickLook.appex" -print)
    [[ -z "$extras" ]] || die "Review signing for additional nested code: $extras"
    app_entitlements="$stage/source/App/Release.entitlements"
    preview_entitlements="$stage/source/QuickLook/Release.entitlements"
    [[ -f "$app_entitlements" && -f "$preview_entitlements" ]] || die "Missing app or Quick Look release entitlements in the archived source"
    /usr/bin/plutil -lint "$app_entitlements" "$preview_entitlements"
    mkdir "$stage/pre_notary" "$stage/dmg_root"
    app="$stage/dmg_root/Glancemark.app"
    /usr/bin/ditto "$source" "$app"
    notices="$app/Contents/Resources/Third_Party_Notices"
    mkdir -p "$notices"
    for file in "$stage/source/release/Notices/"*.txt; do
      [[ -s "$file" ]] || die "Missing third-party notices in the archived source"
      cp "$file" "$notices/"
    done
    [[ -s "$notices/Renderer_Notices.txt" && -s "$notices/Swift_Cmark_COPYING.txt" ]] || die "Incomplete third-party notices"
    cp "$stage/source/LICENSE" "$notices/Glancemark_MIT.txt"
    cp "$stage/source/release/Licenses.md" "$notices/"
    /usr/bin/codesign --force --sign "$identity" --timestamp --options runtime \
      --entitlements "$preview_entitlements" "$app/Contents/PlugIns/GlancemarkQuickLook.appex"
    /usr/bin/codesign --force --sign "$identity" --timestamp --options runtime --entitlements "$app_entitlements" "$app"
    verify_distribution_code "$app"
    /usr/bin/codesign -d --entitlements :- "$app" > "$stage/app_entitlements.plist"
    /usr/bin/codesign -d --entitlements :- "$app/Contents/PlugIns/GlancemarkQuickLook.appex" > "$stage/extension_entitlements.plist"
    team=$(/usr/bin/codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    python3 - "$team" "$app_entitlements" "$stage/app_entitlements.plist" "$preview_entitlements" "$stage/extension_entitlements.plist" <<'PYTHON'
import plistlib
import sys

def plist(path):
    with open(path, "rb") as file:
        return plistlib.load(file)

team, app_source, app_signed, preview_source, preview_signed = sys.argv[1:]
app, preview = plist(app_signed), plist(preview_signed)
if app != plist(app_source) or preview != plist(preview_source):
    sys.exit("Signed entitlements differ from the archived release entitlements")
key = "com.apple.security.application-groups"
groups = app.get(key)
if not groups or groups != preview.get(key) or any(not group.startswith(team + ".") for group in groups):
    sys.exit("App and Quick Look must share a team-prefixed app group")
if not preview.get("com.apple.security.app-sandbox") or not preview.get("com.apple.security.network.client"):
    sys.exit("Quick Look sandbox or network entitlement is missing")
if app.get("com.apple.security.get-task-allow") or preview.get("com.apple.security.get-task-allow"):
    sys.exit("Debug entitlements are not permitted in a release")
PYTHON
    ln -s /Applications "$stage/dmg_root/Applications"
    /usr/bin/hdiutil create -srcfolder "$stage/dmg_root" -volname Glancemark -format UDZO -fs HFS+ "$pre_dmg"
    /usr/bin/codesign --sign "$identity" --timestamp "$pre_dmg"
    /usr/bin/codesign --verify --strict --verbose=2 "$pre_dmg"
    /usr/bin/hdiutil verify "$pre_dmg"
    sha "$pre_dmg" > "$stage/pre_notary.sha256"
    printf 'Signed DMG pending notarization: %s\n' "$pre_dmg"
    ;;
  probe-notary)
    [[ $# == 2 ]] || die "Usage: release_macos.sh probe-notary STAGE_DIRECTORY"
    stage_setup "$2"
    notary history --no-progress --output-format json | python3 -c 'import json,sys; print("Apple accepted notary credentials. History records:",len(json.load(sys.stdin).get("history",[])))'
    ;;
  submit)
    [[ $# == 2 ]] || die "Usage: release_macos.sh submit STAGE_DIRECTORY"
    stage_setup "$2"
    [[ -f "$pre_dmg" && -s "$stage/pre_notary.sha256" && "$(sha "$pre_dmg")" == "$(cat "$stage/pre_notary.sha256")" ]] || die "Signed DMG checksum mismatch"
    [[ ! -e "$stage/notary_submit.json" && ! -L "$stage/notary_submit.json" ]] || die "Existing submission receipt. Reconcile it with notarytool info or history before retrying."
    (set -o noclobber; notary submit "$pre_dmg" --no-wait --output-format json > "$stage/notary_submit.json")
    /usr/bin/plutil -extract id raw -o - "$stage/notary_submit.json"
    ;;
  finalize)
    [[ $# == 2 ]] || die "Usage: release_macos.sh finalize STAGE_DIRECTORY"
    stage_setup "$2"
    [[ -f "$pre_dmg" && -s "$stage/pre_notary.sha256" && "$(sha "$pre_dmg")" == "$(cat "$stage/pre_notary.sha256")" ]] || die "Signed DMG checksum mismatch"
    [[ ! -e "$stage/release" ]] || die "Final artifact directory already exists; inspect previous finalization"
    submission=$(plist "$stage/notary_submit.json" id)
    [[ $submission =~ ^[0-9a-fA-F-]{36}$ ]] || die "Invalid submission ID"
    notary info "$submission" --output-format json > "$stage/notary_info.json"
    value "$stage/notary_info.json" id "$submission"
    value "$stage/notary_info.json" status Accepted
    notary log "$submission" "$stage/notary_log.json"
    mkdir "$stage/release"
    cp "$pre_dmg" "$final_dmg"
    /usr/bin/xcrun stapler staple -v "$final_dmg"
    verify_dmg "$final_dmg" 2>&1 | tee "$stage/verify.log"
    (cd "$stage/release" && /usr/bin/shasum -a 256 "$filename" > SHA256SUMS.txt)
    printf 'Verified final artifact: %s\n' "$final_dmg"
    ;;
  verify-installed)
    [[ $# == 3 && -d "$3" ]] || die "Usage: release_macos.sh verify-installed STAGE_DIRECTORY INSTALLED_APP"
    stage_setup "$2"
    installed=$(cd "$3" && pwd -P)
    [[ -f "$final_dmg" && -s "$stage/release/SHA256SUMS.txt" ]] || die "Missing finalized DMG or checksum"
    (cd "$stage/release" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
    check_app "$installed" "$version" "$build" "$arch"
    verify_distribution_code "$installed"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$installed"
    (
      mount=$(mktemp -d "${TMPDIR:-/tmp}/glancemark-install-check.XXXXXX")
      trap '/usr/bin/hdiutil detach "$mount" >/dev/null 2>&1 || true; rmdir "$mount" 2>/dev/null || true' EXIT
      /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$final_dmg" >/dev/null
      diff -qr "$mount/Glancemark.app" "$installed" || die "Installed app bytes differ from the notarized DMG"
      /usr/bin/hdiutil detach "$mount" >/dev/null
    )
    printf 'Installed bytes match the notarized DMG on macOS %s (%s), %s. Finder runtime checks are separate.\n' \
      "$(/usr/bin/sw_vers -productVersion)" "$(/usr/bin/sw_vers -buildVersion)" "$(uname -m)"
    ;;
  verify-preview)
    [[ $# == 2 && -d "$2" ]] || die "Usage: release_macos.sh verify-preview INSTALLED_APP"
    installed=$(cd "$2" && pwd -P)
    extension="$installed/Contents/PlugIns/GlancemarkQuickLook.appex"
    [[ -d "$extension" ]] || die "Missing embedded Quick Look extension"
    value "$extension/Contents/Info.plist" CFBundleIdentifier "$preview_id"
    binary="$extension/Contents/MacOS/$(plist "$extension/Contents/Info.plist" CFBundleExecutable)"
    found=
    processes=$(/bin/ps -axo pid=,comm=)
    while read -r pid executable; do
      case "$executable" in
        */Glancemark.app/Contents/MacOS/Glancemark) die "Glancemark is still open (PID $pid)" ;;
        "$binary") found="${found:+$found, }$pid" ;;
      esac
    done <<< "$processes"
    [[ -n "$found" ]] || die "No running Quick Look process from the selected app; open the test file in Finder first"
    printf 'Glancemark is quit. Quick Look PID(s) %s match %s (build %s). Confirm the visible fixture separately.\n' \
      "$found" "$binary" "$(plist "$extension/Contents/Info.plist" CFBundleVersion)"
    ;;
  qa-kit)
    [[ $# == 3 && ! -e "$3" && ! -L "$3" ]] || die "Usage: release_macos.sh qa-kit STAGE_DIRECTORY NEW_KIT_DIRECTORY"
    stage_setup "$2"
    [[ -f "$final_dmg" && -s "$stage/release/SHA256SUMS.txt" ]] || die "Missing finalized DMG or checksum"
    (cd "$stage/release" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
    /usr/bin/xcrun stapler validate "$final_dmg"
    /usr/sbin/spctl --assess --type open --context context:primary-signature "$final_dmg"
    mkdir "$3"
    kit=$(cd "$3" && pwd -P)
    mkdir "$kit/release" "$kit/Fixtures"
    for name in version build arch commit; do cp "$stage/$name.txt" "$kit/"; done
    cp "$final_dmg" "$stage/release/SHA256SUMS.txt" "$kit/release/"
    cp "$root/release/QA_Fixtures/README.md" "$kit/README.md"
    cp "$root/release/QA_Fixtures/Finder_Readme.md" "$kit/Fixtures/"
    cp "$root/script/release_macos.sh" "$kit/release_macos.sh"
    # Generate a real UTF-8 BOM and CRLF so Git checkout settings cannot normalize the fixture.
    printf '\357\273\277# Source roundtrip\r\n\r\nKeep trailing spaces  \r\n' > "$kit/Fixtures/Source_Roundtrip.md"
    (cd "$kit/release" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
    printf 'Clean-Mac QA kit: %s\n' "$kit"
    ;;
  cask|cask-preview)
    [[ $# == 4 && $3 =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ && ! -e "$4" && ! -L "$4" ]] || die "Usage: release_macos.sh $1 STAGE_DIRECTORY GITHUB_OWNER NEW_CASK_FILE"
    [[ $(basename "$4") == glancemark.rb ]] || die "Expected a cask named glancemark.rb"
    stage_setup "$2"
    [[ -f "$final_dmg" && -s "$stage/release/SHA256SUMS.txt" ]] || die "Missing finalized DMG or checksum"
    (cd "$stage/release" && /usr/bin/shasum -a 256 -c SHA256SUMS.txt)
    local_sha=$(sha "$final_dmg")
    owner=$3
    if [[ $1 == cask ]]; then
      (
        remote=$(mktemp "${TMPDIR:-/tmp}/glancemark-release.XXXXXX")
        trap 'rm -f -- "$remote"' EXIT
        /usr/bin/curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
          --connect-timeout 15 --max-time 300 \
          "https://github.com/$owner/glancemark/releases/download/v$version/$filename" -o "$remote"
        [[ "$(sha "$remote")" == "$local_sha" ]] || die "Public asset checksum differs from the verified local DMG"
      )
    fi
    (
      set -o noclobber
      {
        printf '# frozen_string_literal: true\n\ncask "glancemark" do\n  version "%s"\n  sha256 "%s"\n\n' "$version" "$local_sha"
        printf '  url "https://github.com/%s/glancemark/releases/download/v#{version}/Glancemark_#{version}_%s.dmg"\n' "$owner" "$arch"
        printf '  name "Glancemark"\n  desc "Markdown editor and Finder Quick Look preview"\n  homepage "https://github.com/%s/glancemark"\n\n' "$owner"
        printf '  depends_on arch: :arm64\n'
        printf '  depends_on macos: :golden_gate\n\n  app "Glancemark.app"\nend\n'
      } > "$4"
    )
    if [[ $1 == cask ]]; then
      printf 'Cask matches the public DMG SHA-256: %s\n' "$local_sha"
    else
      printf 'Local cask draft uses the finalized DMG SHA-256: %s\n' "$local_sha"
    fi
    ;;
  *) usage >&2; exit 2 ;;
esac
