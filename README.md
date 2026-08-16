# simpletreesitter

面向 Vim9 的 Tree-sitter 语法高亮与代码大纲插件。解析、查询和符号提取由 Rust daemon 异步完成，Vim 主线程只负责调度与 UI。

## 主要能力

- 实时语法高亮：仅查询可见区域与 margin，编辑、滚动分别防抖。
- 端到端增量：首次全量快照后，Vim 只发送变更行区间（`edit_lines`），daemon 用
  `Tree::edit` + 旧语法树增量重解析；行数校验失配自动回退全量同步。
- 代码大纲：层级容器、折叠、跳转、光标跟随、ASCII/Nerd Font 两套图标。
- Tree-sitter 折叠：`:TsHlFoldsToggle` 由语法树驱动 `foldexpr`，支持嵌套层级。
- Tree-sitter 文本对象：`af`/`if`（函数）、`ac`/`ic`（类型容器）、`aa`/`ia`（参数/实参），
  另有 block/call/comment/conditional/loop 共 8 类的 `<Plug>` 映射与 `:TsHlSelect`。
  参数的 outer 连分隔符一起选，`daa` 之后实参表仍然合法。
- 增量选择：从光标处最内层节点开始按语法节点逐层扩展/收缩（默认不占键，见
  `g:simpletreesitter_selection_maps`）。
- 符号跳转：`:TsHlSymbols` 把当前 buffer 符号送入 location list。
- 异步符号导航：`:TsHlNextSymbol` / `:TsHlPrevSymbol` 支持计数、循环与连续按键合并，不必打开 Outline。
- 语言注入：markdown 的行内语法与带语言标记的围栏代码块（```rust 等）、HTML 的
  `<script>`/`<style>` 分别用对应语法解析并高亮，坐标仍在宿主文档里；注入区间内
  宿主自己的 capture 会被丢弃，围栏不再被一整片 `@text.literal` 盖住。未知或无标记
  的围栏保持原样。注入深度为 1，每种语言每次同步只解析一遍。
- 协议 v7 省流编辑回路：symbols/folds 内容没变时 daemon 只回一个 `unchanged`，
  不重发载荷、不重建 Outline、也不重设 `'foldexpr'`（重设会让 Vim 把整个 buffer
  的折叠层级重算一遍）；高亮改用「组名表 + 定长列表」的紧凑编码，约省三分之二
  字节。两者都按请求协商，旧 daemon 仍按 v6 形态工作。
- 协议 v6 作用域链：一次应答同时喂饱文本对象与增量选择，且对整个 token 有效，
  故算子等待里无需往返即可同步作答；旧 daemon 缺 `scope` 能力时给出可执行提示。
- 协议 v5 请求关联：每次 symbols 请求携带单调 token；迟到的 full/partial 成功或
  error 都不能清掉新请求状态、污染 full cache 或触发旧跳转，v4 后台仍按原有
  revision / op / kind 守卫兼容运行。
- 精确版本协议：所有结果携带 buffer revision，过期高亮、符号、折叠和 AST 会被丢弃。
- 长会话稳定性：buffer 关闭即释放 daemon cache；daemon 重启后自动重新同步。
- 大文件保护：Vim 端默认跳过超过 5 MiB 的 buffer；daemon 另有硬上限和有界结果。
- 彩虹括号、缩进参考线、breadcrumb、AST 调试视图。
- 远程工作区：`'buftype'` 为 `acwrite` 的 buffer（SimpleRemote 的 `remote://` 虚拟文件、
  netrw 的 `scp://` 等）与本地文件同等对待；监听 `User SimpleRemoteBufferRead`，远程
  文件读完/重读后立即重新同步高亮，详见下文「与 SimpleRemote 协作」。
- 查询与语义回归测试：覆盖全部 13 种语言。

## 支持语言

| 语言 | Vim filetype | 高亮 | 大纲 |
|---|---|---:|---:|
| Rust | `rust` | ✅ | ✅ |
| C | `c` | ✅ | ✅ |
| C++ | `cpp`, `cc` | ✅ | ✅ |
| JavaScript / JSX | `javascript`, `javascriptreact`, `jsx` | ✅ | ✅ |
| TypeScript | `typescript` | ✅ | ✅ |
| TSX | `typescriptreact` | ✅ | ✅ |
| Python | `python` | ✅ | ✅ |
| Go | `go` | ✅ | ✅ |
| Bash / Shell | `sh`, `bash`, `zsh` | ✅ | ✅ |
| Vim9 | `vim`, `vimrc` | ✅ | ✅ |
| JSON / JSONC | `json`, `jsonc` | ✅ | ✅ |
| YAML | `yaml` | ✅ | ✅ |
| TOML | `toml` | ✅ | ✅ |
| Lua | `lua` | ✅ | ✅ |
| HTML | `html` | ✅（`<script>`/`<style>` 注入） | ✅ |
| CSS | `css` | ✅ | ✅ |
| Markdown (GFM) | `markdown` | ✅（行内 + 围栏注入） | ✅（标题大纲） |
| Julia | `julia` | ✅ | ✅ |
| Haskell | `haskell` | ✅ | ✅ |

