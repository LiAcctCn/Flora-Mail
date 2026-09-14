# Application icon

`FloraMail.icns` is the unchanged Main / teal application icon supplied in
`Flora-Mail-macOS-Icons.zip`, at `flora-mail-icon/main/FloraMail.icns`.
The alternate Midnight artwork is not bundled.

Source ZIP SHA-256:
`82206f408e7017ed8bef38440b4558d80d939e183cfed98bbbeeffe49f95268b`

Bundled ICNS SHA-256:
`998c28eff8ee7ebd374763fdaedbf6b1945459054b187efd4a76c13122d95081`

The supplied ICNS contains the ten standard macOS icon representations:
16, 32, 128, 256 and 512 points at 1x and 2x, covering 16 through 1024 pixels.
Its transparency, proportions and artwork are preserved without conversion.

`Scripts/Info.plist` declares `CFBundleIconFile`. Both Debug and Release runs of
`Scripts/build-app.sh` copy the declared resource into the application's
`Contents/Resources` directory before signing. `Scripts/package-release.sh`
includes that complete application in the release archive.

This resource belongs to the application bundle packaging workflow, rather than
a separate SwiftPM resource bundle or asset catalog. Use the packaged `.app`
to see the application icon; a bare `swift run FloraMail` is not an app bundle.
