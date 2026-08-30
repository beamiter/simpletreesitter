# simplecore — shared installer body for the simple* Vim plugin suite.
# shellcheck shell=bash
#
# VENDORED FILE — DO NOT EDIT IN PLACE.
#   The canonical copy lives in the suite's .simplecore/install-common.sh.
#   Edit that and re-run .simplecore/vendor.sh.
#
# Sourced by each plugin's install.sh, which sets before sourcing:
#
#   SIMPLECORE_BINARY          (required) daemon basename, e.g. simplegit-daemon
#   SIMPLECORE_DISPLAY         (required) name for messages, e.g. SimpleGit
#   SIMPLECORE_MIN_RUST_MINOR  (required) MSRV minor version, e.g. 88
#   SIMPLECORE_VERIFY          version | self-test | none  (default: self-test)
#   SIMPLECORE_ROOT            plugin root (default: the caller's directory)
#
# The caller is expected to have run `set -euo pipefail` already.

# ── preconditions ────────────────────────────────────────────────────────────

for _required in SIMPLECORE_BINARY SIMPLECORE_DISPLAY SIMPLECORE_MIN_RUST_MINOR; do
	if [ -z "${!_required:-}" ]; then
		echo "install.sh: $_required is not set" >&2
		exit 1
	fi
done
unset _required

if [[ ! "$SIMPLECORE_BINARY" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "install.sh: SIMPLECORE_BINARY must be a basename" >&2
	exit 1
fi
if [[ ! "$SIMPLECORE_MIN_RUST_MINOR" =~ ^[0-9]+$ ]]; then
	echo "install.sh: SIMPLECORE_MIN_RUST_MINOR must be a non-negative integer" >&2
	exit 1
fi

: "${SIMPLECORE_VERIFY:=self-test}"
: "${SIMPLECORE_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd)}"

case "$SIMPLECORE_VERIFY" in
self-test | version | none) ;;
*)
	echo "install.sh: unknown SIMPLECORE_VERIFY '$SIMPLECORE_VERIFY'" >&2
	exit 1
	;;
esac

cd -- "$SIMPLECORE_ROOT" || exit 1
SIMPLECORE_ROOT="$(pwd -P)"

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
	echo "error: $SIMPLECORE_DISPLAY needs Rust 1.$SIMPLECORE_MIN_RUST_MINOR or newer and Cargo." >&2
	echo "       Install them from https://rustup.rs and run this script again." >&2
	exit 1
fi

# Refuse early rather than let the user read a page of trait-resolution errors
# and conclude the plugin is broken.
rustc_version="$(rustc --version)"
if [[ "$rustc_version" =~ ^rustc[[:space:]]+([0-9]+)\.([0-9]+)\. ]]; then
	rustc_major="${BASH_REMATCH[1]}"
	rustc_minor="${BASH_REMATCH[2]}"
	if ((rustc_major < 1 || (rustc_major == 1 && rustc_minor < SIMPLECORE_MIN_RUST_MINOR))); then
		echo "error: $SIMPLECORE_DISPLAY needs Rust 1.$SIMPLECORE_MIN_RUST_MINOR or newer; found $rustc_version." >&2
		exit 1
	fi
else
	echo "error: could not read a version out of: $rustc_version" >&2
	exit 1
fi

# ── build ────────────────────────────────────────────────────────────────────

# An installer must produce a binary runnable on this machine. Explicit CLI
# values override a user's cross-compilation target and custom target-dir, and
# give us one fresh path instead of an older target/release artifact.
host="$(rustc -vV | sed -n 's/^host: //p')"
if [ -z "$host" ]; then
	echo "error: rustc did not report its host target." >&2
	exit 1
fi
suffix=""
[[ "$host" == *windows* ]] && suffix=".exe"

cargo build \
	--manifest-path Cargo.toml \
	--release \
	--locked \
	--bin "$SIMPLECORE_BINARY" \
	--target "$host" \
	--target-dir "$SIMPLECORE_ROOT/target"

source_binary="target/$host/release/$SIMPLECORE_BINARY$suffix"

if [ ! -f "$source_binary" ] || [ ! -x "$source_binary" ]; then
	echo "error: the build succeeded but $SIMPLECORE_BINARY$suffix was not where it was expected." >&2
	echo "       Expected: $SIMPLECORE_ROOT/$source_binary" >&2
	exit 1
fi

# ── verify ───────────────────────────────────────────────────────────────────

# Check the daemon before replacing a working one with it.  A binary that
# cannot answer --version is one the plugin will fail to start much later,
# somewhere far less obvious than here.
if [ "$SIMPLECORE_VERIFY" = self-test ]; then
	if ! "$source_binary" --self-test >/dev/null; then
		echo "error: the freshly built $SIMPLECORE_BINARY failed its self-test; nothing was installed." >&2
		exit 1
	fi
fi

reported_version=""
if [ "$SIMPLECORE_VERIFY" != none ]; then
	if ! reported_version="$("$source_binary" --version)"; then
		echo "error: the freshly built $SIMPLECORE_BINARY could not report its version; nothing was installed." >&2
		exit 1
	fi
fi

# ── install ──────────────────────────────────────────────────────────────────

# Replace atomically.  Writing over the destination in place fails with ETXTBSY
# while Vim still has the old daemon running, and a partial copy would leave a
# corrupt binary behind — mv over the same filesystem cannot.
if [ -L lib ]; then
	echo "error: $SIMPLECORE_ROOT/lib must not be a symbolic link." >&2
	exit 1
fi
mkdir -p lib
lib_directory="$(cd lib && pwd -P)"
case "$lib_directory" in
"$SIMPLECORE_ROOT"/*) ;;
*)
	echo "error: the install directory resolves outside $SIMPLECORE_ROOT." >&2
	exit 1
	;;
esac
destination="lib/$SIMPLECORE_BINARY$suffix"
if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
	echo "error: $SIMPLECORE_ROOT/$destination must be a regular file or absent." >&2
	exit 1
fi
if ! (
	temporary="$(mktemp "lib/.$SIMPLECORE_BINARY.XXXXXX")"
	trap 'rm -f -- "$temporary"' EXIT
	cp -- "$source_binary" "$temporary"
	# No `--` for chmod: BSD chmod (which is what macOS ships) takes it as a file
	# name and fails. Every path here begins with `lib/`, so there is nothing for
	# the terminator to protect against.
	chmod 0755 "$temporary"
	mv -f -- "$temporary" "$destination"
	trap - EXIT
); then
	echo "error: could not atomically install $SIMPLECORE_BINARY; the old binary is unchanged." >&2
	exit 1
fi

# ── help tags ────────────────────────────────────────────────────────────────

if [ -d doc ]; then
	if command -v vim >/dev/null 2>&1; then
		vim -Nu NONE -n -i NONE -es -c 'helptags doc' -c 'qa!'
	else
		echo "note: Vim is not on PATH; run :helptags $SIMPLECORE_ROOT/doc yourself." >&2
	fi
fi

echo "Installed ${reported_version:-$SIMPLECORE_BINARY} to $SIMPLECORE_ROOT/$destination"
echo "Ensure $SIMPLECORE_ROOT is on Vim's 'runtimepath'."
