# simpletreesitter

基于 Tree-sitter 的 Vim9 语法高亮与代码大纲插件。通过一个 Rust 后台守护进程完成解析、高亮和符号提取，Vim 端仅负责 UI 渲染。

## 功能

- **实时语法高亮** — 仅高亮可见区域 + 可配置 margin，支持 debounce
- **代码大纲 (Outline)** — 交互式符号侧栏，支持层级结构、跳转、Nerd Font 图标
- **容器推断** — 自动识别符号的父级（如 method → class, field → struct）
- **增量解析** — 复用旧语法树，编辑大文件时更快
- **查询预编译** — Query 对象按语言缓存，避免重复编译

## 支持语言

| 语言 | 高亮 | 大纲符号 |
|------|------|----------|
| Rust | ✅ | ✅ 函数/方法/类型/结构体/枚举/trait/常量/宏/字段/变体 |
| C | ✅ | ✅ 函数/结构体/枚举/typedef |
| C++ | ✅ | ✅ 函数/方法/类/结构体/枚举/命名空间/模板/类型别名 |
| JavaScript | ✅ | ✅ 函数/类/方法/变量 |
| Python | ✅ | ✅ 函数/类/方法/变量/类型别名 |
| Go | ✅ | ✅ 函数/方法/类型/常量/变量/字段 |
| Bash/Shell | ✅ | ✅ 函数/变量 |
| Vim9 | ✅ | ✅ 函数/变量/映射/插件/augroup/autocmd/set/highlight |

## 安装

### 依赖

- Vim 9.0+ (需要 Vim9 script 支持)
- Rust toolchain (编译守护进程)

### vim-plug

```vim
Plug 'beamiter/simpletreesitter'
```

安装后编译守护进程：

```bash
cd ~/.vim/plugged/simpletreesitter
cargo build --release
cp target/release/ts-hl-daemon lib/
```

或直接运行安装脚本：

```bash
bash install.sh
```

## 使用

### 命令

| 命令 | 说明 |
|------|------|
| `:TsHlToggle` | 切换语法高亮 |
| `:TsHlEnable` / `:TsHlDisable` | 启用/禁用高亮 |
| `:TsHlOutlineToggle` | 切换代码大纲侧栏 |
| `:TsHlOutlineOpen` / `:TsHlOutlineClose` | 打开/关闭大纲 |
| `:TsHlOutlineRefresh` | 刷新大纲 |
| `:TsHlDumpAST` | 输出当前文件的 AST（调试用） |

### 默认快捷键

| 快捷键 | 功能 |
|--------|------|
| `<leader>th` | 切换高亮 |
| `<leader>to` | 切换大纲 |

### 配置

```vim
" 自动启用的文件类型
let g:simpletreesitter_auto_enable_filetypes = ['rust', 'c', 'cpp', 'javascript', 'python', 'go', 'sh']

" 高亮 debounce 毫秒数
let g:simpletreesitter_debounce = 120

" 大纲宽度
let g:simpletreesitter_outline_width = 40

" 使用 Nerd Font 图标
let g:simpletreesitter_outline_fancy = 1

" 大纲最大符号数
let g:simpletreesitter_outline_max_items = 1000

" 隐藏内部函数/字段/变体
let g:simpletreesitter_outline_hide_inner_functions = 1
let g:simpletreesitter_outline_hide_fields = 0
let g:simpletreesitter_outline_hide_variants = 0

" 可见区域 margin（高亮行数）
let g:simpletreesitter_view_margin = 120
```

## 架构

```
Vim9 (plugin/ + autoload/)
    │  JSON stdin/stdout
    ▼
ts-hl-daemon (Rust)
    ├── tree-sitter 解析
    ├── .scm 查询 → 高亮 spans / 符号列表
    └── 按 buffer 缓存 (text + tree + queries)
```

## License

MIT