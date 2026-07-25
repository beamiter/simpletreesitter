# simpletreesitter

面向 Vim9 的 Tree-sitter 语法高亮与代码大纲插件。解析、查询和符号提取由 Rust daemon 异步完成，Vim 主线程只负责调度与 UI。

## 主要能力

- 实时语法高亮：仅查询可见区域与 margin，编辑、滚动分别防抖。
- 端到端增量：首次全量快照后，Vim 只发送变更行区间（`edit_lines`），daemon 用
  `Tree::edit` + 旧语法树增量重解析；行数校验失配自动回退全量同步。
- 代码大纲：层级容器、折叠、跳转、光标跟随、ASCII/Nerd Font 两套图标。
- Tree-sitter 折叠：`:TsHlFoldsToggle` 由语法树驱动 `foldexpr`，支持嵌套层级。
- 符号跳转：`:TsHlSymbols` 把当前 buffer 符号送入 location list。
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

## 环境要求

- Vim 9.0+，并包含 `+vim9script`、`+job`、`+channel`、`+textprop`、`+timers`。
- UTF-8 编码。
- Rust 1.85+，用于构建 daemon。
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
| `:TsHlDumpAST` | 打开当前 revision 的 AST 视图 |
| `:TsHlStatus` | 显示 daemon 协议、cache 和解析统计；不会启动 daemon |
| `:TsHlSymbols` | 当前 buffer 符号送入 location list 并打开 |
| `:TsHlFoldsToggle` | 切换 Tree-sitter 折叠（`foldexpr` 驱动，可恢复原设置） |

默认普通模式映射：

| 按键 | 功能 |
|---|---|
| `<leader>th` | 切换插件 |
| `<leader>to` | 切换大纲 |

插件不会覆盖已有 leader 映射，并提供标准 `<Plug>` 接口：

```vim
nmap <leader>x <Plug>(simpletreesitter-toggle)
nmap <leader>s <Plug>(simpletreesitter-outline-toggle)
```

大纲窗口内：`<CR>` 跳转，`o`/`za` 折叠或展开，`q` 关闭。

## 配置

以下均为默认值；请在插件加载前覆盖。

```vim
" 自动启动与 daemon
g:simpletreesitter_auto_enable_filetypes = [
  'rust', 'c', 'cpp', 'cc', 'javascript', 'javascriptreact', 'jsx',
  'typescript', 'typescriptreact',
  'python', 'go', 'sh', 'bash', 'zsh', 'vim', 'vimrc',
  'json', 'jsonc', 'yaml', 'toml'
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

" 缩进参考线
g:simpletreesitter_indent_guides = 0
g:simpletreesitter_indent_guide_char = '│'

" Breadcrumb；Vim 无 winbar 时可放入 statusline
g:simpletreesitter_breadcrumb = 0
g:simpletreesitter_breadcrumb_separator = ' > '
" set statusline+=%{simpletreesitter#Breadcrumb()}

" 打开 Outline 时可选暂停高亮
g:simpletreesitter_suspend_highlight_on_outline = 0
g:simpletreesitter_clear_props_on_suspend = 1
g:simpletreesitter_clear_scope_on_suspend = 'visible'  " 或 'buffer'

" 调试日志
g:simpletreesitter_debug = 0
g:simpletreesitter_log_file = '/tmp/ts-hl.log'
```

单个 buffer 可选择退出：

```vim
let b:simpletreesitter_disable = 1
let b:simpletreesitter_max_buffer_bytes = 0  " 仅当前 buffer 取消 Vim 端上限
```

## 架构与稳定性

```text
Vim9 plugin/autoload
  │ newline-delimited JSON，protocol v3 + revision
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
