# Changelog

## 0.5.1 — 2026-07-26

- Performance: highlight span groups and symbol kinds now use `&'static str`
  from the capture tables instead of per-item heap allocations — a full
  highlight pass on a large buffer no longer allocates thousands of short
  strings, and symbol dedup keys got cheaper.
- Release profile now aborts on panic (daemons never unwind), trimming the
  binary.

## 0.5.0 — 2026-07-25

- Added Markdown (GFM) support with a dual-tree pipeline: the block grammar
  parses structure while an inline grammar parses only the block tree's
  `inline` ranges (via `included_ranges`), giving emphasis, strong, code
  spans, links and autolinks without a full injection engine. The inline
  tree is rebuilt on each sync; the block tree stays incremental.
- Outline for Markdown shows the heading hierarchy: h1..h6 map to distinct
  symbol kinds, and setext headings are supported.
- New prose highlight groups: `TSTitle`, `TSLiteral`, `TSEmphasis`,
  `TSStrong`, `TSStrike`, `TSURI`, `TSLink` (linked to sensible defaults,
  overridable like every other `TS*` group).

## 0.4.0 — 2026-07-25

- Added three languages: Lua, HTML and CSS, each with highlight and symbol
  queries plus end-to-end regression tests (parse → highlight spans → outline
  symbols).
- Migrated the crate metadata forward (dependency refresh, lockfile update).

## 0.3.0 — 2026-07-25

- Added protocol v3 line-delta sync: after the first full snapshot, Vim merges
  `listener_add` changes into a single splice and sends only the changed line
  range (`edit_lines`); the daemon re-splices its cached text, verifies the
  resulting line count and falls back to a full resync on any mismatch.
- Added five languages: TypeScript, TSX, JSON/JSONC, YAML and TOML, each with
  highlight and symbol queries, outline containers and regression coverage.
- Added Tree-sitter folds: a bounded `folds` request computes nested fold
  ranges from the syntax tree; `:TsHlFoldsToggle` drives 'foldexpr' per window
  and restores the previous fold settings when disabled.
- Added `:TsHlSymbols` to collect the buffer's symbols into the location list.
- Extended smoke and unit coverage: splice-merge composition, incremental
  end-to-end sync, folds, location list and the new filetype routing.

## 0.2.0 — 2026-07-15

- Added protocol v2 handshake and revision-safe highlights, symbols, AST and sync acknowledgements.
- Added real Tree-sitter incremental parsing with minimal `InputEdit` calculation.
- Added buffer cache release, daemon restart recovery, status diagnostics and bounded responses.
- Reworked Vim scheduling to coalesce in-flight work and retry the latest viewport.
- Fixed Rust function/method classification, Rust keywords, C/C++ definition ranges, JavaScript lexical declarations, Go containers and Vim9 declaration fallback.
- Made multiline strings/comments visible when their capture starts above the requested viewport.
- Removed the rainbow-bracket quadratic root scan and bounded AST depth, indentation and node output.
- Made Outline idempotent, revision-safe across buffers, source-window safe and correctly hierarchical.
- Added large-buffer opt-out, namespaced text properties, per-window indent-guide restoration and theme refresh.
- Added 17 Rust regression tests, a headless Vim integration test and CI quality gates.
- Pinned the Vim9 grammar, committed `Cargo.lock`, updated Tree-sitter, fixed the installer and added the MIT license.

## 0.1.0 — 2026-07-04

- Initial Vim9 syntax highlighting and Outline implementation.
