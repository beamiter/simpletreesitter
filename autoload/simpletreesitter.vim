vim9script

# =============== 状态 ===============
var s_enabled: bool = false
var s_daemon_generation: number = 0
var s_protocol_version: number = 0
var s_protocol_notice_shown: bool = false
var s_active_bufs: dict<bool> = {}
# 每个缓冲的请求定时器
var s_req_timers: dict<number> = {}
# 缓冲文本同步定时器（set_text）
var s_sync_timers: dict<number> = {}
# 正在同步（等待 daemon ok）
var s_inflight_sync: dict<bool> = {}
# 正在同步的精确 changedtick；daemon 必须在 OK 中原样回传
var s_inflight_revision: dict<number> = {}
# daemon 已确认的 changedtick（避免重复 set_text）
var s_sent_changedtick: dict<number> = {}
# 因体积限制跳过的 changedtick；变化后会自动重新评估
var s_skipped_changedtick: dict<number> = {}
var s_oversized_notified: dict<bool> = {}
# AST 请求需要等待对应 revision 同步完成
var s_pending_ast: dict<bool> = {}
# :TsHlInspect 同样要等 revision 对齐；条目本身就是"已请求"标记，并记住发起时的
# 位置与 bang，避免用响应到达时"碰巧"的光标位置作答。
# buf -> {lnum, col, verbose}
var s_pending_inspect: dict<dict<any>> = {}
# daemon 在 hello 里通告的能力集合。加法式请求（inspect）用它做门控，这样一个
# 未重建的旧 daemon 得到的是一句可执行的提示，而不是 "unknown variant"。
var s_daemon_capabilities: dict<bool> = {}
# 上次应用的可见范围缓存 {bufnr: [start_lnum, end_lnum]}
var s_last_ranges: dict<list<number>> = {}
# 上次实际写入的高亮类型 {bufnr: [type, ...]}，用于增量清除（只清自己用过的类型）
var s_applied_types: dict<list<string>> = {}
# =============== 侧边栏状态 ===============
var s_outline_win: number = 0
var s_outline_buf: number = 0
var s_outline_src_buf: number = 0
var s_outline_src_win: number = 0
# The last accepted daemon payload stays unfiltered. Interactive filtering can
# therefore run before the render limit and clear instantly without sending a
# new symbols request.
var s_outline_raw_items: list<dict<any>> = []
var s_outline_raw_valid: bool = false
var s_outline_filter: string = ''
var s_outline_items: list<dict<any>> = []
var s_outline_linemap: list<number> = []  # 每一可见行对应 s_outline_items 的下标，-1 表示不可跳转
var s_outline_idx_to_lnum: dict<number> = {}  # s_outline_items 下标 -> outline 行号（光标跟随 O(1) 反查）
var s_last_outline_sig: string = ''  # 上次渲染的符号签名，未变则跳过整树重建
var s_outline_cursor_timer: number = 0  # 光标跟随防抖定时器
var s_sym_timer: number = 0
var s_inflight_syms: dict<bool> = {}
var s_inflight_hl: dict<bool> = {}
var s_pending_syms: dict<bool> = {}
var s_pending_hl: dict<bool> = {}
# BufUnload 后保留 tombstone，阻止同一 daemon 会话中迟到的 ACK/事件复活状态。
var s_closed_bufs: dict<bool> = {}
var s_user_disabled: bool = false
# =============== 增量同步状态（protocol v3） ===============
# buf -> listener id（listener_add 返回值）
var s_listener_ids: dict<number> = {}
# buf -> 自上次发送以来累计的行级变更 {os, oe, ne}：
# 旧文本（上次发送快照）中被替换的 [os, oe) 行区间，及其在当前 buffer 中的
# 新终点 ne（1-based，end-exclusive）。
var s_pending_splice: dict<dict<number>> = {}
# =============== 折叠状态 ===============
var s_inflight_folds: dict<bool> = {}
var s_pending_folds: dict<bool> = {}
# buf -> 每行 foldexpr 取值（'>1'、'2'、'0' 等）
var s_fold_exprs: dict<list<string>> = {}
# winid -> {method: string, expr: string} 应用折叠前的窗口设置
var s_fold_windows: dict<dict<string>> = {}
# =============== 符号 location list 请求 ===============
var s_loclist_pending: dict<bool> = {}
# 当前 symbols 请求的用途：partial 只覆盖视口，full 服务 loclist/导航。
var s_symbol_request_purpose: dict<string> = {}
# Kind filter sent with the inflight symbol request, used to validate/cache the
# response without consulting mutable global configuration later.
var s_symbol_request_kinds: dict<list<string>> = {}
# Protocol-v5 correlation token for the one inflight symbols request per buf.
# The counter stays monotonic across buffer close/reopen so a reused bufnr can
# never accept a late reply from its previous lifetime.
var s_next_symbol_request_id: number = 0
var s_symbol_request_ids: dict<number> = {}
# Last full-buffer response per buffer, keyed by revision and kind snapshot.
var s_full_symbol_cache: dict<dict<any>> = {}
# buf -> {steps, winid, lnum, col, changedtick}。导航响应必须回到发起窗口，
# 不能以响应到达时的当前窗口/光标为准。
var s_symbol_jump_pending: dict<dict<any>> = {}

# 待用的 TS 高亮组 -> Vim 高亮组 默认链接
const s_groups = [
  'TSComment', 'TSString', 'TStringRegex', 'TStringEscape', 'TStringSpecial',
  'TSNumber', 'TSBoolean', 'TSConstant', 'TSConstBuiltin',
  'TSKeyword', 'TSKeywordOperator', 'TSOperator',
  'TSPunctDelimiter', 'TSPunctBracket',
  'TSFunction', 'TSFunctionBuiltin', 'TSMethod',
  'TSType', 'TSTypeBuiltin', 'TSNamespace',
  'TSVariable', 'TSVariableParameter', 'TSVariableBuiltin',
  'TSProperty', 'TSField',
  'TSMacro', 'TSAttribute',
  'TSVariant',
  'TSTitle', 'TSLiteral', 'TSEmphasis', 'TSStrong', 'TSStrike',
  'TSURI', 'TSLink',
  'TSRainbow1', 'TSRainbow2', 'TSRainbow3',
  'TSRainbow4', 'TSRainbow5', 'TSRainbow6'
  ]
const s_prop_prefix = 'SimpleTreeSitter_'
const s_outline_guide_prop = 'SimpleTreeSitter_OutlineGuide'
const s_outline_pos_prop = 'SimpleTreeSitter_OutlinePos'
const s_outline_cursor_prop = 'SimpleTreeSitter_OutlineCursor'
const s_language_by_filetype = {
  rust: 'rust',
  c: 'c',
  cpp: 'cpp',
  cc: 'cpp',
  javascript: 'javascript',
  javascriptreact: 'javascript',
  jsx: 'javascript',
  typescript: 'typescript',
  typescriptreact: 'tsx',
  python: 'python',
  go: 'go',
  sh: 'bash',
  bash: 'bash',
  zsh: 'bash',
  vim: 'vim',
  vimrc: 'vim',
  json: 'json',
  jsonc: 'json',
  yaml: 'yaml',
  toml: 'toml',
  lua: 'lua',
  html: 'html',
  css: 'css',
  markdown: 'markdown',
}

# =============== 面包屑状态 ===============
var s_bc_items: list<dict<any>> = []
var s_bc_buf: number = 0
var s_bc_timer: number = 0
# winid (as a string key) -> the breadcrumb that window's own cursor produced.
# Every window's 'winbar' holds the same fixed %{simpletreesitter#Breadcrumb()}
# expression, so a single script-global string made all of them render whichever
# window was updated last: split a file, leave the cursor in `foo` above and move
# into `bar` below, and the top window started advertising `bar`.  Vim evaluates
# %{} with the drawn window temporarily current (see |stl-%{|), so keying on
# win_getid() gives each window back its own text.
var s_breadcrumb_cache: dict<string> = {}
# =============== Outline 跟随状态 ===============
var s_outline_cursor_line: number = 0
# =============== Outline 折叠状态 ===============
var s_outline_collapsed: dict<bool> = {}
var s_outline_state_buf: number = 0
# =============== 缩进参考线状态 ===============
# winid -> {list: bool, listchars: string}
var s_indent_guide_windows: dict<dict<any>> = {}

# =============== Outline 的每标签页上下文 ===============
# The Outline is one sidebar per tabpage.  All the s_outline_* variables above
# describe exactly one of them — the tabpage whose id is s_outline_ctx — and
# entering another tabpage swaps the whole set.  Indexing every read by tabpage
# instead would touch the render, filter, cursor-follow, jump and fold paths;
# swapping one working set leaves them all written as if tabs did not exist.
#
# Vim gives a tabpage no stable numeric identity (tabpagenr() renumbers on every
# :tabclose, which is why win_id2win() on a stored window id silently reads 0
# for a sidebar living in another tab).  Tab-local variables do travel with the
# tabpage and are freed with it, so both the identity and the stashed state live
# in t:.
var s_outline_ctx: number = 0
var s_next_outline_ctx: number = 0
const s_outline_ctx_var = 'simpletreesitter_outline_ctx'
const s_outline_state_var = 'simpletreesitter_outline_state'

def OutlineCtxId(): number
  var ctx = gettabvar(tabpagenr(), s_outline_ctx_var, 0)
  if type(ctx) != v:t_number || ctx <= 0
    s_next_outline_ctx += 1
    ctx = s_next_outline_ctx
    settabvar(tabpagenr(), s_outline_ctx_var, ctx)
  endif
  return ctx
enddef

def CaptureOutlineState(): dict<any>
  return {
    win: s_outline_win,
    buf: s_outline_buf,
    src_buf: s_outline_src_buf,
    src_win: s_outline_src_win,
    raw_items: s_outline_raw_items,
    raw_valid: s_outline_raw_valid,
    filter: s_outline_filter,
    items: s_outline_items,
    linemap: s_outline_linemap,
    idx_to_lnum: s_outline_idx_to_lnum,
    sig: s_last_outline_sig,
    collapsed: s_outline_collapsed,
    state_buf: s_outline_state_buf,
    cursor_line: s_outline_cursor_line,
  }
enddef

def ResetOutlineState()
  s_outline_win = 0
  s_outline_buf = 0
  s_outline_src_buf = 0
  s_outline_src_win = 0
  s_outline_raw_items = []
  s_outline_raw_valid = false
  s_outline_filter = ''
  s_outline_items = []
  s_outline_linemap = []
  s_outline_idx_to_lnum = {}
  s_last_outline_sig = ''
  s_outline_collapsed = {}
  s_outline_state_buf = 0
  s_outline_cursor_line = 0
enddef

def LoadOutlineState(state: dict<any>)
  s_outline_win = get(state, 'win', 0)
  s_outline_buf = get(state, 'buf', 0)
  s_outline_src_buf = get(state, 'src_buf', 0)
  s_outline_src_win = get(state, 'src_win', 0)
  s_outline_raw_items = get(state, 'raw_items', [])
  s_outline_raw_valid = get(state, 'raw_valid', false)
  s_outline_filter = get(state, 'filter', '')
  s_outline_items = get(state, 'items', [])
  s_outline_linemap = get(state, 'linemap', [])
  s_outline_idx_to_lnum = get(state, 'idx_to_lnum', {})
  s_last_outline_sig = get(state, 'sig', '')
  s_outline_collapsed = get(state, 'collapsed', {})
  s_outline_state_buf = get(state, 'state_buf', 0)
  s_outline_cursor_line = get(state, 'cursor_line', 0)
enddef

# Every Outline entry point calls this first.  TabEnter is the usual trigger,
# but win_gotoid() across tabpages, :tabdo and a <CR> in a sidebar mapping can
# all reach the Outline without one, and running a mapping against another
# tabpage's line map is precisely the bug this replaces.
def SyncOutlineContext()
  var ctx = OutlineCtxId()
  if ctx == s_outline_ctx
    return
  endif
  if s_outline_ctx != 0
    # The tabpage being left may already be gone (:tabclose), in which case its
    # t: dictionary went with it and there is nothing left to write back.
    for nr in range(1, tabpagenr('$'))
      if gettabvar(nr, s_outline_ctx_var, 0) == s_outline_ctx
        settabvar(nr, s_outline_state_var, CaptureOutlineState())
        break
      endif
    endfor
  endif
  s_outline_ctx = ctx
  var saved = gettabvar(tabpagenr(), s_outline_state_var, {})
  if type(saved) == v:t_dict && !empty(saved)
    LoadOutlineState(saved)
  else
    ResetOutlineState()
  endif
enddef

# Window ids of every tabpage's sidebar, current tabpage included.  Used where
# the question really is global — "may the daemon stop?", "close everything".
def AllOutlineWins(): list<number>
  var wins: list<number> = []
  for nr in range(1, tabpagenr('$'))
    var wid = 0
    if gettabvar(nr, s_outline_ctx_var, 0) == s_outline_ctx
      wid = s_outline_win
    else
      var saved = gettabvar(nr, s_outline_state_var, {})
      if type(saved) == v:t_dict
        wid = get(saved, 'win', 0)
      endif
    endif
    if wid != 0 && !empty(getwininfo(wid))
      wins->add(wid)
    endif
  endfor
  return wins
enddef

# =============== 工具 ===============

def HlProp(group: string): string
  return s_prop_prefix .. group
enddef

# 只清除 simpletreesitter 自己的 text properties，不影响其它插件（如 coc.nvim 虚拟文本）
# types 为空时清除全部高亮组；否则只清除指定的类型（增量清除，避免对 33 个组逐一
# 调用 prop_remove）。
def ClearOwnProps(start_lnum: number, end_lnum: number, buf: number, types: list<string> = [])
  var prop_types = types
  if empty(prop_types)
    prop_types = []
    for group in s_groups
      prop_types->add(HlProp(group))
    endfor
  endif
  for prop_type in prop_types
    try
      prop_remove({type: prop_type, bufnr: buf, all: true}, start_lnum, end_lnum)
    catch
    endtry
  endfor
  try
    prop_remove({type: s_outline_guide_prop, bufnr: buf, all: true}, start_lnum, end_lnum)
  catch
  endtry
  try
    prop_remove({type: s_outline_pos_prop, bufnr: buf, all: true}, start_lnum, end_lnum)
  catch
  endtry
enddef

def Log(msg: string)
  if get(g:, 'simpletreesitter_debug', 0)
    var lf = get(g:, 'simpletreesitter_log_file', '')
    if type(lf) == v:t_string && lf !=# ''
      try
        call writefile(['[ts-hl] ' .. msg], lf, 'a')
      catch
      endtry
    else
      echom '[ts-hl] ' .. msg
    endif
  endif
enddef

def DetectLang(buf: number): string
  var ft = getbufvar(buf, '&filetype')
  if ft ==# 'c'
    # .h files may contain C++ code; detect C++ features and use cpp parser
    var ext = fnamemodify(bufname(buf), ':e')
    if ext =~? '^h$\|^hh$\|^hpp$\|^hxx$'
      var lines = getbufline(buf, 1, 200)
      var text = join(lines, "\n")
      if text =~# '\<enum\s\+class\>\|\<class\s\+\w\+\s*[:{]\|\<namespace\s\+\w\|\<template\s*<\|\<using\s\+namespace\>\|\<public\s*:\|\<private\s*:\|\<protected\s*:'
        return 'cpp'
      endif
    endif
  endif
  return get(s_language_by_filetype, ft, '')
enddef

def IsSupportedLang(buf: number): bool
  if !bufexists(buf) || !bufloaded(buf) || getbufvar(buf, '&buftype') !=# ''
    return false
  endif
  if getbufvar(buf, 'simpletreesitter_disable', 0)
    return false
  endif
  return has_key(s_language_by_filetype, getbufvar(buf, '&filetype'))
enddef

