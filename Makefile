.PHONY: check fmt clippy test daemon vim-test vim-remote vim-indent vim-core defcompile core-verify

check: core-verify fmt clippy test defcompile vim-core vim-indent vim-test vim-remote

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

# tests/vim_smoke.vim drives the *real* daemon, pinned to target/debug/ts-hl-daemon.
# Nothing else in `check` produces that binary: `cargo test` builds the bin's unit
# tests, not the bin itself, because this crate has no integration test or bench
# that would select the bin target.  Both lib/ and target/ are gitignored, so on a
# clean checkout FindExe() found nothing and every behavioural assertion failed --
# and on a developer's tree it silently fell back to whatever stale daemon was
# lying around in lib/ or target/release/, so the suite tested last month's binary
# against this month's Vim code.  `check` must build what it tests.
daemon:
	cargo build --locked

vim-test: daemon
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# SimpleRemote integration: remote:// buffers ('buftype' acwrite) and the
# User SimpleRemoteBufferRead event, against the same real daemon.  simpleremote
# itself is not on the runtimepath; the test fires the event by hand.
vim-remote: daemon
	vim -Nu NONE -n -i NONE -es -S tests/vim_remote.vim

vim-indent:
	vim -Nu NONE -n -i NONE -es -S tests/haskell_indent.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
#   https://github.com/beamiter/simplecore
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpletreesitter/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one such copy went unnoticed long enough
# for the whole .simplecore directory to go missing before it had a repository
# of its own: .simplecore.manifest pins the sha256 of every vendored file, and
# this target fails the build when a copy no longer matches.
#
#   git clone https://github.com/beamiter/simplecore ../.simplecore
#   ../.simplecore/vendor.sh --check    # suite-wide drift
#   ../.simplecore/vendor.sh            # re-vendor
core-verify:
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