SimpleTreeSitter also enables Vim's bundled `matchit` for `%`/`g%`/`[%`/`]%`
block matching and ships a lightweight Haskell layout indent script, so these
features do not require `vim-matchup` or `haskell-vim`.

## 环境要求

- Vim 9.0+，并包含 `+vim9script`、`+job`、`+channel`、`+textprop`、`+timers`。
- UTF-8 编码。
- Rust 1.88+，用于构建 daemon。
- 当前插件使用 Vim9 script，不支持 Neovim。

## 安装与更新

使用 vim-plug，并让每次安装/更新后自动重建 daemon：

```vim
Plug 'beamiter/simpletreesitter', { 'do': './install.sh' }
```

手工安装或升级：

```bash
cd ~/.vim/plugged/simpletreesitter
./install.sh
```

安装脚本使用锁定依赖构建 release 版本，并原子替换 `lib/ts-hl-daemon`。如果 Vim 提示 daemon protocol 过旧，重新运行该脚本即可。

也可以手工执行：

```bash
cargo build --release --locked
mkdir -p lib
install -m 0755 target/release/ts-hl-daemon lib/ts-hl-daemon
```

## 命令与按键

| 命令 | 说明 |
|---|---|
| `:TsHlEnable` / `:TsHlDisable` | 启用或禁用插件 |
| `:TsHlToggle` | 切换插件状态 |
| `:TsHlOutlineOpen` / `:TsHlOutlineClose` | 打开或关闭大纲 |
| `:TsHlOutlineToggle` | 切换大纲 |
| `:TsHlOutlineRefresh` | 刷新当前大纲 |
| `:TsHlOutlineFilter [query]` | 即时过滤大纲；省略 query 清除过滤 |
| `:TsHlDumpAST` | 打开当前 revision 的 AST 视图 |
| `:TsHlInspect[!]` | 报告光标处匹配到的 capture、映射到的高亮组与 link 链、以及节点链；`!` 连同未被采用的 capture 一起解析 |
| `:TsHlSelect {object}` | 选中光标处的文本对象，如 `:TsHlSelect function.inner`（支持补全） |
| `:TsHlStatus` | 显示 daemon 协议、cache 和解析统计；不会启动 daemon |
| `:TsHlSymbols` | 当前 buffer 符号送入 location list 并打开 |
| `:[count]TsHlNextSymbol` / `:[count]TsHlPrevSymbol` | 在结构符号间前后跳转，到头循环 |
| `:TsHlFoldsToggle` | 切换 Tree-sitter 折叠（`foldexpr` 驱动，可恢复原设置） |

大纲是**每个标签页一份**：窗口、buffer、source buffer、过滤、折叠与跳转表都属于
所在标签页。在第二个标签页打开不会影响第一个，任何 `:TsHlOutline*` 只作用于当前
标签页、绝不切走；`:TsHlDisable` 关闭全部。第一个大纲 buffer 名为 `ts-hl-outline`，
之后的带后缀（Vim buffer 名必须唯一）。

默认普通模式映射：

| 按键 | 功能 |
|---|---|
| `<leader>th` | 切换插件 |
| `<leader>to` | 切换大纲 |
| `af` / `if` | 函数整体 / 函数体（可视与算子等待模式） |
| `ac` / `ic` | 类型容器整体 / 其成员 |
| `aa` / `ia` | 参数（连分隔符） / 参数本身 |

插件不会覆盖已有 leader 映射，并提供标准 `<Plug>` 接口：

```vim
nmap <leader>x <Plug>(simpletreesitter-toggle)
nmap <leader>s <Plug>(simpletreesitter-outline-toggle)
nmap ]s <Plug>(simpletreesitter-next-symbol)
nmap [s <Plug>(simpletreesitter-prev-symbol)

" 文本对象共 8 类 × outer/inner，每个都有 <Plug>：
xmap am <Plug>(simpletreesitter-textobj-call-outer)
omap am <Plug>(simpletreesitter-textobj-call-outer)

" 增量选择默认不占键（<CR>/<BS> 在可视模式里本来就有含义）：
let g:simpletreesitter_selection_maps =
      \ {'init': 'gnn', 'expand': '<CR>', 'shrink': '<BS>'}
```

