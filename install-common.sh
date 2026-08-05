# simplecore — shared installer body for the simple* Vim plugin suite.
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

: "${SIMPLECORE_VERIFY:=self-test}"
: "${SIMPLECORE_ROOT:=$(cd -- "$(dirname -- "${BASH_SOURCE[1]}")" && pwd)}"

cd -- "$SIMPLECORE_ROOT"

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

cargo build --manifest-path Cargo.toml --release --locked

# Where the binary landed depends on the user's cargo configuration: a
# build.target in ~/.cargo/config.toml moves it under target/<triple>/release.
# Ask rustc for the host triple and check both, rather than guessing one and
# reporting a build that succeeded as a failure.
host="$(rustc -vV | sed -n 's/^host: //p')"
suffix=""
[[ "$host" == *windows* ]] && suffix=".exe"

source_binary=""
for candidate in \
	"target/release/$SIMPLECORE_BINARY$suffix" \
	"target/$host/release/$SIMPLECORE_BINARY$suffix"; do
	if [ -f "$candidate" ]; then
		source_binary="$candidate"
		break
	fi
done

if [ -z "$source_binary" ]; then
	echo "error: the build succeeded but $SIMPLECORE_BINARY$suffix was not where it was expected." >&2
	echo "       Looked in target/release and target/$host/release." >&2
	echo "       A build.target or build.target-dir in your cargo config can move it." >&2
	exit 1
fi

# ── verify ───────────────────────────────────────────────────────────────────

# Check the daemon before replacing a working one with it.  A binary that
# cannot answer --version is one the plugin will fail to start much later,
# somewhere far less obvious than here.
case "$SIMPLECORE_VERIFY" in
self-test)
	if ! "$source_binary" --self-test >/dev/null; then
		echo "error: the freshly built $SIMPLECORE_BINARY failed its self-test; nothing was installed." >&2
		exit 1
	fi
	;&
version)
	if ! reported_version="$("$source_binary" --version)"; then
		echo "error: the freshly built $SIMPLECORE_BINARY could not report its version; nothing was installed." >&2
		exit 1
	fi
	;;
none) reported_version="" ;;
*)
	echo "install.sh: unknown SIMPLECORE_VERIFY '$SIMPLECORE_VERIFY'" >&2
	exit 1
	;;
esac

# ── install ──────────────────────────────────────────────────────────────────

# Replace atomically.  Writing over the destination in place fails with ETXTBSY
# while Vim still has the old daemon running, and a partial copy would leave a
# corrupt binary behind — mv over the same filesystem cannot.
mkdir -p lib
destination="lib/$SIMPLECORE_BINARY$suffix"
temporary="$(mktemp "lib/.$SIMPLECORE_BINARY.XXXXXX")"
trap 'rm -f -- "$temporary"' EXIT
cp -- "$source_binary" "$temporary"
chmod 0755 -- "$temporary"
mv -f -- "$temporary" "$destination"
trap - EXIT

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
