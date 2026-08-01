# Changelog

## Unreleased - 2026-08-01

### 构建与 CI 修复

- clippy 的 `collapsible_if` / `manual_is_multiple_of` 属于按 MSRV 放开的 lint;声明升到 1.88 后开始生效,17 处已修正。
- `rust-version` 由 1.85 更正为 1.88:daemon 自身有 26 处 let-chains,按 1.85 根本编译不过;README、doc 与 install.sh 的提示同步更新。
- 修复 clippy `manual_filter`(CI 用的 1.97 会报错,本地 1.96 不报),该作业已失败很久。
- 新增 CI 的 MSRV 作业。

### 修复

- `cargo fmt --check` 长期不通过(与本仓库 CI 的质量门冲突),现已按当前 rustfmt
  重新格式化。该问题与本次改动无关,是原就存在的。

### 修复

- `EnsureDaemon()` 用 `s_job != v:null` 判定启动成功,而 `job_start()` 在 exec
  失败时同样返回 job 对象;`Send()` 也只看缓存标志、从不复查 `job_status()`。
  daemon 起不来或中途死掉时,高亮会静默停止而插件仍认为一切正常。
- daemon 崩溃后不再自动恢复,只能手动 `:TsHlToggle`;现在会退避重启并自动
  重新 hello 握手,所有 buffer 重新同步。

### 新增

- `:TsHlHealth`、`:TsHlRestart`、`:TsHlLog`。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpletreesitter/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:TsHlRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:TsHlHealth`、`:TsHlRestart`、`:TsHlLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

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
