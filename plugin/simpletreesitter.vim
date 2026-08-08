vim9script

if exists('g:loaded_simpletreesitter')
  finish
endif
g:loaded_simpletreesitter = 1

if !has('job') || !has('channel') || !has('textprop') || !has('timers')
  echohl ErrorMsg
  echom '[ts-hl] requires Vim with +job, +channel, +textprop and +timers'
  echohl None
  finish
endif
if &encoding !=# 'utf-8'
  echohl ErrorMsg
  echom '[ts-hl] requires :set encoding=utf-8'
  echohl None
  finish
endif

# =============== 配置项 ===============
g:simpletreesitter_daemon_path = get(g:, 'simpletreesitter_daemon_path', '')
g:simpletreesitter_debounce = get(g:, 'simpletreesitter_debounce', 120)
g:simpletreesitter_auto_enable_filetypes = get(g:, 'simpletreesitter_auto_enable_filetypes',
  ['rust', 'c', 'cpp', 'cc', 'javascript', 'javascriptreact', 'jsx',
   'typescript', 'typescriptreact',
   'python', 'go', 'sh', 'bash', 'zsh', 'vim', 'vimrc',
   'json', 'jsonc', 'yaml', 'toml', 'lua', 'html', 'css', 'markdown'])
g:simpletreesitter_auto_stop = get(g:, 'simpletreesitter_auto_stop', 1)
g:simpletreesitter_max_buffer_bytes = get(g:, 'simpletreesitter_max_buffer_bytes', 5 * 1024 * 1024)
g:simpletreesitter_clear_props_on_disable = get(g:, 'simpletreesitter_clear_props_on_disable', 1)
# 增量同步：只把变更行区间发给 daemon（需要 protocol v3 的 daemon）
g:simpletreesitter_incremental_sync = get(g:, 'simpletreesitter_incremental_sync', 1)

g:simpletreesitter_debug = get(g:, 'simpletreesitter_debug', 0)
g:simpletreesitter_log_file = get(g:, 'simpletreesitter_log_file', '/tmp/ts-hl.log')

g:simpletreesitter_outline_width = get(g:, 'simpletreesitter_outline_width', 40)

# Outline UI 配置
g:simpletreesitter_outline_fancy = get(g:, 'simpletreesitter_outline_fancy', 1)
g:simpletreesitter_outline_disable_props = get(g:, 'simpletreesitter_outline_disable_props', 0)
g:simpletreesitter_outline_hide_icon = get(g:, 'simpletreesitter_outline_hide_icon', 0)
g:simpletreesitter_outline_ascii = get(g:, 'simpletreesitter_outline_ascii', 0)
g:simpletreesitter_outline_show_position = get(g:, 'simpletreesitter_outline_show_position', 1)
g:simpletreesitter_outline_max_items = get(g:, 'simpletreesitter_outline_max_items', 1000)
g:simpletreesitter_outline_scan_max_items = get(g:, 'simpletreesitter_outline_scan_max_items', 5000)

# Outline 过滤配置
g:simpletreesitter_outline_hide_inner_functions = get(g:, 'simpletreesitter_outline_hide_inner_functions', 1)
g:simpletreesitter_outline_hide_fields = get(g:, 'simpletreesitter_outline_hide_fields', 0)
g:simpletreesitter_outline_hide_variants = get(g:, 'simpletreesitter_outline_hide_variants', 0)
g:simpletreesitter_outline_exclude_patterns = get(g:, 'simpletreesitter_outline_exclude_patterns', [])
# ]s/[s-style navigation can be wired through the <Plug> mappings below.
# An empty list navigates every extracted symbol.
g:simpletreesitter_symbol_jump_kinds = get(g:, 'simpletreesitter_symbol_jump_kinds',
  ['function', 'method', 'class', 'struct', 'enum', 'namespace', 'type', 'module', 'macro'])

# =============== 可见范围/懒高亮配置 ===============
g:simpletreesitter_view_margin = get(g:, 'simpletreesitter_view_margin', 120)
g:simpletreesitter_symbols_view_margin = get(g:, 'simpletreesitter_symbols_view_margin', 10000)
g:simpletreesitter_scroll_debounce = get(g:, 'simpletreesitter_scroll_debounce', 300)
g:simpletreesitter_max_props = get(g:, 'simpletreesitter_max_props', 20000)

# =============== 缩进参考线 ===============
g:simpletreesitter_indent_guides = get(g:, 'simpletreesitter_indent_guides', 0)
g:simpletreesitter_indent_guide_char = get(g:, 'simpletreesitter_indent_guide_char', '│')

# =============== 彩虹括号 ===============
g:simpletreesitter_rainbow_brackets = get(g:, 'simpletreesitter_rainbow_brackets', 1)

