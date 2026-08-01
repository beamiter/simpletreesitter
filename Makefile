.PHONY: check fmt clippy test vim-test vim-core defcompile

check: fmt clippy test defcompile vim-core vim-test

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

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts and the protocol handshake.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
