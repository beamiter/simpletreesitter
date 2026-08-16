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
   'json', 'jsonc', 'yaml', 'toml', 'lua', 'html', 'css', 'markdown',
   'julia', 'haskell'])
g:simpletreesitter_auto_stop = get(g:, 'simpletreesitter_auto_stop', 1)
g:simpletreesitter_max_buffer_bytes = get(g:, 'simpletreesitter_max_buffer_bytes', 5 * 1024 * 1024)
g:simpletreesitter_clear_props_on_disable = get(g:, 'simpletreesitter_clear_props_on_disable', 1)
# 增量同步：只把变更行区间发给 daemon（需要 protocol v3 的 daemon）
g:simpletreesitter_incremental_sync = get(g:, 'simpletreesitter_incremental_sync', 1)

g:simpletreesitter_debug = get(g:, 'simpletreesitter_debug', 0)
g:simpletreesitter_log_file = get(g:, 'simpletreesitter_log_file', '/tmp/ts-hl.log')
g:simpletreesitter_match_words = get(g:, 'simpletreesitter_match_words', 1)

# Vim 自带的 matchit 已经覆盖 %, g%, [%, ]% 与 a% 文本对象，并会读取各
# filetype 的 b:match_words。SimpleTreeSitter 负责语义高亮/括号层级，matchit
# 负责块关键字跳转；两者组合替代 vim-matchup，同时不再引入第三方插件。
if g:simpletreesitter_match_words
  silent! packadd matchit
endif

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

# =============== 文本对象与增量选择 ===============
# 键 -> 类别.半边（见 :help simpletreesitter-textobjects）。设成 {} 则一个也不装。
g:simpletreesitter_textobjects = get(g:, 'simpletreesitter_textobjects', {
  af: 'function.outer',
  if: 'function.inner',
  ac: 'class.outer',
  ic: 'class.inner',
  aa: 'parameter.outer',
  ia: 'parameter.inner',
})
g:simpletreesitter_textobject_maps = get(g:, 'simpletreesitter_textobject_maps', 1)
# 增量选择默认不占键：expand/shrink 只在可视模式下有意义，而 <CR> 与 <BS> 在
# 可视模式里本来就有含义，默认抢过来属于意外行为。<Plug> 映射始终可用，想要的
# 人填这个字典即可，例如
#   g:simpletreesitter_selection_maps = {init: 'gnn', expand: '<CR>', shrink: '<BS>'}
g:simpletreesitter_selection_maps = get(g:, 'simpletreesitter_selection_maps', {})
# 光标停下后预取作用域链的防抖毫秒数。算子等待里没有等待回包的机会，预取正是
# 文本对象能同步作答的原因；把 prefetch 设为 0 则完全不预取。
g:simpletreesitter_scope_prefetch = get(g:, 'simpletreesitter_scope_prefetch', 1)
g:simpletreesitter_scope_debounce = get(g:, 'simpletreesitter_scope_debounce', 50)

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
command! -nargs=1 -complete=customlist,simpletreesitter#SelectComplete TsHlSelect
  \ call simpletreesitter#Select(<q-args>)
command! TsHlHealth  call simpletreesitter#Health()
command! TsHlRestart call simpletreesitter#Restart()
command! TsHlLog     call simpletreesitter#ShowLog()

# =============== 快捷键 ===============
nnoremap <silent> <Plug>(simpletreesitter-toggle) <Cmd>TsHlToggle<CR>
nnoremap <silent> <Plug>(simpletreesitter-outline-toggle) <Cmd>TsHlOutlineToggle<CR>
nnoremap <silent> <Plug>(simpletreesitter-next-symbol) <Cmd>call simpletreesitter#NextSymbol(v:count1)<CR>
nnoremap <silent> <Plug>(simpletreesitter-prev-symbol) <Cmd>call simpletreesitter#PrevSymbol(v:count1)<CR>

# 文本对象类别。与 simpletreesitter#TEXTOBJECT_SPECS 由 tests/vim_smoke.vim 校对；
# 在这里重列一份，是为了装映射时不必在启动阶段 source 整个 autoload 脚本。
const TEXTOBJECT_SPECS = [
  'function.outer', 'function.inner',
  'class.outer', 'class.inner',
  'parameter.outer', 'parameter.inner',
  'block.outer', 'block.inner',
  'call.outer', 'call.inner',
  'comment.outer', 'comment.inner',
  'conditional.outer', 'conditional.inner',
  'loop.outer', 'loop.inner',
]