# =============== Tree-sitter 折叠 ===============
g:simpletreesitter_folds = get(g:, 'simpletreesitter_folds', 0)

# =============== :TsHlInspect ===============
# 1: 光标处弹出 popup；0: 用底部的 ts-hl-inspect scratch split（可复制/搜索）。
g:simpletreesitter_inspect_popup = get(g:, 'simpletreesitter_inspect_popup', 1)

# =============== 面包屑导航 ===============
g:simpletreesitter_breadcrumb = get(g:, 'simpletreesitter_breadcrumb', 0)
g:simpletreesitter_breadcrumb_separator = get(g:, 'simpletreesitter_breadcrumb_separator', ' > ')

# =============== Outline 增强 ===============
g:simpletreesitter_outline_follow_cursor = get(g:, 'simpletreesitter_outline_follow_cursor', 1)
g:simpletreesitter_outline_foldable = get(g:, 'simpletreesitter_outline_foldable', 1)
g:simpletreesitter_outline_spacing = get(g:, 'simpletreesitter_outline_spacing', 1)

# =============== Outline 打开时全局暂停高亮 ===============
g:simpletreesitter_suspend_highlight_on_outline = get(g:, 'simpletreesitter_suspend_highlight_on_outline', 0)
g:simpletreesitter_clear_props_on_suspend = get(g:, 'simpletreesitter_clear_props_on_suspend', 1)
g:simpletreesitter_clear_scope_on_suspend = get(g:, 'simpletreesitter_clear_scope_on_suspend', 'visible')

# =============== 命令 ===============
command! TsHlEnable  call simpletreesitter#Enable()
command! TsHlDisable call simpletreesitter#Disable()
command! TsHlToggle  call simpletreesitter#Toggle()

command! TsHlOutlineOpen    call simpletreesitter#OutlineOpen()
command! TsHlOutlineClose   call simpletreesitter#OutlineClose()
command! TsHlOutlineToggle  call simpletreesitter#OutlineToggle()
command! TsHlOutlineRefresh call simpletreesitter#OutlineRefresh()
command! -nargs=* TsHlOutlineFilter call simpletreesitter#OutlineFilter(<q-args>)
command! TsHlDumpAST        call simpletreesitter#DumpAST()
command! -bang TsHlInspect  call simpletreesitter#Inspect(<bang>0)
command! TsHlStatus         call simpletreesitter#Status()
command! TsHlSymbols        call simpletreesitter#SymbolsToLoclist()
command! -count=1 TsHlNextSymbol call simpletreesitter#NextSymbol(<count>)
command! -count=1 TsHlPrevSymbol call simpletreesitter#PrevSymbol(<count>)
command! TsHlFoldsToggle    call simpletreesitter#FoldsToggle()
command! TsHlHealth  call simpletreesitter#Health()
command! TsHlRestart call simpletreesitter#Restart()
command! TsHlLog     call simpletreesitter#ShowLog()

# =============== 快捷键 ===============
nnoremap <silent> <Plug>(simpletreesitter-toggle) <Cmd>TsHlToggle<CR>
nnoremap <silent> <Plug>(simpletreesitter-outline-toggle) <Cmd>TsHlOutlineToggle<CR>
nnoremap <silent> <Plug>(simpletreesitter-next-symbol) <Cmd>call simpletreesitter#NextSymbol(v:count1)<CR>
nnoremap <silent> <Plug>(simpletreesitter-prev-symbol) <Cmd>call simpletreesitter#PrevSymbol(v:count1)<CR>

if maparg('<leader>th', 'n') ==# '' && !hasmapto('<Plug>(simpletreesitter-toggle)', 'n')
  nmap <silent> <leader>th <Plug>(simpletreesitter-toggle)
endif
if maparg('<leader>to', 'n') ==# '' && !hasmapto('<Plug>(simpletreesitter-outline-toggle)', 'n')
  nmap <silent> <leader>to <Plug>(simpletreesitter-outline-toggle)
endif

# =============== 自动启动逻辑 ===============
augroup TsHlAutoStart
  autocmd!
  autocmd BufEnter,FileType * call simpletreesitter#OnBufEvent(bufnr())
augroup END

# 新增：当任何窗口关闭时，若是 outline 窗口则自动 OutlineClose
augroup TsHlOutlineAutoClose
  autocmd!
  # WinClosed 的 <amatch> 是被关闭窗口的 winid（字符串）
  autocmd WinClosed * call simpletreesitter#OnWinClosed(expand('<amatch>'))
  # The Outline is per tabpage: swap in this tab's sidebar state before any
  # mapping, timer or daemon reply can read the previous tab's line map.
  autocmd TabEnter * call simpletreesitter#OnTabEnter()
augroup END
