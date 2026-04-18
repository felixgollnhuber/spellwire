Prebuilt `libghostty-vt.a` archives for the pinned `Vendor/ghostty` submodule.

- `iphonesimulator/libghostty-vt.a`: fat simulator archive (`arm64` + `x86_64`)
- `iphoneos/libghostty-vt.a`: device archive (`arm64`)

The Xcode build phase attempts a fresh Zig build first and falls back to these archives if Zig cannot rebuild Ghostty from a cold cache on the local machine.
