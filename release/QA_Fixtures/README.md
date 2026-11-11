# Test Glancemark on a clean Mac

This kit contains the exact signed and notarized release candidate. Use an Apple Silicon Mac on the current macOS generation. Record the macOS version, architecture, and candidate hash for each result.

1. In this kit, run `(cd release && shasum -a 256 -c SHA256SUMS.txt)`. Open the DMG and copy Glancemark to Applications. Launch Glancemark once, then quit it. If needed, enable its Quick Look extension under **System Settings → General → Login Items & Extensions**.
2. From this directory, run `./release_macos.sh verify-installed . /Applications/Glancemark.app`. Save the output. If you installed elsewhere, use that actual path. This check uses built-in macOS utilities and does not require Xcode.
3. In Finder, select **Finder_Readme.md** in **Fixtures** and press Space with Glancemark quit. Confirm the centered heading, table alignment, callout, equation without clipping or an opaque rectangle, disclosure, footnote links, and the three offline geometry blocks. While the preview is open, run `./release_macos.sh verify-preview /Applications/Glancemark.app` to record the extension process path. Confirm the actual visible preview separately. Test keyboard navigation and the map and model controls. If Finder limits a control, record the OS and confirm the interaction in Glancemark’s Read view.
4. Open Reading Appearance in Glancemark. Set a recognizable width or theme, quit, and preview the fixture again. Confirm Finder uses the preset. Restore the prior preset. Test Light and Dark and record any OS-specific difference.
5. Duplicate **Source_Roundtrip.md** before testing. Hash the copy, open it in Glancemark, switch between Edit, Read, and Source, then save without editing. Confirm the file hash stays the same. Test a single edit and undo. Use Finder’s per-file **Open with** for the copy to test editor opening without changing your other Markdown files.
6. Record failures and screenshots with the version and hash. Repeat the install, launch, and Finder checks through the public Homebrew cask once it is available.

If you changed a local extension election during the test, restore the previous selection when finished.
