# Building Virtual Moon Atlas for macOS (Apple Silicon)

This branch (`macos-cocoa-port`) is a native arm64 / Cocoa port of the whole
eight-program VMA suite: `atlun`, `calclun`, `datlun`, `notelun`, `photlun`,
`weblun`, `cclun`, `catlun`. Two scripts take a clean checkout to a
distributable app.

Verified with FPC 3.2.2 + Lazarus 3.6 on macOS 26 (M1 Pro).

## 0. Build workspace

Everything that isn't the source checkout - the fpcupdeluxe toolchain (it
unpacks thousands of files), the extracted base data, and the packaging output
- goes in one **build workspace**, so it stays out of your home dir and out of
the git checkout.

Both scripts prompt for it and default to **`~/vma-build`**. To skip the
prompt, `export VMA_BUILD=~/vma-build` (or any path). Use the same value for
both scripts.

```
~/vma-build/
  fpcupdeluxe/    the toolchain (you install this - step 1)
  basedata/       the downloaded texture/database set (step 3)
  dist/           packaging output, incl. Virtual-Moon-Atlas-arm64.dmg (step 4)
```

## 1. Toolchain

Xcode Command Line Tools:

```
xcode-select --install
```

FPC + Lazarus with the Cocoa widgetset. The no-sudo route is **fpcupdeluxe**
(<https://github.com/LongDirtyAnimAlf/fpcupdeluxe>): install FPC **3.2.2
(stable)** and Lazarus **3.6 (stable)**, with install dir **`~/vma-build/fpcupdeluxe`**.
Homebrew's `fpc` / `lazarus` do not work on current macOS.

> If a future Xcode drops the classic linker, FPC 3.2.2 will not link Cocoa
> code (`ld: malformed method list atom ...`). Move fpcupdeluxe to FPC `fixes`
> (3.2.4) / trunk and Lazarus trunk, rebuild, and drop `-k-ld_classic` from the
> `.lpi` CustomOptions.

For `calclun` / `weblun` runtime TLS: `brew install openssl@3` (the packaging
script bundles it - step 4).

## 2. Build the suite

```
tools/macos/build-suite.sh
```

Asks for the workspace, then: registers the vendored Lazarus packages, builds
`libplan404` and CSPICE, and `lazbuild`s all eight programs. It expects the
toolchain at `<workspace>/fpcupdeluxe/...`; override with `FPC=`, `LB=`, `PCP=`
env vars. Allow 10-20 min the first time (CSPICE is ~2200 C files).

Output binaries (these land in the checkout - that's normal for `lazbuild`):

| program | path |
|---|---|
| atlun (3D globe, main) | `virtualmoon/units/aarch64-darwin-cocoa/atlun` |
| calclun (ephemeris) | `calclun/calclun` |
| datlun (formations DB) | `datlun/units/aarch64-darwin-cocoa/datlun` |
| notelun (notebook) | `notelun/notelun` |
| photlun (photo library) | `photlun/photlun` |
| weblun (data updater) | `weblun/weblun` |
| cclun (launcher / help) | `cclun/cclun` |
| catlun (catalog editor) | `catlun/units/aarch64-darwin-cocoa/catlun` |

Plus `virtualmoon/library/plan404/libplan404.dylib` and
`calclun/cspice/libcspice.dylib`.

## 3. Base data

The ~250 MB texture / database / kernel set is not in git. Fetch it once into
`<workspace>/basedata` - then `package-app.sh` finds it with no extra config:

* **Upstream installer** (needs `wget`: `brew install wget`):

  ```
  bash install_data.sh ~/vma-build/basedata
  ```

  produces `~/vma-build/basedata/share/virtualmoon/...` - the default location
  `package-app.sh` looks in.

* **Debian base-data package** (`virtualmoon-basedata_9.0_all.deb` from the
  SourceForge project files) - extracts to a slightly different path, so point
  `VMA_BASEDATA` at it:

  ```
  mkdir -p ~/vma-build/basedata && cd ~/vma-build/basedata
  ar x /path/to/virtualmoon-basedata_9.0_all.deb
  tar xf data.tar.zst
  export VMA_BASEDATA=~/vma-build/basedata/usr/share/virtualmoon
  ```

`VMA_BASEDATA` (if you set it) must point at the directory that directly
contains `Textures/`, `Database/`, `Encyclopedia/`, ...

## 4. Package

```
tools/macos/package-app.sh
```

Asks for the same workspace, then assembles
`<workspace>/dist/pkg-stage/Virtual Moon Atlas.app` (all eight binaries +
helper dylibs + bundled OpenSSL 3 + one shared `Contents/Resources` data set),
adhoc-signs it, emits the `VMA Menu` (`cclun.app`) Spotlight sidecar, and
writes **`<workspace>/dist/Virtual-Moon-Atlas-arm64.dmg`**.

If `<workspace>/dist/libs/libssl.3.dylib` / `libcrypto.3.dylib` are absent the
script derives them from `brew --prefix openssl@3` - copies the pair, rewrites
their install names to `@loader_path`, re-signs. Drop your own fixed pair in
`<workspace>/dist/libs/` to skip that.

## Distribution

The `.dmg` is **adhoc-signed, not notarized**. First launch on another Mac:
right-click -> *Open*, or

```
xattr -dr com.apple.quarantine "/Applications/Virtual Moon Atlas.app"
```

Install `Virtual Moon Atlas.app` and `VMA Menu` into the **same** folder.

For a real release: sign with a Developer ID certificate and notarize the
`.dmg`; `component/glscene/Source/GLScene.inc` should read
`{.$DEFINE GLS_LOGGING}` (off - its state on this branch; flip it on only for
local diagnostics, it writes `atlun.log`).

## What's what

| file | role |
|---|---|
| `build-suite.sh` | toolchain -> eight binaries + libplan404 + libcspice |
| `package-app.sh` | binaries + base data -> `.app` + `.dmg` (output under the workspace) |
| `vmamenu.c` | compiled arm64 stub the `VMA Menu` sidecar re-`exec()`s `cclun` with (a script there trips Gatekeeper's "install Rosetta" on Rosetta-less Macs) |

Full rationale for every code change is in `PORT_REPORT.md` (attached to Mantis
issue 0002948, <https://www.ap-i.net/mantis/view.php?id=2948>) - or ask there.
