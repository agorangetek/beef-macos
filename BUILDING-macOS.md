# Building Beef on macOS

Beef's official binaries are Windows-only, and the docs' build page is thin. This document gets
`BeefBuild` (the command-line toolchain) building from upstream source on macOS, and explains the two
source patches this repository carries.

Scope: **the CLI toolchain** (`BeefBuild`, `BeefCon`, …). Upstream's GUI IDE is Windows-only and is not
covered here — see [Not included](#not-included).

---

## Verified environment

| | |
|---|---|
| macOS | 27.0, Apple Silicon (arm64) |
| Toolchain | Xcode 26 / Apple clang 21 |
| LLVM | Homebrew `llvm@22` = **22.1.8** |
| Other | cmake 4.1.2, ninja 1.13.2, python3, git |
| Beef | upstream `master` @ `1cd7cf8687d86c447872c32fdf8c7a2ea7b699f1` |

Intel Macs should work too — the patches are architecture-independent — but that combination is
**untested**.

## How this differs from the official docs

The site's [Building from Source](https://www.beeflang.org/docs/getting-start/building/) page says:

> ### Building on Linux and macOS
> **Requirements:** CMake 3.15 or newer · LLVM-18 · Git
> **Build Steps:** Build Beef with bin/build.sh

That page is out of date, and following it literally will not work on a current machine:

| The docs say | Current `master` actually does |
|---|---|
| LLVM-18 | `bin/build.sh` hard-requires **LLVM 22.1**. It checks `if [ "$LLVM_MAJOR_VERSION" = "22" ] && [ "$LLVM_MINOR_VERSION" = "1" ]` and otherwise prints `ERROR: LLVM 22.1 was not detected` and exits. The string "18" does not appear in the script at all. |
| `bin/build.sh` just works | It is upstream's own script and it does work — but on a current Xcode its C++ does not compile until `0001` is applied, and its link step needs the `clang++` handling below. |
| nothing else to know | Upstream's macOS CI does run `bin/build.sh` successfully, because GitHub's runners have the Command Line Tools installed and carried an older libc++ when these commits were current. On a developer machine with Xcode 26 and no CLT, both problems surface. |

The drift is visible in the release notes: 0.43.2 (2022) was "Upgrade to LLVM 13.0.1", the docs page says
LLVM-18, and `master` requires 22.1.

The docs are right about scope, though: *"the CLI tools such as BeefBuild are supported on these
platforms, but the IDE is currently only available for Windows."* That matches what this repository
covers.

## Requirements

- **Xcode** (full or Command Line Tools). *Only full Xcode is known-good* — see
  [troubleshooting](#troubleshooting).
- **Homebrew `llvm@22`**, version **22.1.x exactly**. Beef's `bin/build.sh` checks for this and refuses
  to build otherwise. The language docs' "LLVM-18" is out of date.
  ```bash
  brew install llvm@22
  ```
- `cmake`, `ninja`, `python3`, `git`.
- ~4 GB of disk for the checkout plus build products.

## Quick start

```bash
bash setup-beef-macos.sh
```

That script fetches upstream at the pinned revision, applies the patches, builds Debug + Release +
the bootstrap compiler, runs the corlib test suites, and finally compiles and runs the IPv6 socket test
in `tests/socket_ipv6` as a smoke test.

Expect roughly **10 minutes**, dominated by the C++ compiler build.

## Manual build

If you would rather drive it yourself:

```bash
# 1. Get the source at the revision the patches target
git init Beef && cd Beef
git remote add origin https://github.com/beefytech/Beef.git
git fetch --depth 1 origin 1cd7cf8687d86c447872c32fdf8c7a2ea7b699f1
git checkout -b macos FETCH_HEAD

# 2. Apply the patches
git apply ../patches/0001-libcpp-iterator-conformance.patch
git apply ../patches/0002-corlib-macos-sockets.patch

# 3. Build, with llvm-config visible but clang++ resolving to Apple's
SHIM=$(mktemp -d)
ln -sf "$(brew --prefix llvm@22)/bin/llvm-config" "$SHIM/llvm-config"
PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" bash bin/build.sh

# 4. Use it
cd IDE/dist
./BeefBuild -workspace=<your-workspace> -run
```

`bin/build.sh` is upstream's own script; it builds `jbuild_d` and `jbuild`, bootstraps the compiler via
`BeefBoot`, builds `BeefBuild`, and runs `IDEHelper/Tests` (you should see `Completed 134 of 134 tests`).

A minimal command-line project is three files — see `tests/socket_ipv6/`:

```toml
# BeefSpace.toml
FileVersion = 1
Projects = {Hello = {Path = "."}}
Unlocked = ["corlib"]

[Workspace]
StartupProject = "Hello"
```
```toml
# BeefProj.toml
FileVersion = 1

[Project]
Name = "Hello"
StartupObject = "Hello.Program"
```
```beef
// src/Program.bf
using System;

namespace Hello;

class Program
{
	public static int Main()
	{
		Console.WriteLine("Hello from Beef on macOS!");
		return 0;
	}
}
```

## The two patches

### `0001-libcpp-iterator-conformance.patch`

Adds `operator[]` to the iterators in `BeefySysLib/util/{Array,SizedArray,String}.h`.

**Without it the C++ compiler does not compile at all** on a modern toolchain:

```
/…/c++/v1/__algorithm/sift_down.h:49:46: error: type 'Beefy::ArrayBase<…>::iterator'
      does not provide a subscript operator
```

Modern libc++ implements `std::sort` via `__sift_down`, which requires random-access iterators to
supply `operator[]`. Beef's iterators advertise `std::random_access_iterator_tag` but never implemented
it. Nothing to do with macOS specifically — any current libc++/libstdc++ will hit this.

### `0002-corlib-macos-sockets.patch`

Fixes four independent bugs in `BeefLibs/corlib/src/Net/Socket.bf`. macOS is BSD, and these constants and
struct layouts were written for Windows and Linux:

| Bug | Detail |
|---|---|
| Address-family constants | `AddressFamily.IPv6` and `AF_INET6` were hardcoded to the **Windows** value `23`. macOS needs `30`, Linux `10`. `OpenEx` derives the family from the sockaddr, so macOS called `socket(23, …)` → `EAFNOSUPPORT`. (This also meant **IPv6 was broken on Linux**.) |
| `sockaddr` length byte | BSD prefixes the family with a length field: `struct sockaddr { __uint8_t sa_len; sa_family_t sa_family; }`. Beef wrote an `int16` family at offset 0, so the family landed in the length byte and the kernel read family `0` → `bind()` failed with `EAFNOSUPPORT`. |
| `addrinfo` field order | BSD declares `… ai_addrlen, ai_canonname, ai_addr, ai_next`; glibc puts `ai_addr` first. Beef used the Linux order, so on macOS it read `ai_canonname` (usually NULL) as `ai_addr` and called `connect(NULL, 28)` → **segfault** for any hostname-based connect. |
| Socket option values | `SOL_SOCKET`, `SO_REUSEADDR`, `SO_BROADCAST`, `IPV6_V6ONLY` came from the Linux branch. BSD/macOS uses the same values as Windows (`0xffff`, `0x0004`, `0x0020`, `27`), so `setsockopt(IPPROTO_IPV6, IPV6_V6ONLY, …)` returned `ENOPROTOOPT`. |

All changes sit behind `#if BF_PLATFORM_MACOS || BF_PLATFORM_IOS`, so Windows and Linux layouts are
unchanged.

## Verifying

`tests/socket_ipv6` is a small Beef project that prints the constants it compiled with, tries each way of
binding, and performs a full IPv6 loopback round-trip:

```
compiled constants: AF_INET=2 AF_INET6=30 IPV6_V6ONLY=27

listen variants:
  [PASS] Listen(5557)           [IPv6 any]
  [PASS] ListenLocal(5557)      [127.0.0.1]
  [PASS] Listen(IPv4 any, 5558) [0.0.0.0]

round trip A: explicit sockaddr_in6 + ConnectEx(SockAddr*)
  [PASS] listen / accept / client connect
  [PASS] client received server payload
  [PASS] server received client payload

round trip B: hostname path ConnectEx("::1") via getaddrinfo
  [PASS] listen / accept / client connect
  [PASS] client received server payload
  [PASS] server received client payload

ALL CHECKS PASSED
```

Run it any time with:

```bash
Beef/IDE/dist/BeefBuild -workspace=tests/socket_ipv6 -config=Debug -platform=macOS -run
```

## Troubleshooting

These are the failures actually encountered while bringing this up, in order.

**`ERROR: LLVM 22.1 was not detected`**
`bin/build.sh` requires LLVM **22.1 exactly**. `brew install llvm@22`, and make sure it is not shadowed
by another `llvm-config` earlier on `PATH`.

**`type 'Beefy::ArrayBase<…>::iterator' does not provide a subscript operator`**
`0001` was not applied (or did not apply cleanly).

**`clang++: warning: no such sysroot directory: '/Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk'`
then `ld: library 'c++' not found`**
Beef resolves `clang++` from `PATH` for its link step. Homebrew's clang defaults to a Command Line Tools
SDK path, which does not exist if you have only full Xcode. `SDKROOT` does **not** override it. Keep
Homebrew's `llvm-config` reachable but let `clang++` resolve to Apple's:

```bash
SHIM=$(mktemp -d)
ln -sf "$(brew --prefix llvm@22)/bin/llvm-config" "$SHIM/llvm-config"
PATH="$SHIM:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" bash bin/build.sh
```

Alternatively, install the Command Line Tools (`xcode-select --install`) so that path exists.

**Build succeeds but a program fails to link with `library 'LLVM-22' not found`**
The generated `IDE/dist/IDEHelper_libs.txt` contains `-lLLVM-22`, which only resolves when the LLVM lib
directory is on the search path. Add `-L$(brew --prefix llvm@22)/lib` to that project's link flags.

**`error: no space left on device`**
The checkout plus Debug and Release build trees want roughly 4 GB.

## Keeping up with upstream

The patches target one commit so that builds are reproducible. When you move to newer upstream code:

```bash
git -C Beef fetch --depth 1 origin master
git -C Beef checkout -q -B macos FETCH_HEAD
git -C Beef apply --check ../patches/0001-libcpp-iterator-conformance.patch
```

If a patch no longer applies it is usually because upstream fixed the same thing — `Socket.bf` is the
file to check first, since the platform branches there are actively evolving. Anchor points to look for:

- `public enum AddressFamily` / `public const int AF_INET6`
- `public struct SockAddr`
- `public struct AddrInfo`
- the `#if BF_PLATFORM_WINDOWS` / `#else` block containing `IPV6_V6ONLY`

## Not included

- **The GUI IDE.** Upstream ships it for Windows; there is a Linux build in CI. A macOS build needs more
  work than the CLI toolchain: the darwin platform app is stubbed to a headless backend, corlib has no
  macOS dialog implementation, and `IDEHelper`'s LLDB debugger support is fenced off with
  `if(UNIX AND NOT APPLE)`. It also currently trips a compiler crash (`exit 139`) partway through.
- **Editor integration.** Published separately as
  **[beef-lsp-macos](https://github.com/agorangetek/beef-lsp-macos)** — a macOS build of [MineGame159](https://github.com/MineGame159/Beef)'s
  community language server (branch `lsp`) plus a VS Code extension. It depends on the toolchain this
  repository builds, so build this first.
- **Cross-targets** (iOS/Android/wasm) are untested here.

## Credits and license

Beef is Copyright © 2019 BeefyTech LLC, MIT licensed — see `LICENSE.TXT` and `LICENSES.TXT`, which are
upstream's own files. The patches in this repository are provided under the same license.