算子等待模式里没有等待 daemon 回包的机会，所以文本对象只吃缓存：光标停下时预取
一次作用域链，一次应答对整个 token 有效。缓存冷（刚编辑完、或首次预取还没回来），
或者链上根本没有这一类节点（例如没有类型的文件里按 `ac`）时，**什么也不选、不做
任何编辑**：算子等待模式下算子被放弃，可视模式下原来的选区原样还给你。两种模式都
是再按一次即可。详见 `:help simpletreesitter-textobjects`。

大纲窗口内：`<CR>` 跳转，`o`/`za` 折叠或展开，`/` 输入过滤词，`q` 关闭。
过滤对符号名、kind 与容器名做不区分大小写的字面子串匹配；它直接投影最近一次
通过 revision/request 校验的原始 symbols，在条数上限之前执行，因此无需新请求，
清除后也能立即恢复完整大纲。重绘会保持仍可见的选中符号和调用方窗口焦点；
切换或关闭 source buffer 会清掉 query 与原始缓存，避免跨 buffer 串用。

## 配置

以下均为默认值；请在插件加载前覆盖。

```vim
" 自动启动与 daemon
g:simpletreesitter_auto_enable_filetypes = [
  'rust', 'c', 'cpp', 'cc', 'javascript', 'javascriptreact', 'jsx',
  'typescript', 'typescriptreact',
  'python', 'go', 'sh', 'bash', 'zsh', 'vim', 'vimrc',
  'json', 'jsonc', 'yaml', 'toml', 'lua', 'html', 'css', 'markdown'
]
g:simpletreesitter_auto_stop = 1
g:simpletreesitter_daemon_path = ''
g:simpletreesitter_debounce = 120
g:simpletreesitter_scroll_debounce = 300
g:simpletreesitter_max_buffer_bytes = 5 * 1024 * 1024  " 0 表示不设 Vim 端上限
g:simpletreesitter_clear_props_on_disable = 1
g:simpletreesitter_incremental_sync = 1  " 行级增量同步（需要 protocol v3 daemon）

" Tree-sitter 折叠
g:simpletreesitter_folds = 0

" 高亮范围与上限
g:simpletreesitter_view_margin = 120
g:simpletreesitter_symbols_view_margin = 10000
g:simpletreesitter_max_props = 20000
g:simpletreesitter_rainbow_brackets = 1

" Outline
g:simpletreesitter_outline_width = 40
g:simpletreesitter_outline_fancy = 1
g:simpletreesitter_outline_ascii = 0
g:simpletreesitter_outline_hide_icon = 0
g:simpletreesitter_outline_show_position = 1
g:simpletreesitter_outline_disable_props = 0
g:simpletreesitter_outline_max_items = 1000
g:simpletreesitter_outline_scan_max_items = 5000
g:simpletreesitter_outline_follow_cursor = 1
g:simpletreesitter_outline_foldable = 1
g:simpletreesitter_outline_spacing = 1
g:simpletreesitter_outline_hide_inner_functions = 1
g:simpletreesitter_outline_hide_fields = 0
g:simpletreesitter_outline_hide_variants = 0
g:simpletreesitter_outline_exclude_patterns = []
g:simpletreesitter_symbol_jump_kinds = [
  'function', 'method', 'class', 'struct', 'enum',
  'namespace', 'type', 'module', 'macro'
]  " [] 表示全部；Markdown/结构化数据自动导航全部层级

" 文本对象与增量选择
g:simpletreesitter_textobjects = {
  'af': 'function.outer', 'if': 'function.inner',
  'ac': 'class.outer',    'ic': 'class.inner',
  'aa': 'parameter.outer','ia': 'parameter.inner',
}                                    " {} 表示一个默认键都不装
g:simpletreesitter_textobject_maps = 1
g:simpletreesitter_selection_maps = {}   " init/expand/shrink，默认不占键
g:simpletreesitter_scope_prefetch = 1    " 0 表示不预取；文本对象只在重按时才命中
g:simpletreesitter_scope_debounce = 50

" :TsHlInspect 渲染方式：1 = 光标处 popup，0 = ts-hl-inspect scratch split
g:simpletreesitter_inspect_popup = 1

" 缩进参考线
g:simpletreesitter_indent_guides = 0
g:simpletreesitter_indent_guide_char = '│'

" Breadcrumb；Vim 无 winbar 时可放入 statusline
g:simpletreesitter_breadcrumb = 0
g:simpletreesitter_breadcrumb_separator = ' > '
" set statusline+=%{simpletreesitter#Breadcrumb()}
" 'winbar' 也只放这一个固定表达式，符号名永远按字面渲染：
" 两个选项都按 'statusline' 格式解析，名字里的 %{...} 否则会在每次重绘时求值。
" 面包屑按窗口缓存：同一文件的两个窗口各自显示自己光标所在的符号。

" 打开 Outline 时可选暂停高亮
g:simpletreesitter_suspend_highlight_on_outline = 0
g:simpletreesitter_clear_props_on_suspend = 1
g:simpletreesitter_clear_scope_on_suspend = 'visible'  " 或 'buffer'

" 调试日志
g:simpletreesitter_debug = 0
g:simpletreesitter_log_file = '/tmp/ts-hl.log'
```

