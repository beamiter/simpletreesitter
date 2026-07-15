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
   'python', 'go', 'sh', 'bash', 'zsh', 'vim', 'vimrc'])
g:simpletreesitter_auto_stop = get(g:, 'simpletreesitter_auto_stop', 1)
g:simpletreesitter_max_buffer_bytes = get(g:, 'simpletreesitter_max_buffer_bytes', 5 * 1024 * 1024)
g:simpletreesitter_clear_props_on_disable = get(g:, 'simpletreesitter_clear_props_on_disable', 1)

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
command! TsHlDumpAST        call simpletreesitter#DumpAST()
command! TsHlStatus         call simpletreesitter#Status()

# =============== 快捷键 ===============
nnoremap <silent> <Plug>(simpletreesitter-toggle) <Cmd>TsHlToggle<CR>
nnoremap <silent> <Plug>(simpletreesitter-outline-toggle) <Cmd>TsHlOutlineToggle<CR>

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
augroup END
