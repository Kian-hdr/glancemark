# Glancemark direct distribution and Homebrew

The release owner runs the stages from a clean, identified checkout after the full compatibility and platform checks on the candidate source. The target version, source tag, disk image and cask must describe the same release. Confirm the GitHub source owner and personal tap before publishing.

## Local candidate and Apple notarization

The script makes a clean source copy of the checked-in commit, copies the Swift package lock into the Xcode workspace, and creates an unsigned Release archive. The release target is Apple Silicon on the current macOS generation.

    stage="$PWD/dist/Glancemark_0.1.0_arm64"
    mkdir -p "$PWD/dist"
    script/release_macos.sh archive 0.1.0 1 arm64 "$stage"

Set GLANCEMARK_SIGNING_IDENTITY to the exact installed Developer ID Application identity. Notarization defaults to the saved Apple team API key for the signing team. Set GLANCEMARK_NOTARY_PROFILE to use an existing, authorized Keychain profile instead. Do not put credentials in the checkout or command history. The main app and Quick Look use the team-prefixed app group from their committed Release entitlements. The signer checks that both signing teams and groups agree.

    script/release_macos.sh package "$stage"
    script/release_macos.sh probe-notary "$stage"
    script/release_macos.sh submit "$stage"

The submit step sends the exact Developer ID signed DMG to Apple and records the submission ID. To wait for Apple separately, use notarytool with the ID in the stage's notary_submit.json and the same team authentication. An uncertain submit result needs readback via notarytool info or history before another submission. Keep the receipt and DMG together.

    script/release_macos.sh finalize "$stage"

Finalize checks the saved pre-notary checksum, requires Accepted for the stored submission, saves the notarization log, staples the outer DMG, and verifies its contents. It emits the exact final DMG and SHA256SUMS.txt in the stage's release directory. Keep that directory's bytes unchanged once published. A rejected submission needs diagnosis and a new candidate, and an interrupted finalize should be inspected before running again. [Apple notarization](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## Published download and Homebrew

For local syntax and style checks before publication, generate the draft in an untracked directory. The draft points to the intended release URL and uses the finalized DMG checksum. Use the separate verified cask command after the public download exists.

    mkdir -p "$PWD/.build/cask-preview"
    script/release_macos.sh cask-preview "$stage" GITHUB_OWNER "$PWD/.build/cask-preview/glancemark.rb"
    brew style "$PWD/.build/cask-preview/glancemark.rb"

Publish the verified release tag and exact files under the same versioned GitHub Release. Do not replace a previously published asset with different bytes. After release, the script independently downloads the public versioned URL without credentials and compares its SHA-256 to the final local DMG before creating a cask.

    script/release_macos.sh cask "$stage" GITHUB_OWNER /path/to/tap/Casks/glancemark.rb

Use a personal tap. Check the generated cask with Homebrew style and audit. Install and uninstall the exact cask from that tap in a clean supported account, preserving the installer's normal quarantine behavior. Compare the installed app and extension's version, architecture and code signature with the verified mounted DMG. Reinstall to check that Quick Look recovers. [GitHub release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases) · [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook)

For either install route, compare the installed bundle with the finalized DMG before opening Finder. Use the actual app path on the test Mac. This check does not change the registered preview provider or default editor.

    script/release_macos.sh verify-installed "$stage" /Applications/Glancemark.app

## Release checks and recorded evidence

For a separate clean Mac, export the notarized DMG, its exact checksum, the local installation verifier, and source and Finder fixtures together. The kit can be used without access to the source checkout or Apple credentials.

    script/release_macos.sh qa-kit "$stage" "$PWD/dist/Glancemark_QA"

Run the editor tests from a clean checkout with `swift test --filter GlancemarkEditorTests`. They exercise the native document writer and TextKit operations without installing or registering the app. Use `script/verify_public_readmes.sh` to refresh the pinned GitHub comparison fixtures. On the clean test Mac, confirm the signed app's actual Finder preview, appearance, and open behavior separately.

| Gate | Evidence to capture for the candidate |
| --- | --- |
| Source and package | Clean commit and tag, Swift package pins, final compatibility test output, project-owned icon/README assets and secret scan |
| DMG | Architecture list, version/build, signing team, signed entitlements, Accepted notarization ID, stapling, Gatekeeper and final SHA-256 |
| Current macOS | Test the exact release on an Apple Silicon Mac running the current macOS generation. Install via the downloaded DMG. Verify a real Finder Space preview on a Markdown fixture and app launch. Record any OS extension enabling step and checked default-editor behavior. |
| Cask | Public URL SHA-256 match, audit/style, clean tap installation, Finder Space preview and app launch, uninstall and reinstall without deleting documents |
| README parity | Pinned representative GitHub READMEs and special-case fixtures across appearance, media, source-preserving edits, and Finder Quick Look |

The app uses network access for remote document images and on-demand GitHub video. Confirm the final README discloses this accurately. The source-preserving editor and preview should be described according to demonstrated behavior. Do not represent a debug build, an unsigned archive or an in-progress notarization as a public release.

### Finder limits reproduced on macOS 27.2 (26B123)

| Finder restriction | Verified behavior and fallback |
| --- | --- |
| Finder may grant the preview extension access to the Markdown file without granting access to sibling files. | Quick Look keeps image labels and local link labels. Preparing images in Glancemark and reopening Quick Look rendered the prepared L.O.R.E. logo. |
| The Quick Look sandbox denied the extension’s request to launch Glancemark directly. | The preview explains the local link restriction and directs the reader to Finder’s **Open With → Glancemark** command. In Glancemark, choosing the repository folder grants the app the context required for repository-root links. |
| The Quick Look sandbox denied DNS for the public lazygit attachment on GitHub. | Finder showed the labeled attachment link and **Open With → Glancemark** instructions. The same attachment played inline in Glancemark with native macOS controls. |
