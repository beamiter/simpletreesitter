# Changelog

## Unreleased - 2026-08-08

### 修复：面包屑按窗口缓存，不再串窗口

- 把符号名从 'winbar' 里挪出去之后，每个窗口的 'winbar' 装的都是同一句
  `%{simpletreesitter#Breadcrumb()}`，而它读的是唯一一份脚本级缓存：于是所有窗口
  渲染的都是"最后一次被更新的那个窗口"的面包屑。`:split` 一个文件，上窗口光标停在
  `foo` 里，再到下窗口进入 `bar`，上窗口就开始宣称自己在 `bar` 里——它指着一个自己
  光标并不在的函数。同样地，光标一进入没有面包屑的 buffer，之前访问过的每个窗口的
  winbar 都会变空，却仍旧占着一行。
- 缓存改为按 winid 存放，`Breadcrumb()` 返回"正在绘制的这个窗口"的那一条。Vim 在
  求值 `%{}` 时会把被绘制的窗口临时置为当前窗口（`:help stl-%{`），因此重绘期间和
  直接调用时 `win_getid()` 得到的都是正确的窗口。窗口关闭时（`WinClosed`）删除对应
  条目，长会话不会按开过的窗口数堆积字符串，回收的 winid 也不会继承死窗口的面包屑。
- `Disable()` 此前只清当前窗口的 'winbar'，其余窗口留着一句求值为空的表达式，白占
  一行屏幕；现在跨标签页扫一遍，只清掉值恰好是本插件那句表达式的窗口。

### 修复：`make check` 自己构建它要测的 daemon

- `tests/vim_smoke.vim` 把 daemon 固定在 `target/debug/ts-hl-daemon`，而 `check`
  里没有任何一个 target 会产出这个二进制：`cargo test` 只构建 bin 的单元测试，不构建
  bin 本身（本 crate 没有会选中 bin target 的集成测试或 bench）。`lib/` 和 `target/`
  都在 .gitignore 里，所以在干净检出上 `FindExe()` 什么也找不到，冒烟测试的行为断言
  全线失败；而在开发者机器上它会静默回退到 `lib/` 或 `target/release/` 里那份陈旧的
  二进制——用上个月的 daemon 测这个月的 Vim 代码。现在 `vim-test` 依赖新的 `daemon`
  target（`cargo build --locked`），`make check` 在干净树上自洽。
- 冒烟测试同时断言这个二进制存在，把"静默跑了别的 daemon"变成一句明确的失败。

### 修复：发送失败不再永久冻结一个 buffer；可自愈的错误不再打断输入

- `core#Send()` 在 job 仍存活但 `ch_sendraw` 抛出时返回 false（管道满、daemon
  卡在写入中）。`SyncBufferNow` 先置 `s_inflight_sync`/`s_inflight_revision`
  再发送，失败分支只是 `return`，没有任何东西会再来清掉这两个标记：此后
  `ScheduleSync()` 卡在 inflight 守卫上，highlight/symbols/folds 全部卡在
  changedtick 检查上——该 buffer 在本次会话里彻底停止更新，且没有任何提示。
  现在三类请求（sync、highlight、folds）在发送失败时都会把自己刚占用的状态还
  回去，下一次调度正常重试。
- daemon 自身缓存淘汰后返回的 `buffer not cached`（超过 128 个 buffer 就会发生）
  以及两个增量同步分歧检查，都是插件在几行之后主动整体重同步就能自愈的；此前它们
  仍被 `echom`，在打字过程中弹出 hit-enter 提示，报告一件已经修好的事。现在这三类
  写日志、不打扰用户，真正的错误照旧上报。三处重复的正则合并成一个
  `RecoverableDaemonError()`，抑制条件与恢复条件从此不可能各自漂移。

### 新增 `:TsHlInspect`：光标处的 capture 与高亮组

- 对一个语法高亮插件来说，"这个 token 为什么是这个颜色、我该覆盖哪个组"是第一
  问题，而在此之前唯一的答案是去读编译进二进制里的 .scm。`:TsHlInspect` 直接给出
  答案：光标处匹配到的每个 capture、它映射到的高亮组、优先级、范围，以及哪一个
  真正被画出来（`*` 标记）；该组的 `highlight link` 链（要改配色就改链首）；还有
  从最内层节点到根的节点链，附带每个节点在父节点里占的 field。没有映射到任何组的
  capture 也会以 `(no group)` 列出——token 完全没被着色时，那就是答案。
- `:TsHlInspect!` 连同未被采用的 capture 一起解析 link 链。
- daemon 侧新增 `inspect` 请求与 `inspect` 能力位，复用 `map_capture_to_group`
  与 `capture_priority`，"被画出来的那一个"用 `run_highlight_cached` 同一条优先级
  规则标记，因此报告不会和渲染结果脱节。列号会夹进本行并回退到 UTF-8 边界，
  否则一个落在多字节字符中间的偏移会描述到旁边的 token 上。
- 位置在按键时刻捕获，回复按 revision 校验：报告不会描述已经改掉的文本。默认渲染
  为光标处 popup，`g:simpletreesitter_inspect_popup = 0` 改用可搜索可复制的
  `ts-hl-inspect` scratch split。旧 daemon 没有该能力位时给出的是一句可执行的
  提示，而不是 `unknown variant`。

### Outline 变成每标签页一份

- 此前 Outline 是一份全局单例，而它的窗口 id 用 `win_id2win()` 探测——那是标签页
  局部的。在第二个标签页 `:TsHlOutlineOpen` 会看不到第一个标签页的侧边栏，把状态
  清零后新建一个（实际上会撞上 E95：buffer 名重复），第一个标签页的侧边栏就此
  变成孤儿：它的 `<CR>`/`q` 映射还在，读到的却是另一个标签页的 linemap。而在
  第二个标签页 `:TsHlOutlineToggle` 会看到非零的 `s_outline_win` 转去
  `OutlineClose()`，`win_gotoid()` 是跨标签页的——用户被直接甩到第一个标签页，
  那边的 Outline 被关掉。
