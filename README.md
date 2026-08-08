# simpletreesitter

面向 Vim9 的 Tree-sitter 语法高亮与代码大纲插件。解析、查询和符号提取由 Rust daemon 异步完成，Vim 主线程只负责调度与 UI。

## 主要能力

- 实时语法高亮：仅查询可见区域与 margin，编辑、滚动分别防抖。
- 端到端增量：首次全量快照后，Vim 只发送变更行区间（`edit_lines`），daemon 用
  `Tree::edit` + 旧语法树增量重解析；行数校验失配自动回退全量同步。
- 代码大纲：层级容器、折叠、跳转、光标跟随、ASCII/Nerd Font 两套图标。
- Tree-sitter 折叠：`:TsHlFoldsToggle` 由语法树驱动 `foldexpr`，支持嵌套层级。
- 符号跳转：`:TsHlSymbols` 把当前 buffer 符号送入 location list。
- 异步符号导航：`:TsHlNextSymbol` / `:TsHlPrevSymbol` 支持计数、循环与连续按键合并，不必打开 Outline。
- 协议 v5 请求关联：每次 symbols 请求携带单调 token；迟到的 full/partial 成功或
  error 都不能清掉新请求状态、污染 full cache 或触发旧跳转，v4 后台仍按原有
  revision / op / kind 守卫兼容运行。
- 精确版本协议：所有结果携带 buffer revision，过期高亮、符号、折叠和 AST 会被丢弃。
- 长会话稳定性：buffer 关闭即释放 daemon cache；daemon 重启后自动重新同步。
- 大文件保护：Vim 端默认跳过超过 5 MiB 的 buffer；daemon 另有硬上限和有界结果。
- 彩虹括号、缩进参考线、breadcrumb、AST 调试视图。
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
| HTML | `html` | ✅ | ✅ |
| CSS | `css` | ✅ | ✅ |
| Markdown (GFM) | `markdown` | ✅ | ✅（标题大纲） |

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

插件不会覆盖已有 leader 映射，并提供标准 `<Plug>` 接口：

```vim
nmap <leader>x <Plug>(simpletreesitter-toggle)
nmap <leader>s <Plug>(simpletreesitter-outline-toggle)
nmap ]s <Plug>(simpletreesitter-next-symbol)
nmap [s <Plug>(simpletreesitter-prev-symbol)
```

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

## 架构与稳定性

```text
Vim9 plugin/autoload
  │ newline-delimited JSON，protocol v5 + revision/request class/request_id
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
