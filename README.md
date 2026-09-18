# beef-macos

Build the [Beef programming language](https://www.beeflang.org/) toolchain on macOS.

Upstream publishes Windows binaries only, and its documentation's build instructions are thin. This
repository carries the small set of source patches a modern macOS toolchain needs, plus a script and
instructions that turn a fresh upstream checkout into a working `BeefBuild` in about ten minutes.

```bash
git clone <this repo> && cd beef-macos
bash setup-beef-macos.sh
```

## What's in here

| Path | |
|---|---|
| `BUILDING-macOS.md` | Full instructions, the reasoning behind each patch, and troubleshooting |
| `setup-beef-macos.sh` | Fetches upstream at a pinned revision, patches, builds, verifies |
| `patches/0001-libcpp-iterator-conformance.patch` | Makes Beef's C++ compile with current libc++ |
| `patches/0002-corlib-macos-sockets.patch` | Fixes four socket bugs on BSD/macOS |
| `tests/socket_ipv6/` | Beef project proving the socket fixes (IPv6 listen + connect round-trip) |

## The two patches

**`0001` — libc++ iterator conformance.** Beef's `ArrayBase`/`SizedArrayBase` iterators claim
`std::random_access_iterator_tag` but never implemented `operator[]`, which modern libc++'s `std::sort`
requires. Without this the C++ compiler does not compile on a current Xcode. Not macOS-specific.

**`0002` — macOS sockets.** Four bugs in `corlib`'s `Socket`, all from treating macOS as Linux (or
Windows):

- `AF_INET6` hardcoded to the Windows value `23` (macOS needs `30`, Linux `10`) — this also broke IPv6
  on Linux;
- `sockaddr` missing the BSD `sa_len`/`sin6_len` length byte, so `bind()` saw address family 0;
- `addrinfo` in glibc field order rather than BSD's, which made hostname-based `connect()` segfault;
- Linux socket-option values (`SOL_SOCKET`, `SO_REUSEADDR`, `SO_BROADCAST`, `IPV6_V6ONLY`) on macOS.

Everything platform-specific is behind `#if BF_PLATFORM_MACOS || BF_PLATFORM_IOS`, so Windows and Linux
code paths are unchanged. Total delta against upstream: **4 files, +101 / −4 lines** — no changes to the
compiler itself.

## Verified

macOS 27.0 on Apple Silicon, Xcode 26 / Apple clang 21, Homebrew `llvm@22` 22.1.8, against upstream
`master` at `1cd7cf86`. The build completes, the corlib suites report `134 of 134` tests passing, and
`tests/socket_ipv6` passes every check — including IPv6 connect/accept/send/recv over `::1` via both the
explicit-sockaddr and `getaddrinfo` paths.

Intel Macs should work (the patches are architecture-independent) but are untested.

## Scope

This covers the **command-line toolchain**. Upstream's GUI IDE remains Windows-only and needs
substantially more porting work; see the "Not included" section of `BUILDING-macOS.md`.

## License

Beef is Copyright © 2019 BeefyTech LLC and MIT licensed. `LICENSE.TXT` and `LICENSES.TXT` are upstream's
own files, reproduced here because the patches are derived from that source. The patches are offered
under the same terms.
