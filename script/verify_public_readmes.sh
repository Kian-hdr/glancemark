#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fixtures="$PWD/.build/real-readmes"
mkdir -p "$fixtures"

fetch() {
    local label="$1" repo="$2" revision="$3"
    /usr/bin/curl -fsSL --max-time 25 "https://raw.githubusercontent.com/$repo/$revision/README.md" -o "$fixtures/$label.md"
    /usr/bin/curl -fsSL --max-time 25 -H 'Accept: application/vnd.github.html+json' \
        "https://api.github.com/repos/$repo/readme?ref=$revision" -o "$fixtures/$label-rendered.html"
}

fetch iina iina/iina 685a40ee1d4165107182f7236751ad9d5873f267
fetch mermaid mermaid-js/mermaid 49429b28c7fee068334bed4af50eaa2db89a990a
fetch lazygit jesseduffield/lazygit 8290cc9357ad20fe15c04df9c71a60d98e3da1d7

fetch lore Kian-hdr/lore-demo b709fe5f4dd25106caeb0027cdcf499a747b9155
mkdir -p "$fixtures/lore-assets"
for logo in LORE_Logo.svg LORE_Logo_Dark.svg; do
    /usr/bin/curl -fsSL --max-time 25       "https://raw.githubusercontent.com/Kian-hdr/lore-demo/b709fe5f4dd25106caeb0027cdcf499a747b9155/demo/assets/$logo"       -o "$fixtures/lore-assets/$logo"
done
GLANCEMARK_README_FIXTURES="$fixtures" swift test --jobs 4 --filter PublicREADMECompatibilityTests
