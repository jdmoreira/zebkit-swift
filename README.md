# zebkit-swift

Swift bindings for [zebkit](https://github.com/ikey4u/zebkit): Chromium as
one embeddable library. For macOS (Apple silicon) and Linux (x86-64).

```swift
import Zebkit

exit(Engine.run(until: {
    let view = try WebView(url: "https://example.com/", width: 1280, height: 800)
    try await view.loadFinished()
    print(try await view.evaluate("document.title", as: String.self))
    try await view.capture().write(to: URL(fileURLWithPath: "page.png"))
}))
```

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/jdmoreira/zebkit-swift", branch: "main"),
],
targets: [
    .executableTarget(name: "app", dependencies: [.product(name: "Zebkit", package: "zebkit-swift")]),
]
```

Then download the engine, once:

```sh
swift run zebkit-engine install
```

## The engine

The engine is not compiled into your program. It is a directory (about
150 MiB) that the program opens at run time. It is looked for in:

1. `$ZEBKIT_DIR`
2. beside the executable (`zebkit/`, or `Contents/Frameworks` of an app bundle)
3. `~/.cache/zebkit`, where `zebkit-engine install` puts it

To ship a program, copy the engine beside it:

```sh
swift run zebkit-engine bundle "$(swift build --show-bin-path)"
```

**macOS:** Chromium's sandbox only works when the engine is beside the
executable or inside the app bundle. So either `bundle` it as above, or
pass `--no-sandbox` while developing.

**Linux:** the engine needs the system libraries Chrome needs (`libnss3`,
`libgbm1`, `libasound2`, ...). Without a display, pass `--headless`.

## API

The engine has one thread: the one that starts it. What needs the running
engine (views, their callbacks, `Engine.quit()`) is isolated to one global
actor, `ZebkitActor`, so the compiler checks the thread. The closures you
give `Engine.run` and the view callbacks already run on it. From anywhere
else, use `await`, `Task { @ZebkitActor in }` or `Engine.post { }`.

One-time results are `async`; events are closure properties
(`view.onTitle = { ... }`).

`Engine.run` owns the loop of the main thread. With a loop of your own,
call `Engine.start()` and then `Engine.pump()` from it. On macOS the
engine's thread is always the main thread. On Linux `Engine.start()` may
be called on any thread, which leaves the main thread free.

| | |
|---|---|
| `Engine`, `WebView`, `WebContext` | Loading, `evaluate`, `capture`, `bind`, windows, settings, permissions, downloads, network filter |
| `Offscreen` | Views without a window: frames and input |
| `URLScheme`, `Script`, `CDP`, `Automation` | Custom schemes, JavaScript without a page, DevTools and Playwright protocols |
| `Application`, `Tray`, `Desktop` | Menus, tray icons, displays, notifications |
| `PDF`, `Drawing`, `ImageCodec`, `DataCompression`, `Cryptography` | Work without a running engine, from any thread |
| `MediaCapture`, `MediaTap`, `MediaTools` | Recording and tapping page media, `ffmpeg` and `ffprobe` |

`import CZebkit` gives the whole C API under its C names. Upstream's
[`docs/API.md`](https://github.com/ikey4u/zebkit/blob/main/docs/API.md)
describes the engine in full.

See `Examples/` for two small programs.

## Status

Written against zebkit 0.4.0 (Chromium 157). Verified on macOS against the
released engine. On Linux the package builds and the engine starts, but
page loads and `Script` are not verified yet: they were only tried in an
emulated x86-64 container, where upstream's own tools fail too.

## Updating zebkit

Upstream is the submodule `Vendor/zebkit`, at a release tag.

```sh
git -C Vendor/zebkit fetch --tags && git -C Vendor/zebkit checkout v<version>
Scripts/generate.py          # regenerates Sources/CZebkit; needs clang and python3
swift run zebkit-engine install && swift build
```

## License

LGPL-2.1-or-later, the same as zebkit (see `LICENSE`). The engine is
loaded at run time and is never linked into your program.
