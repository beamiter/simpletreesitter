.PHONY: check fmt clippy test daemon vim-test vim-remote vim-indent vim-core defcompile core-verify doc-tags

check: core-verify doc-tags fmt clippy test defcompile vim-core vim-indent vim-test vim-remote

doc-tags:
	@tmp=$$(mktemp -d) && cp doc/*.txt $$tmp/ && \
	vim -Nu NONE -n -i NONE -es -c "helptags $$tmp" -c 'qa!' </dev/null && \
	status=0; \
	foreign=$$(awk -F'\t' '$$1 !~ /^(simpletreesitter|g:simpletreesitter|:TsHl|<Plug>\(simpletreesitter)/ { print $$1 }' $$tmp/tags); \
	if [ -n "$$foreign" ]; then \
	  echo "doc: *word* in prose defined a global help tag: $$foreign" >&2; status=1; fi; \
	if ! diff -u doc/tags $$tmp/tags >&2; then \
	  echo "doc/tags is stale; regenerate with :helptags doc" >&2; status=1; fi; \
	rm -rf $$tmp; \
	[ $$status -eq 0 ] && echo "doc: help tags are current and plugin-scoped"

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
#
# These lines are vendored too.  They are the tail of this Makefile — nothing
# above the banner belongs to the bundle — and `.simplecore.manifest` records
# them as a `footer` fragment.  Until it did, they were the one bundle member
# copied by hand and hashed by nothing, so core-verify could not see them
# drift; nine plugins carried an installer in the same position.
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
#
# Whole files are plain `sha256sum -c` records.  A fragment — a run of lines
# inside a file the plugin itself owns, like this footer — is recorded as
# `footer <lines> <sha256>  <path>` and checked against the tail of <path>.
core-verify:
	@records=$$(grep -cE '^[0-9a-f]{64}' .simplecore.manifest); \
	checked=$$(grep -cE '^[0-9a-f]{64}  ' .simplecore.manifest); \
	test "$$records" = "$$checked" || { \
	  echo ".simplecore.manifest: $$((records - checked)) hash record(s) not checked" >&2; \
	  echo "  a record whose separator is not exactly two spaces is dropped by the" >&2; \
	  echo "  reader below and would verify green while its file went unchecked." >&2; \
	  exit 1; }
	@grep -E '^[0-9a-f]{64}  ' .simplecore.manifest | sha256sum -c --quiet
	@awk '$$1 == "footer" { print $$2, $$3, $$4 }' .simplecore.manifest \
	| while read -r lines sum path; do \
		test "$$(tail -n "$$lines" "$$path" | sha256sum | cut -d' ' -f1)" = "$$sum" \
		|| { echo "$$path: FAILED (simplecore footer)" >&2; exit 1; }; \
	done
	@echo "simplecore: bundle v$$(awk '$$1 == "version" { print $$2 }' .simplecore.manifest) verified"

# core-verify proves this repository is internally consistent: every vendored
# copy still matches the manifest written beside it.  It cannot prove freshness.
# A plugin that misses a re-vendor keeps verifying its own stale copy for ever,
# and stays green doing it, because the bundle is deliberately not required to
# be present for the build to work.  This target is the other half, for when it
# is present; `check` cannot depend on it without making the bundle a build
# dependency, which is the coupling the vendoring exists to avoid.
SIMPLECORE_DIR ?= ../.simplecore
core-fresh:
	@if [ -x "$(SIMPLECORE_DIR)/vendor.sh" ]; then \
	  SIMPLECORE_SUITE="$(patsubst %/,%,$(dir $(CURDIR)))" \
	    "$(SIMPLECORE_DIR)/vendor.sh" --check "$(notdir $(CURDIR))"; \
	else \
	  echo "simplecore: $(SIMPLECORE_DIR) is not checked out; freshness unverified"; \
	fi

# Supervisor regression suite: liveness, generation guards, backoff restarts,
# the crash-loop breaker, request timeouts, and both outcomes of the protocol
# handshake — the reply that lands, and the deadline that expires and fails the
# start.
vim-core:
	vim -Nu NONE -n -i NONE -es -S tests/vim_core.vim

# Vim9 compiles def bodies lazily, so a type error in a cold branch stays
# hidden until a user reaches it.  :defcompile surfaces it here instead.
defcompile:
	vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim

.PHONY: core-verify core-fresh vim-core defcompile