符号导航会记住按键发起时的 split、光标和 `changedtick`。daemon 响应前
切到别的窗口不会被抢回焦点；若原光标或文本已改变，旧跳转会取消。
同一 revision/类别配置的 full-symbol 结果会复用，连续跳转不重复扫描；
protocol v4+ daemon 会在结果上限之前先过滤 kind；protocol v5 还会关联每个
symbols 成功/错误响应，避免同 buffer 的迟到响应被误认成当前 full 请求。

单个 buffer 可选择退出：

```vim
let b:simpletreesitter_disable = 1
let b:simpletreesitter_max_buffer_bytes = 0  " 仅当前 buffer 取消 Vim 端上限
```

## 与 SimpleRemote 协作

插件只消费 buffer 文本（daemon 拿到的是 `getbufline()`，从不读路径），所以文件从哪里
来无关紧要，`'buftype'` 才是判据：空值与 `acwrite` 视为文件，其余（nofile、nowrite、
terminal、prompt、popup 以及本插件自己的 Outline/Inspect 视图）一律不碰。`acwrite`
就是「由某个插件自己通过 BufReadCmd/BufWriteCmd 读写」的 buffer —— SimpleRemote 的
`remote://` 虚拟文件、netrw 的 `scp://` 都属此类，同样享有高亮、Outline、符号跳转、
折叠与文本对象，也按 `g:simpletreesitter_auto_enable_filetypes` 自动启动。

[SimpleRemote](https://github.com/beamiter/simpleremote) 可选，运行时探测：

- 投影模式（sshfs / docker-bind / local-map）打开的是普通本地路径，无需任何处理。
- 虚拟模式打开 `remote:///path` buffer（`'buftype'` acwrite），文本异步到达；随后的
  FileType 事件照常挂载。
- 插件监听 `User SimpleRemoteBufferRead`（SimpleRemote 在 `remote://` buffer 填充/重读
  完成后触发，`g:simpleremote_event.bufnr` 指明 buffer）：当前 buffer 立即重新同步 ——
  重读不改 `'filetype'`，不会有 FileType，而 TextChanged 要等下一次按键；显示在其他
  窗口里的 buffer 同样重新同步，但不会把 Outline 或 breadcrumb 从光标所在 buffer 上
  拽走；隐藏 buffer 留给 BufEnter，进入时按 changedtick 补同步。
- 不向远端发送任何东西：高亮、符号与折叠都在本地 daemon 上对 buffer 文本完成；保存
  走 SimpleRemote 自己的 BufWriteCmd，与本插件无关。

自动命令无条件注册，没有 SimpleRemote 时它永远不会触发。回归测试见
`tests/vim_remote.vim`（`make vim-remote`）。

## 架构与稳定性

```text
Vim9 plugin/autoload
  │ newline-delimited JSON，protocol v7 + revision/request class/request_id
  │ symbols/folds 带载荷摘要，内容未变只回 unchanged；highlights 走紧凑编码
  │ 首次 set_text 全量；此后 listener 合并变更行，只发 edit_lines 行区间
  ▼
ts-hl-daemon
  ├─ 每语言 Parser / 预编译 Query cache
  ├─ 每 buffer text / Tree / line index cache
  ├─ edit_lines 行拼接（带行数校验）+ InputEdit 增量解析
  └─ 有界 highlights / symbols / folds / AST 响应
```

daemon 串行处理请求，避免共享语法树并发竞态；Vim 端每个 buffer 合并同步请求，并在响应到达时验证 `changedtick`。关闭、卸载或擦除 buffer 会发送 `close_buffer`。daemon 异常退出时，插件会清空协议状态，并在下一次 buffer 事件重新同步。

## 开发与验证

```bash
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo build --release --locked
vim -Nu NONE -i NONE -n -es -X -S tests/vim_smoke.vim
vim -Nu NONE -i NONE -n -es -X -S tests/vim_remote.vim
```

## 排障

- `daemon not found`：运行 `./install.sh`，或设置 `g:simpletreesitter_daemon_path`。
- `daemon protocol is outdated`：插件已更新而本地二进制仍旧，重新运行安装脚本。
- 大文件没有高亮：检查 `g:simpletreesitter_max_buffer_bytes` 与 `b:simpletreesitter_disable`。
- 查看状态：先打开一个受支持文件，再执行 `:TsHlStatus`。
- 查看日志：启用 `g:simpletreesitter_debug` 后检查 `g:simpletreesitter_log_file`。
- Nerd Font 图标异常：设置 `g:simpletreesitter_outline_fancy = 0` 或启用 ASCII 模式。

## License

[MIT](LICENSE)
