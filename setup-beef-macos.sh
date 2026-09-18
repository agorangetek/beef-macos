#!/bin/bash
# ---------------------------------------------------------------------------
# Build Beef on macOS (Apple Silicon tested; Intel should work too).
#
# Fetches upstream Beef at a pinned revision, applies the two patches that a
# modern Xcode/LLVM toolchain requires, builds the toolchain, and then verifies
# it by compiling and running the IPv6 socket test in tests/socket_ipv6.
#
#   Usage:  bash setup-beef-macos.sh
#           BEEF_DIR=~/src/Beef bash setup-beef-macos.sh     # checkout location
#
# See BUILDING-macOS.md for the full explanation and troubleshooting.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BEEF_DIR="${BEEF_DIR:-$REPO_ROOT/Beef}"
PIN="1cd7cf8687d86c447872c32fdf8c7a2ea7b699f1"   # upstream commit these patches target
LLVM_FORMULA="llvm@22"
LLVM_REQUIRED="22.1"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prerequisites
say "checking prerequisites"

command -v git     >/dev/null || fail "git is required"
command -v cmake   >/dev/null || fail "cmake is required:   brew install cmake"
command -v ninja   >/dev/null || fail "ninja is required:   brew install ninja"
command -v python3 >/dev/null || fail "python3 is required (Xcode CLT usually provides it)"
command -v brew    >/dev/null || fail "Homebrew is required to install ${LLVM_FORMULA}"
xcode-select -p    >/dev/null 2>&1 || fail "Xcode or the Command Line Tools are required: xcode-select --install"

LLVM_PREFIX="$(brew --prefix "$LLVM_FORMULA" 2>/dev/null || true)"
[ -n "$LLVM_PREFIX" ] || fail "${LLVM_FORMULA} is not installed. Run: brew install ${LLVM_FORMULA}"

LLVM_VER="$("$LLVM_PREFIX/bin/llvm-config" --version)"
case "$LLVM_VER" in
	"$LLVM_REQUIRED"*) say "found LLVM $LLVM_VER" ;;
	*) fail "Beef master requires LLVM ${LLVM_REQUIRED}.x exactly, but found $LLVM_VER.
       Run: brew install ${LLVM_FORMULA}" ;;
esac

# --------------------------------------------------------------------- checkout
if [ ! -d "$BEEF_DIR/.git" ]; then
	say "fetching upstream Beef at $PIN (shallow)"
	mkdir -p "$BEEF_DIR"
	git -C "$BEEF_DIR" init -q
	git -C "$BEEF_DIR" remote add origin https://github.com/beefytech/Beef.git 2>/dev/null || true
	git -C "$BEEF_DIR" fetch --depth 1 origin "$PIN"
	git -C "$BEEF_DIR" checkout -q -B macos FETCH_HEAD
else
	say "reusing the existing checkout at $BEEF_DIR"
fi

# ----------------------------------------------------------------------- patches
say "applying patches"
for patch in "$REPO_ROOT"/patches/*.patch; do
	if git -C "$BEEF_DIR" apply --check "$patch" 2>/dev/null; then
		git -C "$BEEF_DIR" apply "$patch"
		echo "    applied          $(basename "$patch")"
	elif git -C "$BEEF_DIR" apply --reverse --check "$patch" 2>/dev/null; then
		echo "    already applied  $(basename "$patch")"
	else
		fail "$(basename "$patch") does not apply. Upstream has probably moved past $PIN -
       see the 'Keeping up with upstream' section of BUILDING-macOS.md."
	fi
done

# ------------------------------------------------------------------------- build
say "building (Debug + Release + bootstrap + corlib tests; expect ~10 minutes)"

# Beef's link step resolves 'clang++' from PATH. Homebrew's clang defaults to a
# Command Line Tools SDK path; on a machine with only full Xcode installed that
# path does not exist, and linking fails with:
#     clang++: warning: no such sysroot directory: '.../CommandLineTools/SDKs/...'
#     ld: library 'c++' not found
# SDKROOT does not override it. So we expose llvm-config (which bin/build.sh
# requires) via a shim directory while letting clang++ resolve to Apple's.
SHIM_DIR="$(mktemp -d)"
ln -sf "$LLVM_PREFIX/bin/llvm-config" "$SHIM_DIR/llvm-config"

(
	export PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
	export HOMEBREW_NO_AUTO_UPDATE=1
	cd "$BEEF_DIR/bin"
	bash ./build.sh
)

BEAT="$BEEF_DIR/IDE/dist/BeefBuild"
[ -x "$BEAT" ] || fail "the build finished but $BEAT was not produced"

# ---------------------------------------------------------------------- verify
say "verifying the toolchain with tests/socket_ipv6"
cd "$BEEF_DIR/IDE/dist"
"$BEAT" -workspace="$REPO_ROOT/tests/socket_ipv6" -config=Debug -platform=macOS -clean -verbosity=minimal
"$REPO_ROOT/tests/socket_ipv6/build/Debug_macOS/SockTest/SockTest"

say "done"
echo "    BeefBuild : $BEAT"
echo "    Build any workspace with:"
echo "        cd $BEEF_DIR/IDE/dist && ./BeefBuild -workspace=<project-dir> -run"