def EnsureHlGroupsAndProps()
  highlight default link TSComment Comment
  highlight default link TSString String
  highlight default link TStringRegex String
  highlight default link TStringEscape SpecialChar
  highlight default link TStringSpecial Special
  highlight default link TSNumber Number
  highlight default link TSBoolean Boolean
  highlight default link TSConstant Constant
  highlight default link TSConstBuiltin Constant

  highlight default link TSKeyword Keyword
  highlight default link TSKeywordOperator Keyword
  highlight default link TSOperator Operator
  highlight default link TSPunctDelimiter Delimiter
  highlight default link TSPunctBracket Delimiter

  highlight default link TSFunction Function
  highlight default link TSFunctionBuiltin Function
  highlight default link TSMethod Function

  highlight default link TSType Type
  highlight default link TSTypeBuiltin Type
  highlight default link TSNamespace Include

  highlight default link TSVariable Identifier
  highlight default link TSVariableParameter Identifier
  highlight default link TSProperty Identifier
  highlight default link TSField Identifier
  highlight default link TSVariableBuiltin Constant

  highlight default link TSMacro Macro
  highlight default link TSAttribute PreProc
  highlight default link TSVariant Constant

  # Markdown / prose
  highlight default link TSTitle Title
  highlight default link TSLiteral String
  highlight default TSEmphasis cterm=italic gui=italic
  highlight default TSStrong cterm=bold gui=bold
  highlight default TSStrike cterm=strikethrough gui=strikethrough
  highlight default link TSURI Underlined
  highlight default link TSLink Identifier

  # Rainbow brackets
  highlight default TSRainbow1 ctermfg=168 guifg=#e06c75
  highlight default TSRainbow2 ctermfg=180 guifg=#e5c07b
  highlight default TSRainbow3 ctermfg=75  guifg=#61afef
  highlight default TSRainbow4 ctermfg=176 guifg=#c678dd
  highlight default TSRainbow5 ctermfg=73  guifg=#56b6c2
  highlight default TSRainbow6 ctermfg=114 guifg=#98c379

  highlight default link TsHlOutlineGuide Comment
  highlight default link TsHlOutlinePos LineNr
  # Outline cursor follow
  highlight default TsHlOutlineCursor ctermbg=238 guibg=#2c323c

  for g in s_groups
    try
      call prop_type_add(HlProp(g), {highlight: g, combine: v:false, priority: 11, override: v:true})
    catch
    endtry
  endfor
  try
    call prop_type_add(s_outline_guide_prop, {highlight: 'TsHlOutlineGuide', combine: v:true, priority: 12})
  catch
  endtry
  try
    call prop_type_add(s_outline_pos_prop, {highlight: 'TsHlOutlinePos', combine: v:true, priority: 12})
  catch
  endtry
  try
    call prop_type_add(s_outline_cursor_prop, {highlight: 'TsHlOutlineCursor', combine: v:true, priority: 13})
  catch
  endtry
enddef

# The vendored simplecore supervisor owns the daemon process: job_status-based
# liveness (a 'fail' job is never mistaken for a live one), generation-guarded
# callbacks, exponential-backoff restarts and a crash-loop breaker.
var s_core_ready: bool = false

def SetupCore()
  if s_core_ready
    return
  endif
  s_core_ready = true
  simpletreesitter#core#Setup({
    name: 'ts-hl',
    exe: 'ts-hl-daemon',
    path_var: 'simpletreesitter_daemon_path',
    debug_var: 'simpletreesitter_debug',
    OnEvent: OnDaemonEvent,
    OnStart: OnDaemonStart,
    OnExit: OnDaemonExit,
  })
enddef

def FindDaemon(): string
  SetupCore()
  return simpletreesitter#core#FindExe()
enddef

# A new process has no buffer cache, so every buffer must re-handshake.
def OnDaemonStart()
  InvalidateDaemonSession()
  EnsureHlGroupsAndProps()
  simpletreesitter#core#Send({type: 'hello', client_protocol: 5})
enddef

def OnDaemonExit(code: number, restarting: bool)
  s_protocol_version = 0
  InvalidateDaemonSession()
  if restarting
    Log('daemon exited with code ' .. code .. '; restarting')
  endif
enddef

def BufLineCount(buf: number): number
  var info = getbufinfo(buf)
  if type(info) == v:t_list && len(info) > 0 && has_key(info[0], 'linecount')
    return info[0].linecount
  endif
  return len(getbufline(buf, 1, '$'))
enddef