- 现在每个标签页各有一份完整的 Outline 状态（窗口、buffer、source、过滤、折叠、
  linemap、光标跟随）。标签页身份与状态快照都存在 `t:` 变量里——这是 Vim 唯一
  随标签页存亡的稳定标识，`tabpagenr()` 会在 `:tabclose` 后重排。进入标签页时
  整体换入换出，因此渲染/过滤/跳转/折叠路径依旧写得像不存在标签页一样。
- 关窗改用 `win_execute()`：它能操作别的标签页的窗口而不移动用户。
  `:TsHlDisable` 与自动停机会关掉所有标签页的侧边栏；只要还有任何一个标签页开着
  Outline，daemon 就不会自动停。第一个 Outline buffer 仍叫 `ts-hl-outline`，
  之后的加标签页后缀。

### 修复：breadcrumb 不再把符号名当作 'statusline' 格式串

- `'winbar'` 与 `'statusline'` 用同一套格式解析：裸 `%` 开启一个 item，`%{expr}`
  会在每次重绘时求值。此前 breadcrumb 把符号名内插进 `'winbar'`，只转义了空格、
  反斜杠、`|` 和 `"`，于是一个 markdown 标题 `# %{system("…")}` 会在光标移到该
  小节时被求值——打开不受信任的文件即可执行任意代码；而无害的 `# 100% coverage`
  只会触发 E539，breadcrumb 直接消失。
- 现在 `'winbar'` 在窗口生命周期内只保存一个固定表达式
  `%{simpletreesitter#Breadcrumb()}`，变化的只是它读取的缓存字符串。Vim 不会
  重新解析普通 `%{}` 的结果（那是 `%{% %}` 的语义），所以符号名一律按字面渲染，
  与文档里早已安全的 statusline 用法同源。写选项改用 `setwinvar()`，不再需要
  当初出错的那套选项值转义。

## Unreleased - 2026-08-05

### Outline 即时过滤

- 新增 `:TsHlOutlineFilter [query]` 与 Outline 内 `/`：按符号名、kind、容器名做
  不区分大小写的字面过滤；空 query 立即恢复。过滤基于最后一次通过
  revision/request_id 守卫的未过滤 raw symbols，并发生在 render limit 之前，
  不发送新请求，也不会漏掉原本被条数上限裁掉的匹配项。
- query 可先于在途响应记忆，匹配响应到达后自动生效；重绘保持仍可见的选中符号与
  调用方焦点。切换/关闭 source 会同时清 query/raw；畸形响应里的非字符串名称、
  kind 或容器字段按空值处理，v4 回退与 v5 token 路径不变。

### Protocol v5：异步 symbols 精确关联

- 每个 partial/full symbols 请求新增单调 `request_id`，daemon 在成功与 error 中
  原样回传；Vim 端仅允许当前 token 清理 inflight/purpose/kinds、写 full cache 或
  执行跳转。迟到的 Outline partial、旧 full、旧 buffer 生命周期响应不再可能被
  同 revision 的新导航误认。
- `request_id` 是加法字段：v4 daemon 会忽略请求字段并省略响应字段，前端检测到
  v4 时继续完整使用已有 revision/op/kind 守卫，不禁用导航、Outline 或 loclist。
- Rust 覆盖旧请求默认 token 及 success/error 回显；Vim 回归按迟到 full → partial
  → error 的顺序注入响应，确认当前 token、用途、inflight 与 pending jump 均不变，
  随后的匹配响应仍完成合并跳转。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--version`/`--help`/`--self-test`:此前 daemon 完全忽略命令行参数。
  `--self-test` 会编译全部 17 个内置 grammar 的 query——某个 grammar 编不过时,
  在用户打开那种文件、发现完全没有高亮之前是看不出来的。

### 新增：异步符号导航

- `:[count]TsHlNextSymbol` / `:[count]TsHlPrevSymbol` 在 Tree-sitter 提取的结构符号间
  前后跳转并循环，提供 `<Plug>(simpletreesitter-next-symbol)` / `-prev-symbol`，不抢占
  用户的 `[s` / `]s`。连续按键会在 daemon 响应前合并成步数。
- `g:simpletreesitter_symbol_jump_kinds` 控制代码文件的导航种类，空列表表示全部；
  Markdown、JSON/YAML/TOML、CSS/HTML 自动保留所有层级，低级标题和配置键不会漏掉。
- full-buffer symbols 请求现在与 Outline/breadcrumb 的视口请求串行化并带用途状态，
  部分响应不会误填 location list 或误触发跳转。smoke test 覆盖计数、环绕和请求合并。
- 异步跳转绑定发起 split、光标与 `changedtick`；等待期间切窗不抢焦点，
  移动光标、修改文本或大文件 preflight 失败都会 fail closed，不会迟到触发旧跳转。
- full-symbol 结果按 revision + kind 快照缓存，后续 Next/Prev 无需再走 JSON/全缓冲扫描。
  daemon 升至 protocol v4，在 `max_items` 截断前先过滤导航 kind，并在 error 中标注
  request class，highlight/fold 错误不再破坏同 buffer 的 symbols 在途状态。

### 修复

- Lua、HTML、CSS 与 Markdown 已受支持且 README 也宣称默认自动启用，但实际默认
  filetype 列表漏了这四项；现已补齐，并加入 smoke 断言防止语言表再次漂移。

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
