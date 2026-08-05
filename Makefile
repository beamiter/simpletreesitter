.PHONY: check fmt clippy test vim-test vim-core defcompile core-verify

check: core-verify fmt clippy test defcompile vim-core vim-test

fmt:
	cargo fmt --all -- --check

clippy:
	cargo clippy --all-targets --locked -- -D warnings

test:
	cargo test --locked

vim-test:
	vim -Nu NONE -n -i NONE -es -S tests/vim_smoke.vim

# ---------------------------------------------------------------------------
# simplecore: the vendored daemon supervisor shared by the simple* suite.
# Regenerate with ../.simplecore/vendor.sh; never edit autoload/simpletreesitter/core.vim.
# ---------------------------------------------------------------------------

# The bundle is copied into each plugin rather than shared by reference, so
# that every plugin stays independently installable.  Copies drift silently
# unless something checks them, and one already went unnoticed long enough for
# the .simplecore directory itself to go missing: .simplecore.manifest pins the
# sha256 of every vendored file, and this target fails the build when a copy
# no longer matches.  Run ../.simplecore/vendor.sh --check to see suite-wide
# drift, or ../.simplecore/vendor.sh to re-vendor.
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