def TextObjectPlug(spec: string): string
  return '<Plug>(simpletreesitter-textobj-' .. substitute(spec, '\.', '-', '') .. ')'
enddef

# 每个类别都给 <Plug>，不用默认键的人也能自己接。
# 用 :<C-u>call 而不是 <Cmd>：函数要把用户带进可视模式，<Cmd> 映射不许换模式。
# 可视模式那份多传一个真值：:<C-u> 已经把用户带出了可视模式，对象答不出来时
# 要靠它 gv 把选区还回去，否则后续按键会掉进普通模式改文件。
for spec in TEXTOBJECT_SPECS
  execute printf('xnoremap <silent> %s :<C-u>call simpletreesitter#TextObject(%s, v:true)<CR>',
    TextObjectPlug(spec), string(spec))
  execute printf('onoremap <silent> %s :<C-u>call simpletreesitter#TextObject(%s)<CR>',
    TextObjectPlug(spec), string(spec))
endfor

nnoremap <silent> <Plug>(simpletreesitter-select-init) :<C-u>call simpletreesitter#SelectInit()<CR>
xnoremap <silent> <Plug>(simpletreesitter-select-expand) :<C-u>call simpletreesitter#SelectExpand()<CR>
xnoremap <silent> <Plug>(simpletreesitter-select-shrink) :<C-u>call simpletreesitter#SelectShrink()<CR>

if get(g:, 'simpletreesitter_textobject_maps', 1)
    && type(g:simpletreesitter_textobjects) == v:t_dict
  for [lhs, spec] in items(g:simpletreesitter_textobjects)
    # 一个拼错的 spec 会静默装成一个什么都不选的键；说出来比让人去猜好。
    if type(spec) != v:t_string || index(TEXTOBJECT_SPECS, spec) < 0
      echohl WarningMsg
      echom '[ts-hl] g:simpletreesitter_textobjects[' .. string(lhs) .. ']: unknown text object ' .. string(spec)
      echohl None
      continue
    endif
    for mode in ['x', 'o']
      if maparg(lhs, mode) ==# '' && !hasmapto(TextObjectPlug(spec), mode)
        execute mode .. 'map <silent> ' .. lhs .. ' ' .. TextObjectPlug(spec)
      endif
    endfor
  endfor
endif

if type(g:simpletreesitter_selection_maps) == v:t_dict
  for [action, mode] in [['init', 'n'], ['expand', 'x'], ['shrink', 'x']]
    var key = get(g:simpletreesitter_selection_maps, action, '')
    var plug = '<Plug>(simpletreesitter-select-' .. action .. ')'
    if type(key) == v:t_string && key !=# ''
        && maparg(key, mode) ==# '' && !hasmapto(plug, mode)
      execute mode .. 'map <silent> ' .. key .. ' ' .. plug
    endif
  endfor
endif

if maparg('<leader>th', 'n') ==# '' && !hasmapto('<Plug>(simpletreesitter-toggle)', 'n')
  nmap <silent> <leader>th <Plug>(simpletreesitter-toggle)
endif
if maparg('<leader>to', 'n') ==# '' && !hasmapto('<Plug>(simpletreesitter-outline-toggle)', 'n')
  nmap <silent> <leader>to <Plug>(simpletreesitter-outline-toggle)
endif

# =============== 自动启动逻辑 ===============
# SimpleRemote (virtual remote:// workspaces) fills a buffer asynchronously
# and announces it with User SimpleRemoteBufferRead; the payload names the
# buffer, which is not necessarily the current one.  The handler must never
# let an error escape into the emitter's read completion, and a one-line
# `try | call ... | catch | endtry` inside an :autocmd does not catch in Vim9,
# so the guard is a function.
def OnRemoteBufferRead()
  try
    simpletreesitter#OnRemoteBufferRead(get(get(g:, 'simpleremote_event', {}), 'bufnr', bufnr()))
  catch
  endtry
enddef

augroup TsHlAutoStart
  autocmd!
  autocmd BufEnter,FileType * call simpletreesitter#OnBufEvent(bufnr())
  # Registered unconditionally: without SimpleRemote nothing ever fires it.
  autocmd User SimpleRemoteBufferRead call OnRemoteBufferRead()
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