# 在构造整份文本前做有界字节预检。普通、未修改的 UTF-8/Unix 文件可直接用
# 磁盘大小；未保存、已修改或经过编码/换行转换的 buffer 按小块精确计数，且一旦
# 越过阈值立即停止，避免为超大 buffer 分配完整副本。
def BufferTextExceedsLimit(buf: number, max_bytes: number): bool
  if max_bytes <= 0
    return false
  endif

  var name = bufname(buf)
  var fileencoding = getbufvar(buf, '&fileencoding')
  if !getbufvar(buf, '&modified') && name !=# '' && filereadable(name)
      && (fileencoding ==# '' || fileencoding ==# 'utf-8')
      && getbufvar(buf, '&fileformat') ==# 'unix'
      && !getbufvar(buf, '&bomb')
    var disk_bytes = getfsize(name)
    if disk_bytes >= 0
      return disk_bytes > max_bytes
    endif
  endif

  # wordcount().bytes 直接遍历当前 buffer 的内部行存储，不构造字符串副本，且会
  # 固定计入一个末尾换行；按 &endofline 修正后才与发送文本严格一致。
  if buf == bufnr()
    var buffer_bytes = get(wordcount(), 'bytes', 0)
    if !getbufvar(buf, '&endofline') && BufLineCount(buf) > 0
      buffer_bytes -= 1
    endif
    return buffer_bytes > max_bytes
  endif

  var total = 0
  var line_count = BufLineCount(buf)
  var has_eol = getbufvar(buf, '&endofline') ? true : false
  var start = 1
  const chunk_size = 256
  while start <= line_count
    var chunk = getbufline(buf, start, min([line_count, start + chunk_size - 1]))
    if empty(chunk)
      break
    endif
    var current = start
    for text_line in chunk
      total += strlen(text_line)
      if current < line_count || has_eol
        total += 1
      endif
      if total > max_bytes
        return true
      endif
      current += 1
    endfor
    start += len(chunk)
  endwhile
  return false
enddef

def VisibleViewportRangeForBuf(buf: number): list<number>
  var lnum_end = BufLineCount(buf)
  var wins = win_findbuf(buf)
  if len(wins) == 0
    return [1, lnum_end]
  endif
  var start = lnum_end
  var stop  = 1
  for w in wins
    var info = getwininfo(w)[0]
    start = min([start, info.topline])
    stop  = max([stop, info.botline])
  endfor
  return [start, stop]
enddef

def VisibleRangeForBufWithMargin(buf: number, margin: number): list<number>
  var lnum_end = BufLineCount(buf)
  var wins = win_findbuf(buf)
  if len(wins) == 0
    return [1, lnum_end]
  endif
  var start = lnum_end
  var stop  = 1
  for w in wins
    var info = getwininfo(w)[0]
    start = min([start, info.topline])
    stop  = max([stop, info.botline])
  endfor
  start = max([1, start - margin])
  stop  = min([lnum_end, stop + margin])
  return [start, stop]
enddef

def VisibleRangeForBuf(buf: number): list<number>
  var margin = get(g:, 'simpletreesitter_view_margin', 120)
  return VisibleRangeForBufWithMargin(buf, margin)
enddef

def VisibleRangeForBufSymbols(buf: number): list<number>
  var margin = get(g:, 'simpletreesitter_symbols_view_margin', 500)
  return VisibleRangeForBufWithMargin(buf, margin)
enddef

def ApplyHighlights(buf: number, spans: list<dict<any>>)
  if !bufexists(buf)
    return
  endif
  var [vstart, vend] = VisibleRangeForBuf(buf)
  if has_key(s_last_ranges, buf)
    var prev = s_last_ranges[buf]
    if len(prev) == 2 && prev[1] >= prev[0]
      # 只清除上轮真正写入过的类型，而不是全部 33 个组。
      ClearOwnProps(prev[0], prev[1], buf, get(s_applied_types, buf, []))
    endif
  endif

  var applied = 0
  var max_props = get(g:, 'simpletreesitter_max_props', 20000)

  # 按类型分桶，最后用 prop_add_list 一次性提交，省去逐 span 调用 prop_add 的开销。
  var by_type: dict<list<list<number>>> = {}
  for s in spans
    var l1 = get(s, 'lnum', 1)
    var l2 = get(s, 'end_lnum', l1)
    if l2 < vstart || l1 > vend
      continue
    endif
    if l1 <= 0 || l2 <= 0
      continue
    endif
    var c1 = max([1, get(s, 'col', 1)])
    var c2 = max([1, get(s, 'end_col', c1)])
    var tp = get(s, 'group', 'TSVariable')
    # Rainbow brackets: 用深度对应的彩虹颜色替换 TSPunctBracket
    if tp ==# 'TSPunctBracket' && get(g:, 'simpletreesitter_rainbow_brackets', 1)
      var depth = get(s, 'depth', 0)
      if depth > 0
        tp = 'TSRainbow' .. string(((depth - 1) % 6) + 1)
      endif
    endif
    var prop_type = HlProp(tp)
    if !has_key(by_type, prop_type)
      by_type[prop_type] = []
    endif
    by_type[prop_type]->add([l1, c1, l2, c2])
    applied += 1
    if applied >= max_props
      break
    endif
  endfor

  for [tp, positions] in items(by_type)
    try
      call prop_add_list({type: tp, bufnr: buf}, positions)
    catch
    endtry
  endfor

  s_last_ranges[buf] = [vstart, vend]
  s_applied_types[buf] = keys(by_type)
enddef

# Daemon errors the plugin recovers from on its own by forcing a full resync:
# 'buffer not cached' after the daemon evicts from its 128-entry cache, and the
# two incremental-sync divergence checks.  One predicate so the message that
# suppresses the echo can never drift from the message that triggers the
# recovery — this used to be the same regexp written out three times.
def RecoverableDaemonError(message: string): bool
  return message =~# 'buffer not cached\|lang mismatch\|edit_lines mismatch'
enddef

def ResetProtocolState()
  s_inflight_sync = {}
  s_inflight_revision = {}
  s_sent_changedtick = {}
  s_skipped_changedtick = {}
  s_oversized_notified = {}
  s_inflight_hl = {}
  s_inflight_syms = {}
  s_pending_hl = {}
  s_pending_syms = {}
  s_pending_ast = {}
  s_pending_inspect = {}
  s_daemon_capabilities = {}
  s_pending_splice = {}
  s_inflight_folds = {}
  s_pending_folds = {}
  s_loclist_pending = {}
  s_symbol_request_purpose = {}
  s_symbol_request_kinds = {}
  s_symbol_request_ids = {}
  s_full_symbol_cache = {}
  s_symbol_jump_pending = {}
  s_protocol_version = 0
enddef

def InvalidateDaemonSession()
  s_daemon_generation += 1
  ResetProtocolState()
enddef

def EventRevisionIsCurrent(ev: dict<any>, buf: number): bool
  if !bufexists(buf)
    return false
  endif
  var acknowledged = get(s_sent_changedtick, buf, -1)
  # 缺少 revision 时回退到 acknowledged，兼容旧 daemon。
  var revision = get(ev, 'revision', acknowledged)
  return revision == acknowledged && revision == GetChangedTick(buf)
enddef

def NextSymbolRequestId(): number
  s_next_symbol_request_id += 1
  return s_next_symbol_request_id
enddef

def ClearSymbolRequestId(buf: number)
  if has_key(s_symbol_request_ids, buf)
    remove(s_symbol_request_ids, string(buf))
  endif
enddef

# v5 correlates success and error with the exact request. A v4 daemon ignores
# the additive request_id field and omits it in replies, so it deliberately
# retains the existing revision/op/kind guards instead of losing functionality.
def SymbolEventMatchesCurrent(ev: dict<any>, buf: number): bool
  if s_protocol_version < 5
    return true
  endif
  var expected = get(s_symbol_request_ids, buf, 0)
  var received = get(ev, 'request_id', 0)
  if expected <= 0 || received != expected
    Log(printf('Discarded stale symbols event for buffer %d (request=%d expected=%d)',
      buf, received, expected))
    return false
  endif
  return true
enddef

def OnDaemonEvent(ev: dict<any>)
  if !has_key(ev, 'type')
    return
  endif
  var event_buf = get(ev, 'buf', 0)
  if event_buf > 0 && get(s_closed_bufs, event_buf, false)
    Log('Discarded event for closed buffer ' .. event_buf)
    return
  endif
  if ev.type ==# 'highlights'
    var buf = get(ev, 'buf', 0)
    var retry = get(s_pending_hl, buf, false)
    s_inflight_hl[buf] = false
    s_pending_hl[buf] = false
    if IsHighlightSuspended(buf)
      return
    endif
    if !EventRevisionIsCurrent(ev, buf)
      Log('Discarded stale highlights for buffer ' .. buf)
      ScheduleSync(buf)
      return
    endif
    var spans = get(ev, 'spans', [])
    ApplyHighlights(buf, spans)
    if retry
      ScheduleRequest(buf, 'scroll')
    endif
  elseif ev.type ==# 'symbols'
    var buf = get(ev, 'buf', 0)
    if !SymbolEventMatchesCurrent(ev, buf)
      return
    endif
    var retry = get(s_pending_syms, buf, false)
    var purpose = get(s_symbol_request_purpose, buf, '')
    var was_full = purpose ==# 'full'
    var request_kinds = get(s_symbol_request_kinds, buf, [])
    s_inflight_syms[buf] = false
    s_pending_syms[buf] = false
    ClearSymbolRequestId(buf)
    if has_key(s_symbol_request_purpose, buf)
      remove(s_symbol_request_purpose, string(buf))
    endif
    if has_key(s_symbol_request_kinds, buf)
      remove(s_symbol_request_kinds, string(buf))
    endif
    if !EventRevisionIsCurrent(ev, buf)
      Log('Discarded stale symbols for buffer ' .. buf)
      ScheduleSync(buf)
      return
    endif
    var syms = get(ev, 'symbols', [])
    # 面包屑：保存符号数据
    SetBreadcrumbItems(buf, syms)
    if was_full
      s_full_symbol_cache[buf] = {
        revision: GetChangedTick(buf),
        kinds: copy(request_kinds),
        symbols: syms,
      }
      ConsumeFullSymbols(buf, syms, request_kinds)
    else
      ApplySymbols(buf, syms)
    endif
    # A partial outline response cannot satisfy loclist/navigation consumers;
    # serialize one full-buffer request behind it.
    if get(s_loclist_pending, buf, false) || has_key(s_symbol_jump_pending, buf)
      RequestFullSymbols(buf)
    elseif retry
      ScheduleSymbols(buf)
    endif
  elseif ev.type ==# 'ast'
    var buf = get(ev, 'buf', 0)
    if !EventRevisionIsCurrent(ev, buf)
      s_pending_ast[buf] = true
      ScheduleSync(buf)
      return
    endif
    var lines = get(ev, 'lines', [])
    ShowAst(buf, lines)
  elseif ev.type ==# 'inspect'
    var buf = get(ev, 'buf', 0)
    if !EventRevisionIsCurrent(ev, buf)
      # 报告会描述已经不存在的文本；保留 pending，同步完成后按原位置重问。
      ScheduleSync(buf)
      return
    endif
    var req = get(s_pending_inspect, buf, {})
    if empty(req)
      # 没有在等的请求，说明这是上一次会话或已取消请求的迟到回复。
      return
    endif
    remove(s_pending_inspect, string(buf))
    ShowInspect(InspectReportLines(ev, DetectLang(buf), get(req, 'verbose', false)))
  elseif ev.type ==# 'folds'
    var buf = get(ev, 'buf', 0)
    var retry = get(s_pending_folds, buf, false)
    s_inflight_folds[buf] = false
    s_pending_folds[buf] = false
    if !EventRevisionIsCurrent(ev, buf)
      Log('Discarded stale folds for buffer ' .. buf)
      ScheduleSync(buf)
      return
    endif
    ApplyFolds(buf, get(ev, 'folds', []))
    if retry
      ScheduleFolds(buf)
    endif
  elseif ev.type ==# 'ok'
    var buf = get(ev, 'buf', 0)
    var op  = get(ev, 'op', '')
    if op ==# 'set_text' || op ==# 'edit_lines'
      # 无对应在途请求的 ACK 必定来自已关闭 buffer 或旧请求，不能复活状态。
      if !has_key(s_inflight_revision, buf)
        Log('Ignored set_text ACK without an inflight revision for buffer ' .. buf)
        return
      endif
      var expected = s_inflight_revision[buf]
      var revision = get(ev, 'revision', expected)
      if revision != expected
        Log('Ignored unexpected set_text ACK for buffer ' .. buf)
        return
      endif
      s_inflight_sync[buf] = false
      if has_key(s_inflight_revision, buf)
        remove(s_inflight_revision, string(buf))
      endif
      s_sent_changedtick[buf] = revision
      if !bufexists(buf)
        return
      endif
      # ACK 对应发送时的快照，而不是回调时“碰巧”的当前文本。
      if GetChangedTick(buf) != revision
        ScheduleSync(buf)
        return
      endif
      # 收到 OK 后触发当前缓冲的请求
      if !IsHighlightSuspended(buf)
        ScheduleRequest(buf, 'edit')
      endif
      ScheduleSymbols(buf)
      ScheduleFolds(buf)
      if get(s_loclist_pending, buf, false)
        RequestFullSymbols(buf)
      endif
      if has_key(s_symbol_jump_pending, buf)
        RequestFullSymbols(buf)
      endif
      if get(s_pending_ast, buf, false)
        s_pending_ast[buf] = false
        RequestAstNow(buf)
      endif
      if has_key(s_pending_inspect, buf)
        RequestInspectNow(buf)
      endif
    endif
  elseif ev.type ==# 'hello'
    s_protocol_version = get(ev, 'protocol_version', 0)
    s_daemon_capabilities = {}
    for cap in get(ev, 'capabilities', [])
      if type(cap) == v:t_string
        s_daemon_capabilities[cap] = true
      endif
    endfor
    if s_protocol_version < 2 && !s_protocol_notice_shown
      s_protocol_notice_shown = true
      echohl WarningMsg
      echom '[ts-hl] daemon protocol is outdated; run install.sh to rebuild it'
      echohl None
    elseif s_protocol_version == 2 && !s_protocol_notice_shown
      s_protocol_notice_shown = true
      echohl WarningMsg
      echom '[ts-hl] daemon protocol is v2; run install.sh to enable incremental sync and folds'
      echohl None
    elseif s_protocol_version == 3 && !s_protocol_notice_shown
      s_protocol_notice_shown = true
      echohl WarningMsg
      echom '[ts-hl] daemon protocol is v3; run install.sh for filtered symbol navigation'
      echohl None
    elseif s_protocol_version == 4 && !s_protocol_notice_shown
      s_protocol_notice_shown = true
      echohl WarningMsg
      echom '[ts-hl] daemon protocol is v4; run install.sh for correlated symbol responses'
      echohl None
    endif
  elseif ev.type ==# 'status'
    echom printf('[ts-hl] daemon v%s protocol=%d | cache=%d/%d bytes evicted=%d | parse full=%d incremental=%d unchanged=%d | %s',
      get(ev, 'version', '?'), get(ev, 'protocol_version', 0), get(ev, 'cached_buffers', 0),
      get(ev, 'cached_bytes', 0), get(ev, 'cache_evictions', 0), get(ev, 'full_parses', 0),
      get(ev, 'incremental_parses', 0), get(ev, 'unchanged_syncs', 0),
      join(get(ev, 'languages', []), ', '))
  elseif ev.type ==# 'error'
    var buf = get(ev, 'buf', 0)
    var message = get(ev, 'message', '')
    var op = get(ev, 'op', '')
    if message =~# 'unknown variant.*hello'
      s_protocol_version = -1
      if !s_protocol_notice_shown
        s_protocol_notice_shown = true
        echohl WarningMsg
        echom '[ts-hl] daemon is from an older plugin version; run install.sh to rebuild it'
        echohl None
      endif
      return
    endif
    if buf > 0 && op ==# 'symbols' && !SymbolEventMatchesCurrent(ev, buf)
      return
    endif
    # 'buffer not cached' is what the daemon says after evicting a buffer from
    # its own 128-entry cache; 'lang mismatch' and 'edit_lines mismatch' are the
    # incremental-sync divergence checks.  All three are recovered a few lines
    # below by forcing a full resync, so echoing them only produced a hit-enter
    # prompt in the middle of typing for something the plugin had already fixed.
    if RecoverableDaemonError(message)
      Log('Recovering from daemon error: ' .. message)
    else
      echom '[ts-hl] error: ' .. message
    endif
    # protocol v4 的 error 带 op，只清理真正失败的请求类别。否则
    # highlight/fold 错误可能破坏同 buffer 的 full-symbol 用途归类。
    if buf > 0
      if op ==# 'symbols'
        s_inflight_syms[buf] = false
        s_pending_syms[buf] = false
        ClearSymbolRequestId(buf)
        if has_key(s_symbol_request_purpose, buf)
          remove(s_symbol_request_purpose, string(buf))
        endif
        if has_key(s_symbol_request_kinds, buf)
          remove(s_symbol_request_kinds, string(buf))
        endif
        if !RecoverableDaemonError(message)
          CancelSymbolConsumers(buf)
        endif
      elseif op ==# 'highlight'
        s_inflight_hl[buf] = false
      elseif op ==# 'folds'
        s_inflight_folds[buf] = false
      elseif op ==# 'inspect'
        # 一次失败的 inspect 不能一直挂着：下一次 set_text 的 ok 会重发它。
        if has_key(s_pending_inspect, buf)
          remove(s_pending_inspect, string(buf))
        endif
      elseif op ==# 'set_text' || op ==# 'edit_lines'
        s_inflight_sync[buf] = false
        if has_key(s_inflight_revision, buf)
          remove(s_inflight_revision, string(buf))
        endif
      elseif op ==# ''
        # 兼容 protocol v3 及更早 daemon 的无 op 错误。新 daemon 不走此分支。
        s_inflight_syms[buf] = false
        s_pending_syms[buf] = false
        ClearSymbolRequestId(buf)
        if has_key(s_symbol_request_purpose, buf)
          remove(s_symbol_request_purpose, string(buf))
        endif
        if has_key(s_symbol_request_kinds, buf)
          remove(s_symbol_request_kinds, string(buf))
        endif
        s_inflight_hl[buf] = false
        s_inflight_sync[buf] = false
        s_inflight_folds[buf] = false
        if has_key(s_inflight_revision, buf)
          remove(s_inflight_revision, string(buf))
        endif
      endif
      if RecoverableDaemonError(message)
        s_sent_changedtick[buf] = -1
        if has_key(s_pending_splice, buf)
          remove(s_pending_splice, string(buf))
        endif
        ScheduleSync(buf)
      endif
    endif
  endif
enddef

def EnsureDaemon(): bool
  SetupCore()
  return simpletreesitter#core#Ensure()
enddef

def Send(req: dict<any>): bool
  return simpletreesitter#core#Send(req)
enddef

def StopBufTimer(buf: number)
  if has_key(s_req_timers, buf) && s_req_timers[buf] != 0 && exists('*timer_stop')
    try
      call timer_stop(s_req_timers[buf])
    catch
    endtry
    s_req_timers[buf] = 0
  endif
enddef

def StopSyncTimer(buf: number)
  if has_key(s_sync_timers, buf) && s_sync_timers[buf] != 0 && exists('*timer_stop')
    try
      call timer_stop(s_sync_timers[buf])
    catch
    endtry
    s_sync_timers[buf] = 0
  endif
enddef

# =============== 全局暂停高亮：工具函数 ===============
def IsHighlightSuspended(buf: number): bool
  return s_outline_win != 0 && get(g:, 'simpletreesitter_suspend_highlight_on_outline', 0)
enddef

def ClearPropsForBuf(buf: number)
  if !bufexists(buf)
    return
  endif
  if getbufvar(buf, '&filetype') ==# 'simpletreesitter_outline'
    return
  endif
  if get(g:, 'simpletreesitter_clear_scope_on_suspend', 'visible') ==# 'buffer'
    var last = BufLineCount(buf)
    ClearOwnProps(1, last, buf)
  else
    var [vs, ve] = VisibleRangeForBuf(buf)
    ClearOwnProps(vs, ve, buf)
  endif
enddef

def ClearAllVisiblePropsOnSuspend()
  var cur = bufnr()
  if bufexists(cur) | ClearPropsForBuf(cur) | endif
  for [k, active] in items(s_active_bufs)
    if active
      var b = str2nr(k)
      if bufexists(b)
        ClearPropsForBuf(b)
      endif
    endif
  endfor
enddef

def ResumeAllHighlights()
  for [k, active] in items(s_active_bufs)
    if active
      var b = str2nr(k)
      if bufexists(b)
        ScheduleRequest(b, 'edit')
      endif
    endif
  endfor
  var cur = bufnr()
  if bufexists(cur)
    ScheduleRequest(cur, 'edit')
  endif
enddef

def GetChangedTick(buf: number): number
  var info = getbufinfo(buf)
  if type(info) == v:t_list && len(info) > 0 && has_key(info[0], 'changedtick')
    return info[0].changedtick
  endif
  return 0
enddef

# =============== 增量同步（protocol v3） ===============
# 把一次 listener 变更（当前坐标系中 [lnum, lend) 被替换为 [lnum, lend+added)）
# 合并进 buf 的累计 splice。累计状态 {os, oe, ne}：上次发送快照中 [os, oe) 行
# 被替换为当前 buffer 的 [os, ne) 行。
def MergeChange(buf: number, lnum: number, lend: number, added: number)
  if !has_key(s_pending_splice, buf)
    s_pending_splice[buf] = {os: lnum, oe: lend, ne: lend + added}
    return
  endif
  var sp = s_pending_splice[buf]
  # 当前坐标与旧坐标在累计区间下方相差 shift 行
  var shift = sp.ne - sp.oe
  var new_os = min([sp.os, lnum])
  var new_oe = sp.oe
  if lend >= sp.ne
    new_oe = max([sp.oe, lend - shift])
  endif
  var new_ne = sp.ne >= lend ? sp.ne + added : lend + added
  s_pending_splice[buf] = {os: new_os, oe: new_oe, ne: new_ne}
enddef

def OnBufLines(buf: number, _start: number, _lend: number, _added: number, changes: list<dict<any>>)
  if get(s_closed_bufs, buf, false)
    return
  endif
  for change in changes
    MergeChange(buf, get(change, 'lnum', 1), get(change, 'end', 1), get(change, 'added', 0))
  endfor
enddef

def EnsureListener(buf: number)
  if !get(g:, 'simpletreesitter_incremental_sync', 1)
    return
  endif
  if get(s_listener_ids, buf, 0) != 0
    return
  endif
  if !bufexists(buf) || !bufloaded(buf) || !exists('*listener_add')
    return
  endif
  try
    s_listener_ids[buf] = listener_add(OnBufLines, buf)
  catch
    s_listener_ids[buf] = 0
  endtry
enddef

def RemoveListener(buf: number)
  if has_key(s_listener_ids, buf)
    if s_listener_ids[buf] != 0
      try | listener_remove(s_listener_ids[buf]) | catch | endtry
    endif
    remove(s_listener_ids, string(buf))
  endif
  if has_key(s_pending_splice, buf)
    remove(s_pending_splice, string(buf))
  endif
enddef

def RemoveAllListeners()
  for [k, id] in items(s_listener_ids)
    if id != 0
      try | listener_remove(id) | catch | endtry
    endif
  endfor
  s_listener_ids = {}
  s_pending_splice = {}
enddef

# core#Send() returns false when ch_sendraw throws while the job is still
# alive — a full pipe, a daemon wedged mid-write.  The inflight flags were set
# before the send, and nothing ever cleared them on that path: ScheduleSync()
# then bailed at its inflight guard and every other request class bailed on the
# changedtick check, so one failed write silently froze that buffer's pipeline
# for the rest of the session.  Unwinding restores the state the send tried to
# leave, and the next ScheduleSync() retries normally.
def UnwindInflightSync(buf: number)
  s_inflight_sync[buf] = false
  if has_key(s_inflight_revision, buf)
    remove(s_inflight_revision, string(buf))
  endif
  Log('Send failed; released the sync interlock for buffer ' .. buf)
enddef

def SyncBufferNow(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  if !EnsureDaemon() | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' | return | endif

  # 同一 buffer 只允许一个 set_text 在途；ACK 后会自动发送最新快照。
  if get(s_inflight_sync, buf, false)
    return
  endif

  # 注册 listener 并强制送达排队中的变更，让 splice 状态覆盖到当前 changedtick。
  EnsureListener(buf)
  if exists('*listener_flush')
    try | listener_flush(buf) | catch | endtry
  endif

  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, -1)
  if last_ct == ct
    return
  endif
  if has_key(s_full_symbol_cache, buf)
    remove(s_full_symbol_cache, string(buf))
  endif

  var max_bytes = getbufvar(buf, 'simpletreesitter_max_buffer_bytes',
    get(g:, 'simpletreesitter_max_buffer_bytes', 5242880))
  if BufferTextExceedsLimit(buf, max_bytes)
    if get(s_skipped_changedtick, buf, -1) != ct
      Log('Skipped oversized buffer ' .. buf .. ' (limit=' .. max_bytes .. ' bytes)')
      ClearOwnProps(1, BufLineCount(buf), buf, get(s_applied_types, buf, []))
      if has_key(s_last_ranges, buf) | remove(s_last_ranges, string(buf)) | endif
      if has_key(s_applied_types, buf) | remove(s_applied_types, string(buf)) | endif
    endif
    if !get(s_oversized_notified, buf, false)
      s_oversized_notified[buf] = true
      echom '[ts-hl] skipped buffer larger than g:simpletreesitter_max_buffer_bytes'
    endif
    if last_ct >= 0 && s_protocol_version >= 2
      Send({type: 'close_buffer', buf: buf})
    endif
    if has_key(s_sent_changedtick, buf)
      remove(s_sent_changedtick, string(buf))
    endif
    if has_key(s_pending_splice, buf)
      remove(s_pending_splice, string(buf))
    endif
    s_skipped_changedtick[buf] = ct
    # A full-symbol consumer waiting for this sync would otherwise remain
    # pending forever and could fire much later after the buffer shrinks.
    CancelSymbolConsumers(buf)
    return
  endif

  if has_key(s_skipped_changedtick, buf)
    remove(s_skipped_changedtick, string(buf))
  endif
  if has_key(s_oversized_notified, buf)
    remove(s_oversized_notified, string(buf))
  endif

  var eol = getbufvar(buf, '&endofline') ? true : false

  # 增量路径：daemon 已持有上次发送的快照，只传变更的行区间。
  # daemon 会校验总行数，任何失配都会触发一次全量重同步。
  if s_protocol_version >= 3
      && get(g:, 'simpletreesitter_incremental_sync', 1)
      && last_ct >= 0
      && has_key(s_pending_splice, buf)
    var sp = s_pending_splice[buf]
    remove(s_pending_splice, string(buf))
    if sp.os >= 1 && sp.oe >= sp.os && sp.ne >= sp.os
      var new_lines = sp.ne > sp.os ? getbufline(buf, sp.os, sp.ne - 1) : []
      s_inflight_sync[buf] = true
      s_inflight_revision[buf] = ct
      if !Send({
        type: 'edit_lines',
        buf: buf,
        lang: lang,
        revision: ct,
        lstart: sp.os,
        old_lend: sp.oe,
        lines: new_lines,
        line_count: BufLineCount(buf),
        eol: eol,
      })
        UnwindInflightSync(buf)
        return
      endif
      Log('Sent edit_lines for buffer ' .. buf .. ' (changedtick=' .. ct
        .. ' lines=' .. sp.os .. '..' .. sp.oe .. '->' .. len(new_lines) .. ')')
      return
    endif
  endif

  var lines = getbufline(buf, 1, '$')
  var text = join(lines, "\n")
  if eol && !empty(lines)
    text ..= "\n"
  endif
  # 全量快照本身就是新的 baseline
  if has_key(s_pending_splice, buf)
    remove(s_pending_splice, string(buf))
  endif
  s_inflight_sync[buf] = true
  s_inflight_revision[buf] = ct
  if !Send({type: 'set_text', buf: buf, lang: lang, text: text, revision: ct})
    UnwindInflightSync(buf)
    return
  endif
  Log('Sent set_text for buffer ' .. buf .. ' (changedtick=' .. ct .. ')')
enddef

def ScheduleSync(buf: number)
  if !bufexists(buf) | return | endif
  if !IsSupportedLang(buf) | return | endif

  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    return
  endif
  var last_ct = get(s_sent_changedtick, buf, -1)
  if ct == last_ct && !get(s_inflight_sync, buf, false)
    return
  endif
  if get(s_inflight_sync, buf, false)
    return
  endif

  StopSyncTimer(buf)
  var ms = get(g:, 'simpletreesitter_debounce', 120)
  if exists('*timer_start')
    try
      s_sync_timers[buf] = timer_start(ms, (id) => {
        s_sync_timers[buf] = 0
        SyncBufferNow(buf)
      })
    catch
      SyncBufferNow(buf)
    endtry
  else
    SyncBufferNow(buf)
  endif
enddef

def ScheduleRequest(buf: number, reason: string = 'edit')
  if !s_enabled
    return
  endif
  if !IsSupportedLang(buf)
    return
  endif
  if IsHighlightSuspended(buf)
    return
  endif

  # 未同步/正在同步时，先同步文本，跳过这次高亮
  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    return
  endif
  var last_ct = get(s_sent_changedtick, buf, -1)
  if ct != last_ct || get(s_inflight_sync, buf, false)
    ScheduleSync(buf)
    return
  endif

  StopBufTimer(buf)
  var ms = reason ==# 'scroll' ? get(g:, 'simpletreesitter_scroll_debounce', 300) : get(g:, 'simpletreesitter_debounce', 120)

  if exists('*timer_start')
    try
      s_req_timers[buf] = timer_start(ms, (id) => {
        s_req_timers[buf] = 0
        RequestNow(buf)
      })
    catch
      RequestNow(buf)
    endtry
  else
    RequestNow(buf)
  endif
enddef

def AutoEnableForBuffer(buf: number)
  if !bufexists(buf)
    return
  endif

  # 若用户手动关闭，则不自动启用
  if s_user_disabled
    return
  endif

  var auto_enable_ft = get(g:, 'simpletreesitter_auto_enable_filetypes', [])
  if type(auto_enable_ft) != v:t_list || len(auto_enable_ft) == 0
    return
  endif

  var ft = getbufvar(buf, '&filetype')
  if index(auto_enable_ft, ft) < 0
    return
  endif
  if s_enabled && has_key(s_active_bufs, buf) && s_active_bufs[buf]
    return
  endif

  if !s_enabled
    Log('Auto-enabling for filetype: ' .. ft)
    Enable()
  endif
  s_active_bufs[buf] = true
  ScheduleSync(buf)
  ScheduleRequest(buf, 'edit')
enddef

def CheckAndStopDaemon()
  # An Outline in *any* tabpage keeps the daemon alive; win_id2win() would only
  # ever see this one, and stopping the daemon under another tab's sidebar
  # leaves it frozen with no way back except :TsHlOutlineRefresh.
  if !empty(AllOutlineWins())
    return
  endif
  var has_active = false
  for [bufnr, active] in items(s_active_bufs)
    var b = str2nr(bufnr)
    if active && bufexists(b) && len(win_findbuf(b)) > 0
      has_active = true
      break
    endif
  endfor
  if !has_active && s_enabled && get(g:, 'simpletreesitter_auto_stop', 1)
    Log('No active buffers, stopping daemon')
    Disable()
    # 自动停机不是用户显式禁用；下一个匹配 buffer 仍可自动启动。
    s_user_disabled = false
    s_active_bufs = {}
  endif
enddef

def ClearAllProps()
  var seen: dict<bool> = {}
  var bufs: list<number> = []
  # 当前 buffer
  var cur = bufnr()
  if bufexists(cur)
    bufs->add(cur)
  endif
  # 已激活的 buffer
  for [k, active] in items(s_active_bufs)
    var b = str2nr(k)
    if active && bufexists(b)
      bufs->add(b)
    endif
  endfor
  # 记录过 last range 的 buffer 也清理一下，防止遗漏
  for [k, _] in items(s_last_ranges)
    var b = str2nr(k)
    if bufexists(b)
      bufs->add(b)
    endif
  endfor
  # 去重并清理
  for b in bufs
    if get(seen, b, false)
      continue
    endif
    seen[b] = true
    ClearOwnProps(1, BufLineCount(b), b)
  endfor
  # 清空范围缓存，避免误判
  s_last_ranges = {}
  s_applied_types = {}
enddef

# =============== 缩进参考线 ===============
def EnableIndentGuides()
  ApplyIndentGuidesForBuf()
enddef

def DisableIndentGuides()
  var current = win_getid()
  for [wid_string, saved] in items(s_indent_guide_windows)
    var wid = str2nr(wid_string)
    if !empty(getwininfo(wid)) && win_gotoid(wid)
      try
        &l:list = get(saved, 'list', false)
        &l:listchars = get(saved, 'listchars', '')
      catch
      endtry
    endif
  endfor
  s_indent_guide_windows = {}
  if current != 0
    win_gotoid(current)
  endif
enddef

def ApplyIndentGuidesForBuf()
  if !get(g:, 'simpletreesitter_indent_guides', 0)
    return
  endif
  var wid = win_getid()
  if wid == 0 || has_key(s_indent_guide_windows, wid)
    return
  endif
  var sw = &shiftwidth > 0 ? &shiftwidth : (&tabstop > 0 ? &tabstop : 4)
  if sw < 2
    return
  endif
  var ch = get(g:, 'simpletreesitter_indent_guide_char', '│')
  var filler = repeat(' ', sw - 1)
  s_indent_guide_windows[wid] = {list: &l:list, listchars: &l:listchars}
  &l:list = true
  var parts = filter(split(&l:listchars, ','), (_, value) => value !~# '^leadmultispace:')
  parts->add('leadmultispace:' .. ch .. filler)
  &l:listchars = join(parts, ',')
enddef

# =============== Tree-sitter 折叠 ===============
def FoldsEnabled(): bool
  return get(g:, 'simpletreesitter_folds', 0) ? true : false
enddef

def ScheduleFolds(buf: number)
  if !s_enabled || !FoldsEnabled() || s_protocol_version < 3
    return
  endif
  if !IsSupportedLang(buf)
    return
  endif
  RequestFoldsNow(buf)
enddef

def RequestFoldsNow(buf: number)
  if !s_enabled || !simpletreesitter#core#IsRunning() || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# '' | return | endif
  # 未同步时直接放弃；set_text/edit_lines 的 ACK 会重新调度。
  if GetChangedTick(buf) != get(s_sent_changedtick, buf, -1) || get(s_inflight_sync, buf, false)
    return
  endif
  if get(s_inflight_folds, buf, false)
    s_pending_folds[buf] = true
    return
  endif
  s_inflight_folds[buf] = true
  s_pending_folds[buf] = false
  if !Send({type: 'folds', buf: buf, lang: lang})
    s_inflight_folds[buf] = false
  endif
enddef

def ApplyFolds(buf: number, folds: list<dict<any>>)
  if !bufexists(buf) || !FoldsEnabled()
    return
  endif
  var line_count = BufLineCount(buf)
  # 用差分数组重建每行嵌套深度；level = 覆盖该行的折叠数量。
  var delta = repeat([0], line_count + 2)
  var starts: dict<bool> = {}
  for fold in folds
    var l1 = get(fold, 'lnum', 0)
    var l2 = get(fold, 'end_lnum', 0)
    if l1 < 1 || l2 > line_count || l2 <= l1
      continue
    endif
    delta[l1] += 1
    delta[l2 + 1] -= 1
    starts[string(l1)] = true
  endfor
  var exprs: list<string> = []
  var level = 0
  for lnum in range(1, line_count)
    level += delta[lnum]
    if get(starts, string(lnum), false)
      exprs->add('>' .. level)
    else
      exprs->add(string(level))
    endif
  endfor
  s_fold_exprs[buf] = exprs
  for wid in win_findbuf(buf)
    ApplyFoldSettingsToWin(wid)
  endfor
enddef

def ApplyFoldSettingsToWin(wid: number)
  if empty(getwininfo(wid))
    return
  endif
  if !has_key(s_fold_windows, wid)
    s_fold_windows[wid] = {
      method: getwinvar(wid, '&foldmethod'),
      expr: getwinvar(wid, '&foldexpr'),
    }
  endif
  # 重新赋值 foldexpr 会触发该窗口的折叠重算
  setwinvar(wid, '&foldmethod', 'expr')
  setwinvar(wid, '&foldexpr', 'simpletreesitter#FoldExpr(v:lnum)')
enddef

def RestoreFoldSettings()
  for [wid_str, saved] in items(s_fold_windows)
    var wid = str2nr(wid_str)
    if !empty(getwininfo(wid))
      try
        setwinvar(wid, '&foldmethod', get(saved, 'method', 'manual'))
        setwinvar(wid, '&foldexpr', get(saved, 'expr', '0'))
      catch
      endtry
    endif
  endfor
  s_fold_windows = {}
  s_fold_exprs = {}
enddef

export def FoldExpr(lnum: number): string
  var exprs = get(s_fold_exprs, bufnr(), [])
  if lnum < 1 || lnum > len(exprs)
    # 折叠数据尚未跟上编辑时沿用上一行的层级
    return '='
  endif
  return exprs[lnum - 1]
enddef

export def FoldsToggle()
  if FoldsEnabled()
    g:simpletreesitter_folds = 0
    RestoreFoldSettings()
    echo '[ts-hl] folds disabled'
    return
  endif
  g:simpletreesitter_folds = 1
  if !s_enabled
    Enable()
  endif
  ScheduleFolds(bufnr())
  echo '[ts-hl] folds enabled'
enddef

# =============== 符号 location list ===============
def CancelSymbolConsumers(buf: number, notice: string = '')
  if has_key(s_loclist_pending, buf)
    s_loclist_pending[buf] = false
  endif
  if has_key(s_symbol_jump_pending, buf)
    remove(s_symbol_jump_pending, string(buf))
  endif
  if notice !=# ''
    echo '[ts-hl] ' .. notice
  endif
enddef

def RequestFullSymbols(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    CancelSymbolConsumers(buf)
    return
  endif
  if !EnsureDaemon()
    CancelSymbolConsumers(buf, 'symbol request could not start the daemon')
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    CancelSymbolConsumers(buf)
    return
  endif
  var changedtick = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == changedtick
    CancelSymbolConsumers(buf, 'buffer exceeds g:simpletreesitter_max_buffer_bytes')
    return
  endif
  if changedtick != get(s_sent_changedtick, buf, -1) || get(s_inflight_sync, buf, false)
    # ACK 处理器会在同步完成后重新发起。
    ScheduleSync(buf)
    return
  endif
  # Full consumers do not inherit the outline's small scan limit. Protocol v4+
  # filters navigation kinds in the daemon before this hard cap. The kind set
  # comes from the queued command, not mutable configuration at response time.
  var kinds: list<string> = []
  if !get(s_loclist_pending, buf, false) && has_key(s_symbol_jump_pending, buf)
      && s_protocol_version >= 4
    kinds = JumpKindsSnapshot(s_symbol_jump_pending[buf])
  endif

  var cached = get(s_full_symbol_cache, buf, {})
  var cached_kinds = get(cached, 'kinds', [])
  var cache_compatible = empty(kinds)
    ? empty(cached_kinds)
    : empty(cached_kinds) || cached_kinds == kinds
  if get(cached, 'revision', -1) == changedtick && cache_compatible
    ConsumeFullSymbols(buf, get(cached, 'symbols', []), cached_kinds, false)
    return
  endif
  if get(s_inflight_syms, buf, false)
    if get(s_symbol_request_purpose, buf, '') !=# 'full'
      s_pending_syms[buf] = true
    endif
    return
  endif
  s_inflight_syms[buf] = true
  s_pending_syms[buf] = false
  s_symbol_request_purpose[buf] = 'full'
  s_symbol_request_kinds[buf] = copy(kinds)
  var request_id = NextSymbolRequestId()
  s_symbol_request_ids[buf] = request_id
  if !Send({type: 'symbols', buf: buf, lang: lang, lstart: 1,
      lend: BufLineCount(buf), max_items: 100000, kinds: kinds, request_id: request_id})
    s_inflight_syms[buf] = false
    ClearSymbolRequestId(buf)
    remove(s_symbol_request_purpose, string(buf))
    remove(s_symbol_request_kinds, string(buf))
    CancelSymbolConsumers(buf, 'symbol request could not be sent')
  endif
enddef

def PopulateSymbolLoclist(buf: number, syms: list<dict<any>>)
  var entries: list<dict<any>> = []
  for s in syms
    var text = get(s, 'kind', '') .. ': ' .. get(s, 'name', '')
    var container = get(s, 'container_name', '')
    if type(container) == v:t_string && container !=# ''
      text ..= ' [' .. container .. ']'
    endif
    entries->add({bufnr: buf, lnum: get(s, 'lnum', 1), col: get(s, 'col', 1), text: text})
  endfor
  var wins = win_findbuf(buf)
  if empty(wins)
    return
  endif
  setloclist(wins[0], [], ' ', {title: '[ts-hl] symbols', items: entries})
  if win_gotoid(wins[0])
    execute 'lopen'
  endif
enddef

def JumpKindsSnapshot(jump: dict<any>): list<string>
  var result: list<string> = []
  var raw = get(jump, 'kinds', [])
  if type(raw) != v:t_list
    return result
  endif
  for kind in raw
    if type(kind) == v:t_string
      result->add(kind)
    endif
  endfor
  return result
enddef

def ConsumeFullSymbols(buf: number, syms: list<dict<any>>,
    response_kinds: list<string> = [], apply_outline: bool = true)
  # A filtered navigation response cannot satisfy an unfiltered location list.
  if empty(response_kinds) && get(s_loclist_pending, buf, false)
    s_loclist_pending[buf] = false
    PopulateSymbolLoclist(buf, syms)
  endif
  if has_key(s_symbol_jump_pending, buf)
    var jump = s_symbol_jump_pending[buf]
    var jump_kinds = JumpKindsSnapshot(jump)
    if empty(response_kinds) || response_kinds == jump_kinds
      remove(s_symbol_jump_pending, string(buf))
      JumpToSymbol(buf, syms, jump)
    endif
  endif
  if apply_outline
    ApplySymbols(buf, syms)
  endif
enddef

def SymbolJumpKinds(): list<string>
  var configured = get(g:, 'simpletreesitter_symbol_jump_kinds', [])
  if type(configured) != v:t_list
    return []
  endif
  var kinds: list<string> = []
  for kind in configured
    if type(kind) == v:t_string && kind !=# ''
      kinds->add(kind)
    endif
  endfor
  return kinds
enddef

def SymbolJumpKindsForBuf(buf: number): list<string>
  var filetype = getbufvar(buf, '&filetype')
  # 文档和结构化数据的层级借用 field/property/variable 等 kind；
  # 这些 filetype 必须保留全部符号。
  if index(['markdown', 'json', 'jsonc', 'yaml', 'toml', 'css', 'html'], filetype) >= 0
    return []
  endif
  return SymbolJumpKinds()
enddef

def NavigableSymbols(buf: number, syms: list<dict<any>>, kinds: list<string>): list<dict<any>>
  var result: list<dict<any>> = []
  var seen: dict<bool> = {}
  for symbol in syms
    var lnum = get(symbol, 'lnum', 0)
    var col = get(symbol, 'col', 0)
    if lnum <= 0 || col <= 0
      continue
    endif
    if !empty(kinds) && index(kinds, get(symbol, 'kind', '')) < 0
      continue
    endif
    var key = lnum .. ':' .. col
    if !has_key(seen, key)
      seen[key] = true
      result->add(symbol)
    endif
  endfor
  result->sort((left, right) => {
    var line_delta = get(left, 'lnum', 0) - get(right, 'lnum', 0)
    return line_delta != 0 ? line_delta : get(left, 'col', 0) - get(right, 'col', 0)
  })
  return result
enddef

def JumpToSymbol(buf: number, syms: list<dict<any>>, jump: dict<any>)
  var target_win = get(jump, 'winid', 0)
  if target_win <= 0 || winbufnr(target_win) != buf
    echo '[ts-hl] symbol source window is no longer available'
    return
  endif
  if get(jump, 'changedtick', -1) != GetChangedTick(buf)
    echo '[ts-hl] symbol jump cancelled because the buffer changed'
    return
  endif
  var live_pos = getcurpos(target_win)
  if live_pos[1] != get(jump, 'lnum', 1) || live_pos[2] != get(jump, 'col', 1)
    echo '[ts-hl] symbol jump cancelled because the source cursor moved'
    return
  endif

  var items = NavigableSymbols(buf, syms, JumpKindsSnapshot(jump))
  if empty(items)
    echo '[ts-hl] no symbols match g:simpletreesitter_symbol_jump_kinds'
    return
  endif

  var steps = get(jump, 'steps', 0)
  if steps == 0
    return
  endif
  var current_line = get(jump, 'lnum', 1)
  var current_col = get(jump, 'col', 1)
  var forward = steps > 0
  var target_idx = -1
  if forward
    for i in range(len(items))
      var item = items[i]
      var item_line = get(item, 'lnum', 0)
      var item_col = get(item, 'col', 0)
      if item_line > current_line || (item_line == current_line && item_col > current_col)
        target_idx = i
        break
      endif
    endfor
    if target_idx < 0
      target_idx = 0
    endif
  else
    var i = len(items) - 1
    while i >= 0
      var item = items[i]
      var item_line = get(item, 'lnum', 0)
      var item_col = get(item, 'col', 0)
      if item_line < current_line || (item_line == current_line && item_col < current_col)
        target_idx = i
        break
      endif
      i -= 1
    endwhile
    if target_idx < 0
      target_idx = len(items) - 1
    endif
  endif

  var extra = (abs(steps) - 1) % len(items)
  target_idx = forward ? (target_idx + extra) % len(items) : (target_idx - extra) % len(items)
  if target_idx < 0
    target_idx += len(items)
  endif
  var target = items[target_idx]
  var target_line = get(target, 'lnum', 1)
  var target_col = get(target, 'col', 1)
  # Update the originating split and restore the user's current focus if they
  # switched windows while the daemon was working. Restoring the captured
  # origin first also makes the previous-context mark deterministic.
  var return_win = win_getid()
  var restore_focus = return_win != target_win
  try
    if restore_focus
      execute $'noautocmd call win_gotoid({target_win})'
    endif
    cursor(current_line, current_col)
    execute "normal! m'"
    cursor(target_line, target_col)
    normal! zv
    # cursor() inside a closed fold may first land on its start; repeat after
    # zv so the exact symbol position wins.
    cursor(target_line, target_col)
  finally
    if restore_focus && winbufnr(return_win) >= 0
      execute $'noautocmd call win_gotoid({return_win})'
    endif
  endtry
  echo printf('[ts-hl] %s: %s', get(target, 'kind', 'symbol'), get(target, 'name', ''))
enddef

def QueueSymbolJump(direction: number, count: number)
  var buf = bufnr()
  var source_win = win_getid()
  if buf == s_outline_buf && s_outline_src_buf != 0
    buf = s_outline_src_buf
    source_win = s_outline_src_win
  endif
  if source_win <= 0 || winbufnr(source_win) != buf
    echo '[ts-hl] symbol source window is no longer available'
    return
  endif
  if !IsSupportedLang(buf)
    echo '[ts-hl] symbol navigation unsupported for this &filetype'
    return
  endif
  if !s_enabled
    Enable()
  endif
  if !s_enabled || !EnsureDaemon()
    return
  endif
  var delta = (direction < 0 ? -1 : 1) * max([1, count])
  var pos = getcurpos(source_win)
  var changedtick = GetChangedTick(buf)
  var kinds = SymbolJumpKindsForBuf(buf)
  var old = get(s_symbol_jump_pending, buf, {})
  var same_origin = !empty(old)
    && get(old, 'winid', 0) == source_win
    && get(old, 'lnum', 0) == pos[1]
    && get(old, 'col', 0) == pos[2]
    && get(old, 'changedtick', -1) == changedtick
    && JumpKindsSnapshot(old) == kinds
  var steps = (same_origin ? get(old, 'steps', 0) : 0) + delta
  if steps == 0
    if has_key(s_symbol_jump_pending, buf)
      remove(s_symbol_jump_pending, string(buf))
    endif
    return
  endif
  s_symbol_jump_pending[buf] = {
    steps: steps,
    winid: source_win,
    lnum: pos[1],
    col: pos[2],
    changedtick: changedtick,
    kinds: kinds,
  }
  RequestFullSymbols(buf)
enddef

export def NextSymbol(count: number = 1)
  QueueSymbolJump(1, count)
enddef

export def PrevSymbol(count: number = 1)
  QueueSymbolJump(-1, count)
enddef

export def SymbolsToLoclist()
  var buf = bufnr()
  if buf == s_outline_buf && s_outline_src_buf != 0
    buf = s_outline_src_buf
  endif
  if !IsSupportedLang(buf)
    echo '[ts-hl] symbols unsupported for this &filetype'
    return
  endif
  if !s_enabled
    Enable()
  endif
  if !s_enabled || !EnsureDaemon()
    return
  endif
  s_loclist_pending[buf] = true
  RequestFullSymbols(buf)
enddef

# =============== 面包屑导航 ===============
def BreadcrumbIcon(kind: string): string
  if !get(g:, 'simpletreesitter_outline_fancy', 1)
    return kind[0]
  endif
  var icons = {
    'function': '󰡱',
    'method': '󰆧',
    'class': '',
    'struct': '',
    'enum': '',
    'namespace': '',
    'type': '',
    'module': '📦',
  }
  return get(icons, kind, '')
enddef

# Vim parses 'winbar' exactly like 'statusline': a bare '%' opens a format item
# and '%{expr}' is *evaluated* on every redraw.  Interpolating a symbol name into
# the option therefore handed a markdown heading such as
# `# %{system("curl … | sh")}` straight to the expression evaluator — code
# execution from moving the cursor in an untrusted file — while an innocent
# `# 100% coverage` raised E539 and lost the breadcrumb entirely.  So the option
# holds one fixed expression for the lifetime of the window and only the cached
# string it reads ever changes: Vim renders the *result* of a plain %{} item
# literally (re-parsing is what the separate %{% %} form is for), which is why
# the documented statusline usage was already safe.
const s_winbar_expr = '%{simpletreesitter#Breadcrumb()}'

# A set-but-empty 'winbar' still costs the window a screen line, so an empty
# breadcrumb must clear the option rather than evaluate to an empty string.
def WinbarValue(text: string): string
  return text ==# '' ? '' : s_winbar_expr
enddef

def SetWinbar(text: string)
  if !exists('+winbar')
    return
  endif
  # setwinvar() stores the value verbatim; ':setlocal winbar=' would need the
  # option-value escaping whose incompleteness caused the bug described above.
  try
    setwinvar(0, '&winbar', WinbarValue(text))
  catch
  endtry
enddef

# SetWinbar() only ever touches the current window, but the expression has been
# installed in every window a breadcrumb was ever computed in — and an installed
# expression that evaluates to nothing still costs each of those windows a screen
# line.  Disabling the plugin must therefore sweep them all, across tabpages.
def ClearAllWinbars()
  if !exists('+winbar')
    return
  endif
  for info in getwininfo()
    if getwinvar(info.winid, '&winbar', '') ==# s_winbar_expr
      try
        setwinvar(info.winid, '&winbar', '')
      catch
      endtry
    endif
  endfor
enddef

# The single entry point for symbol payloads reaching the breadcrumb, so the
# untrusted-name path has one place to test and one place to guard.
def SetBreadcrumbItems(buf: number, syms: list<dict<any>>)
  if buf != s_bc_buf || !get(g:, 'simpletreesitter_breadcrumb', 0)
    return
  endif
  s_bc_items = syms
  ScheduleBreadcrumbUpdate()
enddef

def UpdateBreadcrumb()
  if !get(g:, 'simpletreesitter_breadcrumb', 0)
    return
  endif
  var buf = bufnr('%')
  # The breadcrumb describes *this* window's cursor, so it is cached against
  # this window and never against the plugin as a whole.
  var wkey = string(win_getid())
  if buf != s_bc_buf || empty(s_bc_items)
    if get(s_breadcrumb_cache, wkey, '') !=# ''
      remove(s_breadcrumb_cache, wkey)
      SetWinbar('')
    endif
    return
  endif
  var cur_line = line('.')
  # 找出包含当前行的所有符号
  var enclosing: list<dict<any>> = []
  var container_kinds = ['function', 'method', 'class', 'struct', 'enum', 'namespace', 'type', 'module']
  for item in s_bc_items
    var slnum = get(item, 'lnum', 0)
    var elnum = get(item, 'end_lnum', 0)
    var skind = get(item, 'kind', '')
    if index(container_kinds, skind) < 0
      continue
    endif
    if slnum <= cur_line && elnum >= cur_line
      enclosing->add(item)
    endif
  endfor
  # 按范围从大到小排序（外层在前）
  sort(enclosing, (a, b) => {
    var ra = get(a, 'end_lnum', 0) - get(a, 'lnum', 0)
    var rb = get(b, 'end_lnum', 0) - get(b, 'lnum', 0)
    return rb < ra ? -1 : (rb > ra ? 1 : 0)
  })
  var sep = get(g:, 'simpletreesitter_breadcrumb_separator', ' > ')
  var parts: list<string> = []
  for item in enclosing
    var icon = BreadcrumbIcon(item.kind)
    parts->add(icon .. ' ' .. item.name)
  endfor
  var text = join(parts, sep)
  if text ==# get(s_breadcrumb_cache, wkey, '')
    return
  endif
  if text ==# ''
    remove(s_breadcrumb_cache, wkey)
  else
    s_breadcrumb_cache[wkey] = text
  endif
  SetWinbar(text)
enddef

def ScheduleBreadcrumbUpdate()
  if !get(g:, 'simpletreesitter_breadcrumb', 0)
    return
  endif
  if s_bc_timer != 0
    try | timer_stop(s_bc_timer) | catch | endtry
    s_bc_timer = 0
  endif
  s_bc_timer = timer_start(200, (_) => {
    s_bc_timer = 0
    UpdateBreadcrumb()
  })
enddef

# =============== Outline 光标跟随 ===============
# CursorMoved 每次按键都会触发，UpdateOutlineCursor 又是 O(符号数) 扫描，故防抖。
def ScheduleOutlineCursorUpdate()
  if s_outline_win == 0 || s_outline_buf == 0
    return
  endif
  if !get(g:, 'simpletreesitter_outline_follow_cursor', 1)
    return
  endif
  if s_outline_cursor_timer != 0
    try | timer_stop(s_outline_cursor_timer) | catch | endtry
    s_outline_cursor_timer = 0
  endif
  s_outline_cursor_timer = timer_start(100, (_) => {
    s_outline_cursor_timer = 0
    UpdateOutlineCursor()
  })
enddef

def UpdateOutlineCursor()
  if s_outline_win == 0 || s_outline_buf == 0
    return
  endif
  if !get(g:, 'simpletreesitter_outline_follow_cursor', 1)
    return
  endif
  if !bufexists(s_outline_buf)
    return
  endif
  var cur_line = line('.')
  # 找出包含当前行的最内层符号
  var best_idx = -1
  var best_range = 999999
  for i in range(len(s_outline_items))
    var item = s_outline_items[i]
    var slnum = get(item, 'lnum', 0)
    var elnum = get(item, 'end_lnum', 0)
    if elnum == 0
      # 没有 end_lnum 时用 lnum 最接近的
      if slnum <= cur_line && (best_idx < 0 || slnum > get(s_outline_items[best_idx], 'lnum', 0))
        best_idx = i
      endif
      continue
    endif
    if slnum <= cur_line && elnum >= cur_line
      var rng = elnum - slnum
      if rng < best_range
        best_range = rng
        best_idx = i
      endif
    endif
  endfor
  if best_idx < 0
    # 清除旧高亮
    if s_outline_cursor_line > 0
      try | prop_remove({type: s_outline_cursor_prop, bufnr: s_outline_buf, all: true}) | catch | endtry
      s_outline_cursor_line = 0
    endif
    return
  endif
  # 通过预建的反查表映射到 outline 行号（O(1)，免去逐行扫描 linemap）
  var outline_lnum = get(s_outline_idx_to_lnum, string(best_idx), -1)
  if outline_lnum < 0 || outline_lnum == s_outline_cursor_line
    return
  endif
  # 更新高亮
  try | prop_remove({type: s_outline_cursor_prop, bufnr: s_outline_buf, all: true}) | catch | endtry
  try
    prop_add(outline_lnum, 1, {type: s_outline_cursor_prop, bufnr: s_outline_buf, end_lnum: outline_lnum, end_col: strlen(getbufline(s_outline_buf, outline_lnum)[0]) + 1})
  catch
  endtry
  s_outline_cursor_line = outline_lnum
enddef

# =============== 导出 API ===============
export def Enable()
  if s_enabled
    if EnsureDaemon()
      var current = bufnr()
      if IsSupportedLang(current)
        s_active_bufs[current] = true
        ScheduleSync(current)
        ScheduleRequest(current, 'edit')
      endif
    endif
    return
  endif
  if !EnsureDaemon()
    return
  endif
  s_enabled = true
  s_user_disabled = false  # 清空标记（允许自动开启逻辑）

  augroup TsHl
    autocmd!
    autocmd TextChanged,TextChangedI * call simpletreesitter#OnBufEvent(bufnr())
    autocmd CursorMoved,CursorMovedI * call simpletreesitter#OnScroll(bufnr())
    autocmd BufWinLeave * call simpletreesitter#OnBufWinLeave(str2nr(expand('<abuf>')))
    autocmd BufUnload,BufDelete,BufWipeout * call simpletreesitter#OnBufClose(str2nr(expand('<abuf>')))
    autocmd ColorScheme * call simpletreesitter#RefreshHighlightGroups()
  augroup END

  var buf = bufnr()
  if IsSupportedLang(buf)
    s_active_bufs[buf] = true
    ScheduleSync(buf)
    ScheduleRequest(buf, 'edit')
  endif
enddef

export def Restart()
  SetupCore()
  s_protocol_version = 0
  InvalidateDaemonSession()
  if simpletreesitter#core#Restart()
    echom '[ts-hl] daemon restarted'
  endif
enddef

export def ShowLog()
  simpletreesitter#core#ShowLog()
enddef

export def Health()
  SetupCore()
  var h = simpletreesitter#core#Health()
  echo '[ts-hl] health'
  for line in simpletreesitter#core#HealthLines()
    echo '  ' .. line
  endfor
  echo printf('  [%s] protocol: v%d (plugin speaks v5)',
    s_protocol_version >= 5 ? 'OK' : 'WARN', s_protocol_version)
  echo printf('  [%s] text properties: %s',
    has('textprop') ? 'OK' : 'ERROR',
    has('textprop') ? 'available' : 'missing +textprop — highlighting disabled')
  echo printf('  [INFO] enabled: %s, active buffers: %d',
    s_enabled ? 'yes' : 'no', len(s_active_bufs))
enddef

export def Disable()
  if !s_enabled && !simpletreesitter#core#IsRunning() && s_outline_win == 0
    s_user_disabled = true
    return
  endif
  s_enabled = false
  s_user_disabled = true   # 记录用户主动关闭
  # 先失效当前会话；随后即使旧 channel 中已有回调排队，也不能重新绘制或调度请求。
  SetupCore()
  simpletreesitter#core#Stop()
  InvalidateDaemonSession()
  if s_sym_timer != 0
    try | timer_stop(s_sym_timer) | catch | endtry
    s_sym_timer = 0
  endif
  if s_outline_cursor_timer != 0
    try | timer_stop(s_outline_cursor_timer) | catch | endtry
    s_outline_cursor_timer = 0
  endif
  augroup TsHl
    autocmd!
  augroup END
  CloseAllOutlines()
  for [k, tid] in items(s_req_timers)
    if tid != 0 && exists('*timer_stop')
      try | call timer_stop(tid) | catch | endtry
    endif
  endfor
  s_req_timers = {}
  for [k, tid] in items(s_sync_timers)
    if tid != 0 && exists('*timer_stop')
      try | call timer_stop(tid) | catch | endtry
    endif
  endfor
  s_sync_timers = {}
  s_active_bufs = {}
  # 新增：关闭时清理所有已绘制的 props（可配置）
  if get(g:, 'simpletreesitter_clear_props_on_disable', 1)
    ClearAllProps()
  endif
  # 清理 listener 与折叠状态
  RemoveAllListeners()
  RestoreFoldSettings()
  # 清理缩进参考线
  DisableIndentGuides()
  # 清理面包屑
  s_bc_items = []
  s_breadcrumb_cache = {}
  if s_bc_timer != 0
    try | timer_stop(s_bc_timer) | catch | endtry
    s_bc_timer = 0
  endif
  ClearAllWinbars()
  echo '[ts-hl] disabled'
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def Status()
  if !simpletreesitter#core#IsRunning()
    echo '[ts-hl] daemon is stopped'
    return
  endif
  if s_protocol_version < 2
    echo '[ts-hl] daemon protocol is outdated or still negotiating; run install.sh if this persists'
    return
  endif
  if !Send({type: 'status'})
    echo '[ts-hl] unable to contact daemon'
  endif
enddef

# 可用于 Vim 的 statusline：%{simpletreesitter#Breadcrumb()}
# Returns the breadcrumb of the window this is evaluated for: Vim makes the
# window whose 'statusline'/'winbar' is being drawn temporarily current while it
# evaluates a %{} item (|stl-%{|), so win_getid() names the right window both
# during a redraw and when called directly.
export def Breadcrumb(): string
  return get(s_breadcrumb_cache, string(win_getid()), '')
enddef

def ShowOutlineMessage(message: string)
  if s_outline_win == 0 || s_outline_buf == 0 || !bufexists(s_outline_buf)
    return
  endif
  var curwin = win_getid()
  try
    if win_gotoid(s_outline_win)
      setlocal modifiable
      try | call prop_clear(1, line('$'), {bufnr: s_outline_buf}) | catch | endtry
      call setline(1, [message])
      if line('$') > 1
        try | call deletebufline(s_outline_buf, 2, '$') | catch | endtry
      endif
      setlocal nomodifiable
    endif
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

export def OnBufEvent(buf: number)
  SyncOutlineContext()
  if bufexists(buf) && bufloaded(buf) && has_key(s_closed_bufs, buf)
    remove(s_closed_bufs, string(buf))
  endif
  AutoEnableForBuffer(buf)
  # plugin 级自动命令始终存在；显式禁用或未自动启用时不得偷偷启动 daemon。
  if !s_enabled
    return
  endif
  # 先保证文本同步
  if IsSupportedLang(buf)
    s_active_bufs[buf] = true
    if win_getid() != s_outline_win
      s_outline_src_win = win_getid()
    endif
  endif
  ScheduleSync(buf)

  if s_outline_win != 0 && buf != s_outline_buf && getbufvar(buf, '&filetype') !=# 'simpletreesitter_outline'
    if IsSupportedLang(buf)
      if s_outline_state_buf != buf
        s_outline_collapsed = {}
        s_outline_filter = ''
        s_outline_raw_items = []
        s_outline_raw_valid = false
        s_outline_state_buf = buf
      endif
      s_outline_src_buf = buf
      s_outline_src_win = win_getid()
      s_last_outline_sig = ''
      ScheduleSymbols(buf)
    else
      s_outline_src_buf = 0
      s_outline_src_win = 0
      s_outline_filter = ''
      s_outline_raw_items = []
      s_outline_raw_valid = false
      s_outline_items = []
      s_outline_linemap = [-1]
      s_outline_idx_to_lnum = {}
      s_last_outline_sig = ''
      ShowOutlineMessage('<outline unsupported for this filetype>')
    endif
  endif

  ScheduleRequest(buf, 'edit')
  ScheduleSymbols(buf)
  # 缩进参考线
  if IsSupportedLang(buf)
    ApplyIndentGuidesForBuf()
  endif
enddef

export def RefreshHighlightGroups()
  EnsureHlGroupsAndProps()
enddef

export def OnBufWinLeave(buf: number)
  if exists('*timer_start')
    timer_start(100, (_) => CheckAndStopDaemon())
  endif
enddef

export def OnScroll(buf: number)
  if !bufexists(buf)
    return
  endif
  SyncOutlineContext()
  # AutoEnableForBuffer(buf)
  ScheduleRequest(buf, 'scroll')
  # 面包屑导航更新
  ScheduleBreadcrumbUpdate()
  # Outline 光标跟随（防抖）
  ScheduleOutlineCursorUpdate()
enddef

export def OnBufClose(buf: number)
  s_closed_bufs[buf] = true
  var had_cache = has_key(s_sent_changedtick, buf) || has_key(s_inflight_sync, buf)
  if has_key(s_active_bufs, buf)
    s_active_bufs[buf] = false
  endif
  StopBufTimer(buf)
  StopSyncTimer(buf)
  if had_cache && simpletreesitter#core#IsRunning() && s_protocol_version >= 2
    Send({type: 'close_buffer', buf: buf})
  endif
  RemoveListener(buf)
  for state in [s_inflight_sync, s_pending_ast, s_inflight_syms, s_inflight_hl,
      s_pending_syms, s_pending_hl, s_oversized_notified,
      s_inflight_folds, s_pending_folds, s_loclist_pending, s_symbol_request_purpose,
      s_symbol_request_kinds, s_symbol_request_ids, s_full_symbol_cache]
    if has_key(state, buf)
      remove(state, string(buf))
    endif
  endfor
  for state in [s_inflight_revision, s_sent_changedtick, s_skipped_changedtick,
      s_req_timers, s_sync_timers, s_symbol_jump_pending, s_pending_inspect]
    if has_key(state, buf)
      remove(state, string(buf))
    endif
  endfor
  if has_key(s_last_ranges, buf)
    remove(s_last_ranges, string(buf))
  endif
  if has_key(s_applied_types, buf)
    remove(s_applied_types, string(buf))
  endif
  if has_key(s_fold_exprs, buf)
    remove(s_fold_exprs, string(buf))
  endif
  if buf == s_outline_src_buf
    s_outline_src_buf = 0
    s_outline_src_win = 0
    s_outline_filter = ''
    s_outline_raw_items = []
    s_outline_raw_valid = false
    s_outline_items = []
    s_outline_linemap = [-1]
    s_outline_idx_to_lnum = {}
    s_last_outline_sig = ''
    ShowOutlineMessage('<source buffer closed>')
  endif
  if exists('*timer_start')
    timer_start(2000, (id) => CheckAndStopDaemon())
  endif
enddef

def BuildTreeByContainer(syms: list<dict<any>>): list<dict<any>>
  var roots: list<dict<any>> = []
  var containers: dict<any> = {}
  var nodes: list<dict<any>> = []
  var container_kinds = ['namespace', 'class', 'struct', 'enum', 'type', 'variant', 'function']

  def ContainerKey(k: string, n: string, ln: number, co: number): string
    var l = ln > 0 ? ln : 0
    var c = co > 0 ? co : 0
    return k .. '::' .. n .. '@' .. l .. ':' .. c
  enddef

  for i in range(len(syms))
    var s = syms[i]
    var kind = get(s, 'kind', '')
    var name = get(s, 'name', '')
    var lnum = get(s, 'lnum', 1)
    var col  = get(s, 'col', 1)
    var node = {name: name, kind: kind, lnum: lnum, col: col, idx: i, children: []}
    nodes->add(node)
    if index(container_kinds, kind) >= 0
      var key = ContainerKey(kind, name, lnum, col)
      containers[key] = node
    endif
  endfor

  for i in range(len(syms))
    var s = syms[i]
    var kind = get(s, 'kind', '')
    var node = nodes[i]

    var ck = get(s, 'container_kind', '')
    var cn = get(s, 'container_name', '')
    var cl = get(s, 'container_lnum', 0)
    var cc = get(s, 'container_col', 0)

    if type(ck) == v:t_string && ck !=# '' && type(cn) == v:t_string && cn !=# ''
      var pkey = ContainerKey(ck, cn, cl, cc)
      var ownkey = ContainerKey(kind, get(s, 'name', ''), get(s, 'lnum', 1), get(s, 'col', 1))
      if pkey !=# ownkey
        if !has_key(containers, pkey)
          var parent = {name: cn, kind: ck, lnum: cl, col: cc, idx: -1, children: []}
          containers[pkey] = parent
          roots->add(parent)
        endif
        containers[pkey].children->add(node)
        continue
      endif
    endif
    roots->add(node)
  endfor

  return roots
enddef

def BuildTreePrefix(ancestor_last: list<bool>, is_last: bool): string
  var use_ascii = get(g:, 'simpletreesitter_outline_ascii', 0)
  var s_vert = use_ascii ? '|' : '│'
  var s_tee  = use_ascii ? '+-' : '├─'
  var s_end  = use_ascii ? '`-' : '└─'
  var s_pad  = ' '
  var s_bar  = s_vert .. s_pad

  var pref = ''
  for i in range(len(ancestor_last))
    pref ..= (ancestor_last[i] ? '  ' : s_bar)
  endfor
  pref ..= (is_last ? s_end : s_tee) .. ' '
  return pref
enddef

def OutlineCollapseKey(n: dict<any>): string
  return n.kind .. '::' .. n.name .. '@' .. n.lnum
enddef

def RenderTree(nodes: list<dict<any>>, show_pos: bool): dict<any>
  var lines: list<string> = []
  var linemap: list<number> = []
  var meta: list<dict<any>> = []
  var foldable = get(g:, 'simpletreesitter_outline_foldable', 1)
  var spacing = get(g:, 'simpletreesitter_outline_spacing', 1)

  def Walk(ns: list<dict<any>>, ancestors: list<bool>)
    for i in range(len(ns))
      var n = ns[i]
      var last = (i == len(ns) - 1)
      var is_top = len(ancestors) == 0

      # 顶层分组间距：非首项前插入空行
      if is_top && spacing && len(lines) > 0
        lines->add('')
        linemap->add(-1)
        meta->add({prefix_len: 0, icon_col: 0, icon_w: 0, name_start: 0, name_end: 0, pos_start: 0, pos_end: 0, kind: ''})
      endif

      var prefix = BuildTreePrefix(ancestors, last)
      var icon = FancyIcon(n.kind)
      var name = n.name
      var has_children = len(n.children) > 0
      var ckey = OutlineCollapseKey(n)
      var collapsed = foldable && has_children && get(s_outline_collapsed, ckey, false)
      var fold_indicator = collapsed ? ' [+' .. len(n.children) .. ']' : ''
      var pos_str = show_pos && n.idx >= 0 ? (' (' .. n.lnum .. ':' .. n.col .. ')') : ''

      var line = prefix .. icon .. ' ' .. name .. fold_indicator .. pos_str

      var pref_bytes = strlen(prefix)
      var icon_bytes = strlen(icon)
      var name_bytes = strlen(name)
      var fold_bytes = strlen(fold_indicator)
      var pos_bytes  = strlen(pos_str)

      var icon_col   = pref_bytes + 1
      var name_start = pref_bytes + icon_bytes + 2
      var name_end   = name_start + name_bytes + fold_bytes
      var pos_start  = pos_bytes == 0 ? 0 : name_end
      var pos_end    = pos_bytes == 0 ? 0 : (pos_start + pos_bytes)

      lines->add(line)
      linemap->add(n.idx)
      meta->add({
      prefix_len: pref_bytes,
      icon_col: icon_col,
      icon_w: icon_bytes,
      name_start: name_start,
      name_end: name_end,
      pos_start: pos_start,
      pos_end: pos_end,
      kind: n.kind
      })

      if has_children && !collapsed
        Walk(n.children, ancestors + [last])
      endif
    endfor
  enddef

  Walk(nodes, [])
  return {lines: lines, linemap: linemap, meta: meta}
enddef

def KindToTSGroup(kind: string): string
  if kind ==# 'function'
    return 'TSFunction'
  elseif kind ==# 'method'
    return 'TSMethod'
  elseif kind ==# 'type' || kind ==# 'class' || kind ==# 'struct' || kind ==# 'enum'
    return 'TSType'
  elseif kind ==# 'namespace'
    return 'TSNamespace'
  elseif kind ==# 'variable'
    return 'TSVariable'
  elseif kind ==# 'const'
    return 'TSConstBuiltin'
  elseif kind ==# 'macro'
    return 'TSMacro'
  elseif kind ==# 'property'
    return 'TSProperty'
  elseif kind ==# 'field'
    return 'TSField'
  elseif kind ==# 'variant'
    return 'TSVariant'
  else
    return 'TSVariable'
  endif
enddef

def KindIcon(kind: string): string
  if kind ==# 'function'
    return 'ƒ'
  elseif kind ==# 'method'
    return 'm'
  elseif kind ==# 'type' || kind ==# 'struct' || kind ==# 'class'
    return 'T'
  elseif kind ==# 'enum'
    return 'E'
  elseif kind ==# 'namespace'
    return 'N'
  elseif kind ==# 'variable'
    return 'v'
  elseif kind ==# 'const'
    return 'C'
  elseif kind ==# 'macro'
    return 'M'
  elseif kind ==# 'property' || kind ==# 'field'
    return 'p'
  elseif kind ==# 'variant'
    return 'v'
  elseif kind ==# 'mapping'
    return 'k'
  elseif kind ==# 'module'
    return 'P'
  elseif kind ==# 'event'
    return 'a'
  else
    return '?'
  endif
enddef

def FancyIcon(kind: string): string
  if get(g:, 'simpletreesitter_outline_hide_icon', 0)
    return ''
  endif

  var fancy = get(g:, 'simpletreesitter_outline_fancy', 1)
  if fancy
    if kind ==# 'function'     | return '󰡱' | endif
    if kind ==# 'method'       | return '󰆧' | endif
    if kind ==# 'type'         | return '' | endif
    if kind ==# 'class'        | return '' | endif
    if kind ==# 'struct'       | return '' | endif
    if kind ==# 'enum'         | return '' | endif
    if kind ==# 'namespace'    | return '' | endif
    if kind ==# 'variable'     | return '' | endif
    if kind ==# 'const'        | return '' | endif
    if kind ==# 'macro'        | return '' | endif
    if kind ==# 'property'     | return '' | endif
    if kind ==# 'field'        | return '' | endif
    if kind ==# 'variant'      | return '' | endif
    if kind ==# 'mapping'      | return '⌨' | endif
    if kind ==# 'module'       | return '📦' | endif
    if kind ==# 'event'        | return '⚡' | endif
  endif
  if kind ==# 'function'     | return 'f' | endif
  if kind ==# 'method'       | return 'm' | endif
  if kind ==# 'type'         | return 'T' | endif
  if kind ==# 'class'        | return 'T' | endif
  if kind ==# 'struct'       | return 'T' | endif
  if kind ==# 'enum'         | return 'E' | endif
  if kind ==# 'namespace'    | return 'N' | endif
  if kind ==# 'variable'     | return 'v' | endif
  if kind ==# 'const'        | return 'C' | endif
  if kind ==# 'macro'        | return 'M' | endif
  if kind ==# 'property'     | return 'p' | endif
  if kind ==# 'field'        | return 'p' | endif
  if kind ==# 'variant'      | return 'v' | endif
  if kind ==# 'mapping'      | return 'k' | endif
  if kind ==# 'module'       | return 'P' | endif
  if kind ==# 'event'        | return 'a' | endif
  return ''
enddef

# =============== 符号请求 ===============
def RequestSymbolsNow(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  if !EnsureDaemon() | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' | return | endif

  # 未同步/正在同步时先同步
  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    return
  endif
  var last_ct = get(s_sent_changedtick, buf, -1)
  if ct != last_ct || get(s_inflight_sync, buf, false)
    ScheduleSync(buf)
    return
  endif

  if get(s_inflight_syms, buf, false)
    s_pending_syms[buf] = true
    return
  endif
  s_inflight_syms[buf] = true
  s_pending_syms[buf] = false
  s_symbol_request_purpose[buf] = 'partial'
  s_symbol_request_kinds[buf] = []
  var request_id = NextSymbolRequestId()
  s_symbol_request_ids[buf] = request_id

  var [vstart, vend] = VisibleRangeForBufSymbols(buf)
  var render_limit = get(g:, 'simpletreesitter_outline_max_items', 1000)
  var scan_limit = max([render_limit, get(g:, 'simpletreesitter_outline_scan_max_items', 5000)])
  if !Send({type: 'symbols', buf: buf, lang: lang, lstart: vstart, lend: vend,
      max_items: scan_limit, request_id: request_id})
    s_inflight_syms[buf] = false
    ClearSymbolRequestId(buf)
    remove(s_symbol_request_purpose, string(buf))
    remove(s_symbol_request_kinds, string(buf))
    return
  endif
  Log('Requested symbols (range-only) for buffer ' .. buf .. ' ...')
enddef

def ScheduleSymbols(buf: number)
  if !s_enabled
    return
  endif
  var need_outline = (s_outline_win != 0 && s_outline_src_buf == buf)
  var need_bc = get(g:, 'simpletreesitter_breadcrumb', 0) && IsSupportedLang(buf)
  if !need_outline && !need_bc
    return
  endif
  # 面包屑模式下也跟踪当前 buffer
  if need_bc
    s_bc_buf = buf
  endif
  if s_sym_timer != 0 && exists('*timer_stop')
    try
      call timer_stop(s_sym_timer)
    catch
    endtry
    s_sym_timer = 0
  endif
  if exists('*timer_start')
    try
      var ms = get(g:, 'simpletreesitter_debounce', 120)
      s_sym_timer = timer_start(ms, (id) => {
        s_sym_timer = 0
        RequestSymbolsNow(buf)
      })
    catch
      RequestSymbolsNow(buf)
    endtry
  else
    RequestSymbolsNow(buf)
  endif
enddef

def ShowAst(src_buf: number, lines: list<string>)
  var curwin = win_getid()
  try
    execute 'keepalt botright vsplit'
    execute 'enew'
    execute 'file ts-hl-ast'
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    setlocal nowrap nonumber norelativenumber signcolumn=no
    call setline(1, lines)
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

def RequestAstNow(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  if !EnsureDaemon()
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    return
  endif
  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    echo '[ts-hl] buffer exceeds g:simpletreesitter_max_buffer_bytes'
    s_pending_ast[buf] = false
    return
  endif
  if ct != get(s_sent_changedtick, buf, -1) || get(s_inflight_sync, buf, false)
    s_pending_ast[buf] = true
    ScheduleSync(buf)
    return
  endif
  s_pending_ast[buf] = false
  Send({type: 'dump_ast', buf: buf, lang: lang})
enddef

# DumpAST 使用与当前 changedtick 一致的缓存
export def DumpAST()
  var buf = bufnr()
  if !bufexists(buf)
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    echo '[ts-hl] unsupported filetype for AST'
    return
  endif
  if !s_enabled
    Enable()
  endif
  if !s_enabled
    return
  endif
  RequestAstNow(buf)
enddef

# =============== :TsHlInspect（光标处的 capture 与高亮组） ===============
# 'highlight link A B' 是一条链；只报告链首对想改配色的用户没有用，他必须知道
# 最终落到哪个组。8 跳远超任何真实配色方案，这个上限只是防止有人写出成环的 link
# 时把报告卡死。
def ResolveHighlightChain(group: string): string
  var chain = [group]
  if !exists('*hlget')
    return group
  endif
  var name = group
  for _ in range(8)
    var info: list<dict<any>> = []
    try
      info = hlget(name)
    catch
      break
    endtry
    if empty(info)
      break
    endif
    var linked = get(info[0], 'linksto', '')
    if type(linked) != v:t_string || linked ==# '' || index(chain, linked) >= 0
      break
    endif
    chain->add(linked)
    name = linked
  endfor
  return join(chain, ' -> ')
enddef

# 纯函数：daemon 事件 -> 报告文本。渲染方式（popup/scratch）与它无关，因此格式
# 本身可以被直接断言。
def InspectReportLines(ev: dict<any>, lang: string, verbose: bool): list<string>
  var lines = [printf('ts-hl inspect  %s  [%d:%d]',
    lang ==# '' ? '?' : lang, get(ev, 'lnum', 0), get(ev, 'col', 0))]
  var captures = get(ev, 'captures', [])
  lines->add('')
  if empty(captures)
    lines->add('Captures: none — no pattern in the ' .. lang .. ' query matches here')
  else
    lines->add('Captures (highest priority first; * is the one drawn)')
    for cap in captures
      var group = get(cap, 'group', '')
      var injected = get(cap, 'injected_lang', '')
      lines->add(printf('%s @%-22s %-18s priority %-3d [%d:%d-%d:%d]%s',
        get(cap, 'applied', false) ? '*' : ' ',
        get(cap, 'capture', '?'),
        group ==# '' ? '(no group)' : group,
        get(cap, 'priority', 0),
        get(cap, 'lnum', 0), get(cap, 'col', 0),
        get(cap, 'end_lnum', 0), get(cap, 'end_col', 0),
        injected ==# '' ? '' : '  via ' .. injected))
    endfor
  endif
  # 默认只解析真正画出来的那个组；:TsHlInspect! 解析全部。
  var groups: list<string> = []
  for cap in captures
    var group = get(cap, 'group', '')
    if group ==# '' || index(groups, group) >= 0
      continue
    endif
    if verbose || get(cap, 'applied', false)
      groups->add(group)
    endif
  endfor
  if !empty(groups)
    lines->add('')
    lines->add('Highlight (link the leftmost group to restyle it)')
    for group in groups
      lines->add('  ' .. ResolveHighlightChain(group))
    endfor
  endif
  var chain = get(ev, 'node_chain', [])
  if !empty(chain)
    lines->add('')
    lines->add('Nodes (innermost first)')
    for node in chain
      var field = get(node, 'field', '')
      lines->add(printf('  %-28s [%d:%d-%d:%d]%s',
        get(node, 'kind', '?') .. (get(node, 'named', true) ? '' : ' (anonymous)'),
        get(node, 'lnum', 0), get(node, 'col', 0),
        get(node, 'end_lnum', 0), get(node, 'end_col', 0),
        field ==# '' ? '' : '  field: ' .. field))
    endfor
  endif
  return lines
enddef

def ShowInspect(lines: list<string>)
  if get(g:, 'simpletreesitter_inspect_popup', 1) && exists('*popup_atcursor')
    try
      popup_atcursor(lines, {
        padding: [0, 1, 0, 1],
        border: [],
        moved: 'any',
        maxwidth: 100,
        title: ' ts-hl inspect ',
      })
      return
    catch
    endtry
  endif
  var curwin = win_getid()
  try
    # 上一次的报告窗口可能还开着，而 buffer 名必须唯一。
    var stale = bufnr('^ts-hl-inspect$')
    if stale > 0
      execute 'bwipeout! ' .. stale
    endif
    execute 'keepalt botright split'
    execute 'enew'
    execute 'file ts-hl-inspect'
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    setlocal nowrap nonumber norelativenumber signcolumn=no
    call setline(1, lines)
    execute 'resize ' .. min([max([len(lines), 3]), 20])
    setlocal nomodifiable
    nnoremap <silent><buffer> q :close<CR>
  catch
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

def RequestInspectNow(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  var req = get(s_pending_inspect, buf, {})
  if empty(req)
    return
  endif
  if !EnsureDaemon()
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    return
  endif
  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    echo '[ts-hl] buffer exceeds g:simpletreesitter_max_buffer_bytes'
    remove(s_pending_inspect, string(buf))
    return
  endif
  if ct != get(s_sent_changedtick, buf, -1) || get(s_inflight_sync, buf, false)
    # 保持 pending：set_text/edit_lines 的 ok 会用原始位置重发。
    ScheduleSync(buf)
    return
  endif
  Send({type: 'inspect', buf: buf, lang: lang, lnum: req.lnum, col: req.col})
enddef

# 报告光标处匹配到的 capture、它们映射到的高亮组，以及所在的节点链。
# 加 ! 时连同未被采用的 capture 一起解析 highlight link 链。
export def Inspect(verbose: bool = false)
  var buf = bufnr()
  if !bufexists(buf)
    return
  endif
  if DetectLang(buf) ==# ''
    echo '[ts-hl] inspect unsupported for this &filetype'
    return
  endif
  if !s_enabled
    Enable()
  endif
  if !s_enabled
    return
  endif
  # 握手完成之后才有能力集可查；握手前不拦，让请求自己去撞 daemon 的错误。
  if s_protocol_version > 0 && !get(s_daemon_capabilities, 'inspect', false)
    echo '[ts-hl] this daemon predates :TsHlInspect; run ./install.sh, then :TsHlRestart'
    return
  endif
  # 位置在按键时刻确定：响应可能要等一次同步往返，届时光标早已不在这里。
  s_pending_inspect[buf] = {lnum: line('.'), col: col('.'), verbose: verbose}
  RequestInspectNow(buf)
enddef

# =============== 渲染符号侧边栏（树形 + 高亮） ===============
def OutlineSymbolKey(symbol: dict<any>): string
  return string([
    get(symbol, 'kind', ''),
    get(symbol, 'name', ''),
    get(symbol, 'lnum', 0),
    get(symbol, 'col', 0),
  ])
enddef

def OutlineSelectedKey(): string
  if s_outline_win == 0 || empty(getwininfo(s_outline_win))
    return ''
  endif
  var outline_pos = getcurpos(s_outline_win)
  var row = outline_pos[1] - 1
  if row < 0 || row >= len(s_outline_linemap)
    return ''
  endif
  var item_index = s_outline_linemap[row]
  return item_index >= 0 && item_index < len(s_outline_items)
    ? OutlineSymbolKey(s_outline_items[item_index])
    : ''
enddef

def RestoreOutlineSelection(key: string)
  if key ==# '' || s_outline_win == 0 || empty(getwininfo(s_outline_win))
    return
  endif
  for i in range(len(s_outline_items))
    if OutlineSymbolKey(s_outline_items[i]) ==# key
      var outline_line = get(s_outline_idx_to_lnum, i, 0)
      if outline_line > 0
        call win_execute(s_outline_win, 'call cursor(' .. outline_line .. ', 1)')
      endif
      return
    endif
  endfor
enddef

def OutlineStringField(symbol: dict<any>, field: string): string
  var value = get(symbol, field, '')
  return type(value) == v:t_string ? value : ''
enddef

def NormalizeOutlineSymbols(symbols: list<dict<any>>): list<dict<any>>
  var normalized: list<dict<any>> = []
  for symbol in symbols
    var item = copy(symbol)
    item.name = OutlineStringField(symbol, 'name')
    item.kind = OutlineStringField(symbol, 'kind')
    item.container_name = OutlineStringField(symbol, 'container_name')
    normalized->add(item)
  endfor
  return normalized
enddef

def OutlineItemMatches(symbol: dict<any>, query: string): bool
  if query ==# ''
    return true
  endif
  var name = OutlineStringField(symbol, 'name')
  var kind = OutlineStringField(symbol, 'kind')
  var container = OutlineStringField(symbol, 'container_name')
  var searchable = name .. "\n" .. kind .. "\n" .. container
  return stridx(tolower(searchable), query) >= 0
enddef

def ApplySymbols(buf: number, syms: list<dict<any>>)
  if s_outline_win == 0 || s_outline_buf == 0 || s_outline_src_buf != buf
    return
  endif
  if !bufexists(s_outline_buf)
    return
  endif
  var selected_key = OutlineSelectedKey()
  # Normalize the complete accepted payload once at the outline boundary.
  # Raw cache, signature, filtering, tree building and rendering must all see
  # the same safe string fields instead of diverging on malformed daemon data.
  var accepted = NormalizeOutlineSymbols(syms)
  s_outline_raw_items = copy(accepted)
  s_outline_raw_valid = true

  # 符号 + 折叠状态 + 影响渲染的配置都没变时，跳过整树重建/setline/逐行 prop。
  # symbols 事件常以相同内容重复触发，这一步避免无谓的全量重绘。
  var sig_parts: list<string> = ['buf=' .. buf, string(len(accepted))]
  for s in accepted
    sig_parts->add(get(s, 'kind', '') .. ':' .. get(s, 'name', '')
      .. ':' .. string(get(s, 'lnum', 0)) .. ':' .. string(get(s, 'col', 0))
      .. ':' .. string(get(s, 'end_lnum', 0)) .. ':' .. string(get(s, 'end_col', 0))
      .. ':' .. get(s, 'container_kind', '') .. ':' .. get(s, 'container_name', '')
      .. ':' .. string(get(s, 'container_lnum', 0))
      .. ':' .. string(get(s, 'container_col', 0)))
  endfor
  var collapse_parts: list<string> = []
  for ck in keys(s_outline_collapsed)
    collapse_parts->add(ck .. '=' .. (s_outline_collapsed[ck] ? '1' : '0'))
  endfor
  sig_parts->add('C=' .. join(sort(collapse_parts), ','))
  sig_parts->add('cfg=' .. string([
    get(g:, 'simpletreesitter_outline_hide_inner_functions', 1),
    get(g:, 'simpletreesitter_outline_hide_fields', 1),
    get(g:, 'simpletreesitter_outline_hide_variants', 0),
    get(g:, 'simpletreesitter_outline_show_position', 1),
    get(g:, 'simpletreesitter_outline_max_items', 300),
    get(g:, 'simpletreesitter_outline_exclude_patterns', []),
    get(g:, 'simpletreesitter_outline_disable_props', 1),
    s_outline_filter,
  ]))
  var sig = join(sig_parts, '|')
  if sig ==# s_last_outline_sig
    return
  endif
  s_last_outline_sig = sig

  var items: list<dict<any>> = copy(accepted)

  var hide_inner = get(g:, 'simpletreesitter_outline_hide_inner_functions', 1) ? true : false
  if hide_inner
    var filtered: list<dict<any>> = []
    for s in items
      if get(s, 'container_kind', '') ==# 'function'
        continue
      endif
      filtered->add(s)
    endfor
    items = filtered
  endif

  var pats = get(g:, 'simpletreesitter_outline_exclude_patterns', [])
  if type(pats) == v:t_list && len(pats) > 0
    var filtered2: list<dict<any>> = []
    for s in items
      var skip = false
      for p in pats
        if type(p) == v:t_string && p !=# '' && match(get(s, 'name', ''), p) >= 0
          skip = true
          break
        endif
      endfor
      if !skip
        filtered2->add(s)
      endif
    endfor
    items = filtered2
  endif

  if get(g:, 'simpletreesitter_outline_hide_fields', 1)
    var tmp: list<dict<any>> = []
    for s in items
      if get(s, 'kind', '') ==# 'field'
        continue
      endif
      tmp->add(s)
    endfor
    items = tmp
  endif
  if get(g:, 'simpletreesitter_outline_hide_variants', 1)
    var tmp2: list<dict<any>> = []
    for s in items
      if get(s, 'kind', '') ==# 'variant'
        continue
      endif
      tmp2->add(s)
    endfor
    items = tmp2
  endif

  # User filtering is deliberately applied to the complete accepted payload,
  # after static visibility rules but before the viewport-aware render limit.
  # A matching child keeps its container through BuildTreeByContainer's
  # synthetic-parent path, so hierarchy remains intelligible.
  var normalized_filter = tolower(s_outline_filter)
  if normalized_filter !=# ''
    var filtered3: list<dict<any>> = []
    for symbol in items
      if OutlineItemMatches(symbol, normalized_filter)
        filtered3->add(symbol)
      endif
    endfor
    items = filtered3
  endif

  var max_items = get(g:, 'simpletreesitter_outline_max_items', 300)
  if len(items) > max_items
    # 使用真实视口（无边距），避免 near 覆盖全文件
    var [vstart, vend] = VisibleViewportRangeForBuf(s_outline_src_buf)
    var total = BufLineCount(s_outline_src_buf)
    # 用整数中心的两倍，避免浮点
    var center2 = vstart + vend

    # 拆成视口内/上方/下方
    var near:  list<dict<any>> = []
    var above: list<dict<any>> = []
    var below: list<dict<any>> = []
    for s in items
      var l = get(s, 'lnum', 1)
      if l >= vstart && l <= vend
        call add(near, s)
      elseif l < vstart
        call add(above, s)
      else
        call add(below, s)
      endif
    endfor

    # 上方：从近到远（大->小），下方：从近到远（小->大）
    call sort(above, (a, b) => get(b, 'lnum', 0) - get(a, 'lnum', 0))
    call sort(below, (a, b) => get(a, 'lnum', 0) - get(b, 'lnum', 0))

    # 初始选择：视口内
    var selected = near[ : max_items - 1]
    var need = max_items - len(selected)
    if need > 0
      # 判断更靠近底部还是顶部，靠底部时优先补上方（即当前屏上方、但接近尾部的符号）
      var bias_above_first = (total - vend) < (vstart - 1)
      if bias_above_first
        if len(above) > 0
          selected += above[ : min([need, len(above)]) - 1]
          need = max_items - len(selected)
        endif
        if need > 0 && len(below) > 0
          selected += below[ : min([need, len(below)]) - 1]
          need = max_items - len(selected)
        endif
      else
        if len(below) > 0
          selected += below[ : min([need, len(below)]) - 1]
          need = max_items - len(selected)
        endif
        if need > 0 && len(above) > 0
          selected += above[ : min([need, len(above)]) - 1]
          need = max_items - len(selected)
        endif
      endif
    endif

    # 若还不够：按离视口中心的“整数距离”补齐
    if len(selected) < max_items
      var rest: list<dict<any>> = []
      for s in items
        if index(selected, s) < 0
          rest->add(s)
        endif
      endfor
      # 距离度量：dist = |2*lnum - center2|
      rest->sort((a, b) => {
        var la = get(a, 'lnum', 0)
        var lb = get(b, 'lnum', 0)
        return abs(la * 2 - center2) - abs(lb * 2 - center2)
      })
      var gap = max_items - len(selected)
      selected += rest[ : min([gap, len(rest)]) - 1]
    endif

    items = selected
  endif

  s_outline_items = items

  var nodes = BuildTreeByContainer(items)
  var show_pos = get(g:, 'simpletreesitter_outline_show_position', 1) ? true : false
  var out = RenderTree(nodes, show_pos)
  var lines = out.lines
  s_outline_linemap = out.linemap

  var curwin = win_getid()
  try
    if win_gotoid(s_outline_win)
      setlocal modifiable
      if len(lines) == 0
        lines = [s_outline_filter ==# ''
          ? '<no symbols>'
          : '<no symbols matching "' .. s_outline_filter .. '">']
        s_outline_linemap = [-1]
      endif
      call setline(1, lines)
      var last = len(lines)

      var cur_last = line('$')
      if cur_last > last
        try
          call deletebufline(s_outline_buf, last + 1, '$')
        catch
        endtry
      endif

      var disable_props = get(g:, 'simpletreesitter_outline_disable_props', 1) ? true : false
      try
        call prop_clear(1, last, {bufnr: s_outline_buf})
      catch
      endtry
      if !disable_props
        for i in range(len(lines))
          var lnum = i + 1
          if len(out.meta) <= i
            continue
          endif
          var m = out.meta[i]
          if m.prefix_len > 0
            try | call prop_add(lnum, 1, {type: s_outline_guide_prop, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.prefix_len + 1}) | catch | endtry
          endif
          var grp = KindToTSGroup(m.kind)
          if m.icon_w > 0
            try | call prop_add(lnum, m.icon_col, {type: HlProp(grp), bufnr: s_outline_buf, end_lnum: lnum, end_col: m.icon_col + m.icon_w}) | catch | endtry
          endif
          if m.name_end > m.name_start
            try | call prop_add(lnum, m.name_start, {type: HlProp(grp), bufnr: s_outline_buf, end_lnum: lnum, end_col: m.name_end}) | catch | endtry
          endif
          if m.pos_start > 0 && m.pos_end > m.pos_start
            try | call prop_add(lnum, m.pos_start, {type: s_outline_pos_prop, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.pos_end}) | catch | endtry
          endif
        endfor
      endif

      setlocal nomodifiable
    endif
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry

  # 重建 下标 -> outline 行号 的反查表，供光标跟随 O(1) 使用。
  s_outline_idx_to_lnum = {}
  for i in range(len(s_outline_linemap))
    var sidx = s_outline_linemap[i]
    if sidx >= 0 && !has_key(s_outline_idx_to_lnum, string(sidx))
      s_outline_idx_to_lnum[string(sidx)] = i + 1
    endif
  endfor
  RestoreOutlineSelection(selected_key)
enddef

# =============== 侧边栏窗口管理 ===============
# Buffer names must be unique, and one sidebar per tabpage means more than one
# can exist at a time.  The first keeps the historical name so :buffer
# ts-hl-outline and any user autocmd matching it keep working.
def OutlineBufName(ctx: number): string
  var name = 'ts-hl-outline'
  if bufnr('^' .. name .. '$') != -1
    name ..= '-' .. ctx
  endif
  return name
enddef

export def OutlineOpen()
  SyncOutlineContext()
  var src = bufnr()
  if src == s_outline_buf && s_outline_src_buf != 0
    src = s_outline_src_buf
  endif
  if !IsSupportedLang(src)
    echo '[ts-hl] outline unsupported for this &filetype'
    return
  endif
  if !s_enabled
    Enable()
  endif
  if !s_enabled || !EnsureDaemon()
    return
  endif
  var source_win = win_getid() == s_outline_win ? s_outline_src_win : win_getid()
  if s_outline_win != 0 && win_id2win(s_outline_win) != 0
    if s_outline_state_buf != src
      s_outline_collapsed = {}
      s_outline_filter = ''
      s_outline_raw_items = []
      s_outline_raw_valid = false
      s_outline_state_buf = src
    endif
    s_outline_src_buf = src
    s_outline_src_win = source_win
    s_last_outline_sig = ''
    ScheduleSync(src)
    OutlineRefresh()
    return
  endif
  s_outline_win = 0
  s_outline_buf = 0
  # 新开/重开 outline 时清空签名，确保首帧一定渲染（不被上一个缓冲的签名误判跳过）。
  s_last_outline_sig = ''

  var curwin = win_getid()
  try
    execute 'keepalt botright vsplit'

    if s_outline_buf != 0 && bufexists(s_outline_buf)
      execute 'buffer ' .. s_outline_buf
    else
      execute 'enew'
      s_outline_buf = bufnr('%')
      execute 'file ' .. fnameescape(OutlineBufName(s_outline_ctx))
      setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
      setlocal nowrap nonumber norelativenumber signcolumn=no
      setlocal foldcolumn=0
      setlocal cursorline
      setlocal filetype=simpletreesitter_outline
      setlocal nobuflisted
      setlocal conceallevel=0 concealcursor=
      setlocal winfixwidth
      nnoremap <silent><buffer> <CR> :call simpletreesitter#OutlineJump()<CR>
      nnoremap <silent><buffer> q :call simpletreesitter#OutlineClose()<CR>
      nnoremap <silent><buffer> o :call simpletreesitter#OutlineToggleFold()<CR>
      nnoremap <silent><buffer> za :call simpletreesitter#OutlineToggleFold()<CR>
      nnoremap <silent><buffer> / :call simpletreesitter#OutlinePromptFilter()<CR>
    endif

    s_outline_win = win_getid()
    s_outline_src_buf = src
    s_outline_src_win = source_win
    s_outline_state_buf = src

    var width = get(g:, 'simpletreesitter_outline_width', 32)
    execute 'vertical resize ' .. width

    # 全局暂停：打开时按配置清理各缓冲已绘制 props
    if get(g:, 'simpletreesitter_suspend_highlight_on_outline', 0)
          \ && get(g:, 'simpletreesitter_clear_props_on_suspend', 1)
      ClearAllVisiblePropsOnSuspend()
    endif

    OutlineRefresh()
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

def OutlineTeardown()
  ResetOutlineState()
  Log('[ts-hl] outline closed')

  # 全局暂停 -> 恢复：关闭后主动刷新所有活跃缓冲
  if get(g:, 'simpletreesitter_suspend_highlight_on_outline', 0)
    ResumeAllHighlights()
  endif
enddef

export def OutlineClose()
  SyncOutlineContext()
  if s_outline_win != 0 && !empty(getwininfo(s_outline_win))
    # win_execute() closes the window without ever moving the user; win_gotoid()
    # follows a window id into another tabpage, which is how :TsHlOutlineToggle
    # used to teleport people out of the tab they were working in.
    try
      call win_execute(s_outline_win, 'close')
    catch
    endtry
  endif
  OutlineTeardown()
enddef

# :TsHlDisable and the auto-stop path own every sidebar, not just this tab's.
def CloseAllOutlines()
  var here = OutlineCtxId()
  for nr in range(1, tabpagenr('$'))
    if gettabvar(nr, s_outline_ctx_var, 0) == here
      continue
    endif
    var saved = gettabvar(nr, s_outline_state_var, {})
    if type(saved) != v:t_dict
      continue
    endif
    var wid = get(saved, 'win', 0)
    if wid != 0 && !empty(getwininfo(wid))
      try | call win_execute(wid, 'close') | catch | endtry
    endif
    settabvar(nr, s_outline_state_var, {})
  endfor
  OutlineClose()
enddef

export def OutlineToggle()
  SyncOutlineContext()
  if s_outline_win != 0
    OutlineClose()
  else
    OutlineOpen()
  endif
enddef

export def OutlineRefresh()
  SyncOutlineContext()
  if s_outline_src_buf == 0 || !bufexists(s_outline_src_buf)
    return
  endif
  ScheduleSymbols(s_outline_src_buf)
enddef

export def OutlineFilter(query: string = '')
  SyncOutlineContext()
  if s_outline_win == 0 || s_outline_src_buf == 0 || !bufexists(s_outline_buf)
    echo '[ts-hl] open the Outline before filtering'
    return
  endif
  var normalized = trim(query)
  s_outline_filter = normalized
  s_last_outline_sig = ''
  # Filtering is a pure projection of the latest accepted payload. If a
  # symbols request is still in flight, remembering the query is sufficient:
  # its guarded response will pass through ApplySymbols when it arrives.
  if s_outline_raw_valid
    ApplySymbols(s_outline_src_buf, s_outline_raw_items)
  endif
  if normalized ==# ''
    echo '[ts-hl] outline filter cleared'
  else
    echo '[ts-hl] outline filter: ' .. normalized
  endif
enddef

export def OutlinePromptFilter()
  var query = ''
  try
    query = input('Outline filter (empty to clear): ', s_outline_filter)
  catch
    return
  endtry
  OutlineFilter(query)
enddef

export def OutlineJump()
  SyncOutlineContext()
  if s_outline_win == 0 || s_outline_src_buf == 0
    return
  endif
  var idx_line = line('.') - 1
  if idx_line < 0 || idx_line >= len(s_outline_linemap)
    return
  endif
  var sym_idx = s_outline_linemap[idx_line]
  if sym_idx < 0 || sym_idx >= len(s_outline_items)
    return
  endif
  var it = s_outline_items[sym_idx]
  var lnum = get(it, 'lnum', 1)
  var col  = get(it, 'col', 1)

  var wins = win_findbuf(s_outline_src_buf)
  var target = 0
  if s_outline_src_win != 0 && index(wins, s_outline_src_win) >= 0
    target = s_outline_src_win
  else
    for wid in wins
      if wid != s_outline_win
        target = wid
        break
      endif
    endfor
  endif
  if target != 0
    call win_gotoid(target)
  else
    if s_outline_win == 0 || !win_gotoid(s_outline_win)
      return
    endif
    execute 'keepalt leftabove vsplit'
    execute 'buffer ' .. s_outline_src_buf
    s_outline_src_win = win_getid()
  endif
  call cursor(lnum, col)
  normal! zv
enddef

export def OutlineToggleFold()
  SyncOutlineContext()
  if s_outline_win == 0 || s_outline_buf == 0
    return
  endif
  var idx_line = line('.') - 1
  if idx_line < 0 || idx_line >= len(s_outline_linemap)
    return
  endif
  var sym_idx = s_outline_linemap[idx_line]
  if sym_idx < 0 || sym_idx >= len(s_outline_items)
    return
  endif
  var it = s_outline_items[sym_idx]
  var ckey = it.kind .. '::' .. it.name .. '@' .. it.lnum
  s_outline_collapsed[ckey] = !get(s_outline_collapsed, ckey, false)
  # Re-render from the unfiltered accepted payload so filtering and clearing
  # never compound against an already limited list. ApplySymbols preserves the
  # selected symbol and caller focus.
  ApplySymbols(s_outline_src_buf, s_outline_raw_items)
enddef

# TabEnter 事件回调（导出）：换入本标签页自己的 Outline 状态。
export def OnTabEnter()
  SyncOutlineContext()
  if s_outline_win == 0
    return
  endif
  # Responses that landed while another tabpage was current were dropped by
  # ApplySymbols' source-buffer guard, so ask again instead of leaving this
  # sidebar showing whatever it last managed to render.
  s_last_outline_sig = ''
  OutlineRefresh()
enddef

# 新增：WinClosed 事件回调（导出），用于判断关闭的是否为 outline 窗口
export def OnWinClosed(wid_str: string)
  var wid = 0
  try
    wid = str2nr(wid_str)
  catch
    wid = 0
  endtry
  if wid == 0
    return
  endif
  # The breadcrumb cache is keyed by window id; drop the entry with the window so
  # a long session does not accumulate one string per window ever opened, and so
  # a recycled id cannot inherit a dead window's breadcrumb.
  var wkey = string(wid)
  if has_key(s_breadcrumb_cache, wkey)
    remove(s_breadcrumb_cache, wkey)
  endif
  SyncOutlineContext()
  if wid == s_outline_win
    # 窗口正在关闭中，只剩状态清理；不要再去关一次。
    OutlineTeardown()
    return
  endif
  # A sidebar can also disappear from another tabpage — :tabclose, or the
  # CloseAllOutlines sweep — and that tabpage's stash must not be left pointing
  # at a dead window id that a later win_execute() could resolve to something
  # else entirely.
  for nr in range(1, tabpagenr('$'))
    var saved = gettabvar(nr, s_outline_state_var, {})
    if type(saved) == v:t_dict && get(saved, 'win', 0) == wid
      settabvar(nr, s_outline_state_var, {})
      break
    endif
  endfor
enddef

# =============== 请求调度 ===============
def RequestNow(buf: number)
  if !s_enabled || get(s_closed_bufs, buf, false) || !IsSupportedLang(buf)
    return
  endif
  if !EnsureDaemon() | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' | return | endif
  if IsHighlightSuspended(buf)
    return
  endif

  var ct = GetChangedTick(buf)
  if get(s_skipped_changedtick, buf, -1) == ct
    return
  endif
  if ct != get(s_sent_changedtick, buf, -1) || get(s_inflight_sync, buf, false)
    ScheduleSync(buf)
    return
  endif

  if get(s_inflight_hl, buf, false)
    s_pending_hl[buf] = true
    return
  endif
  s_inflight_hl[buf] = true
  s_pending_hl[buf] = false

  var [hstart, hend] = VisibleRangeForBuf(buf)
  if !Send({
    type: 'highlight',
    buf: buf,
    lang: lang,
    lstart: hstart,
    lend: hend,
    rainbow: get(g:, 'simpletreesitter_rainbow_brackets', 1) ? true : false,
    max_spans: get(g:, 'simpletreesitter_max_props', 20000),
  })
    # 未发出的请求不会有响应来清 inflight 标记，此后本 buffer 再也不会重绘。
    s_inflight_hl[buf] = false
    return
  endif
  Log('Requested highlight (range-only) for buffer ' .. buf .. ' ...')
enddef
