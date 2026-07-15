vim9script

# =============== 状态 ===============
var s_job: any = v:null
var s_running: bool = false
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
# 上次应用的可见范围缓存 {bufnr: [start_lnum, end_lnum]}
var s_last_ranges: dict<list<number>> = {}
# 上次实际写入的高亮类型 {bufnr: [type, ...]}，用于增量清除（只清自己用过的类型）
var s_applied_types: dict<list<string>> = {}
# =============== 侧边栏状态 ===============
var s_outline_win: number = 0
var s_outline_buf: number = 0
var s_outline_src_buf: number = 0
var s_outline_src_win: number = 0
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
  python: 'python',
  go: 'go',
  sh: 'bash',
  bash: 'bash',
  zsh: 'bash',
  vim: 'vim',
  vimrc: 'vim',
}

# =============== 面包屑状态 ===============
var s_bc_items: list<dict<any>> = []
var s_bc_buf: number = 0
var s_bc_timer: number = 0
var s_breadcrumb_cache: string = ''
# =============== Outline 跟随状态 ===============
var s_outline_cursor_line: number = 0
# =============== Outline 折叠状态 ===============
var s_outline_collapsed: dict<bool> = {}
var s_outline_state_buf: number = 0
# =============== 缩进参考线状态 ===============
# winid -> {list: bool, listchars: string}
var s_indent_guide_windows: dict<dict<any>> = {}

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

def FindDaemon(): string
  var p = get(g:, 'simpletreesitter_daemon_path', '')
  if type(p) == v:t_string && p !=# '' && executable(p)
    return p
  endif
  for dir in split(&runtimepath, ',')
    var exe = dir .. '/lib/ts-hl-daemon'
    if executable(exe)
      return exe
    endif
    var exe2 = dir .. '/lib/ts-hl-daemon.exe'
    if executable(exe2)
      return exe2
    endif
  endfor
  return ''
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

def OnDaemonEvent(line: string, generation: number)
  if generation != s_daemon_generation
    return
  endif
  if line ==# ''
    return
  endif
  var ev: any
  try
    ev = json_decode(line)
  catch
    return
  endtry
  if type(ev) != v:t_dict || !has_key(ev, 'type')
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
    var retry = get(s_pending_syms, buf, false)
    s_inflight_syms[buf] = false
    s_pending_syms[buf] = false
    if !EventRevisionIsCurrent(ev, buf)
      Log('Discarded stale symbols for buffer ' .. buf)
      ScheduleSync(buf)
      return
    endif
    var syms = get(ev, 'symbols', [])
    # 面包屑：保存符号数据
    if buf == s_bc_buf && get(g:, 'simpletreesitter_breadcrumb', 0)
      s_bc_items = syms
      ScheduleBreadcrumbUpdate()
    endif
    ApplySymbols(buf, syms)
    if retry
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
  elseif ev.type ==# 'ok'
    var buf = get(ev, 'buf', 0)
    var op  = get(ev, 'op', '')
    if op ==# 'set_text'
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
      if get(s_pending_ast, buf, false)
        s_pending_ast[buf] = false
        RequestAstNow(buf)
      endif
    endif
  elseif ev.type ==# 'hello'
    s_protocol_version = get(ev, 'protocol_version', 0)
    if s_protocol_version < 2 && !s_protocol_notice_shown
      s_protocol_notice_shown = true
      echohl WarningMsg
      echom '[ts-hl] daemon protocol is outdated; run install.sh to rebuild it'
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
    echom '[ts-hl] error: ' .. message
    # 清掉占用标记；只有 cache 失配才重同步，避免永久错误形成重试风暴。
    if buf > 0
      s_inflight_syms[buf] = false
      s_inflight_hl[buf] = false
      s_inflight_sync[buf] = false
      if has_key(s_inflight_revision, buf)
        remove(s_inflight_revision, string(buf))
      endif
      if message =~# 'buffer not cached\|lang mismatch'
        s_sent_changedtick[buf] = -1
        ScheduleSync(buf)
      endif
    endif
  endif
enddef

def EnsureDaemon(): bool
  if s_running && s_job != v:null
    try
      if job_status(s_job) ==# 'run'
        return true
      endif
    catch
    endtry
  endif
  s_running = false
  s_job = v:null
  var exe = FindDaemon()
  if exe ==# ''
    echohl ErrorMsg
    echom '[ts-hl] daemon not found, set g:simpletreesitter_daemon_path or place ts-hl-daemon in runtimepath/lib'
    echohl None
    return false
  endif
  # 新进程没有任何 buffer cache，必须强制所有 buffer 重新握手。
  InvalidateDaemonSession()
  var generation = s_daemon_generation
  try
    s_job = job_start([exe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, l) => OnDaemonEvent(l, generation),
      err_mode: 'nl',
      err_cb: (ch, l) => {
        if generation == s_daemon_generation
          Log('daemon stderr: ' .. l)
        endif
      },
      exit_cb: (ch, code) => {
        if generation == s_daemon_generation
          s_running = false
          s_job = v:null
          InvalidateDaemonSession()
          Log('Daemon exited with code ' .. code)
        endif
    },
    stoponexit: 'term'
    })
  catch
    # job_start() 即使在部分初始化后抛错，也不能留下仍可写入当前状态的 callback。
    InvalidateDaemonSession()
    s_job = v:null
    s_running = false
    echohl ErrorMsg
    echom '[ts-hl] failed to start daemon: ' .. v:exception
    echohl None
    return false
  endtry
  s_running = (s_job != v:null)
  if s_running
    EnsureHlGroupsAndProps()
    Log('Daemon started successfully')
    Send({type: 'hello', client_protocol: 2})
  endif
  return s_running
enddef

def Send(req: dict<any>): bool
  if !s_running
    return false
  endif
  try
    var j = json_encode(req) .. "\n"
    ch_sendraw(s_job, j)
    return true
  catch
    Log('Failed to send request: ' .. v:exception)
    var failed_job = s_job
    s_running = false
    s_job = v:null
    InvalidateDaemonSession()
    if failed_job != v:null
      try | job_stop(failed_job, 'term') | catch | endtry
    endif
    return false
  endtry
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

  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, -1)
  if last_ct == ct
    return
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
    s_skipped_changedtick[buf] = ct
    return
  endif

  var lines = getbufline(buf, 1, '$')
  var text = join(lines, "\n")
  if getbufvar(buf, '&endofline') && !empty(lines)
    text ..= "\n"
  endif
  if has_key(s_skipped_changedtick, buf)
    remove(s_skipped_changedtick, string(buf))
  endif
  if has_key(s_oversized_notified, buf)
    remove(s_oversized_notified, string(buf))
  endif
  s_inflight_sync[buf] = true
  s_inflight_revision[buf] = ct
  if !Send({type: 'set_text', buf: buf, lang: lang, text: text, revision: ct})
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
  if s_outline_win != 0 && win_id2win(s_outline_win) != 0
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

def SetWinbar(text: string)
  if !exists('+winbar')
    return
  endif
  try
    execute 'setlocal winbar=' .. escape(text, ' \|"')
  catch
  endtry
enddef

def UpdateBreadcrumb()
  if !get(g:, 'simpletreesitter_breadcrumb', 0)
    return
  endif
  var buf = bufnr('%')
  if buf != s_bc_buf || empty(s_bc_items)
    if s_breadcrumb_cache !=# ''
      s_breadcrumb_cache = ''
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
  if text ==# s_breadcrumb_cache
    return
  endif
  s_breadcrumb_cache = text
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

export def Disable()
  if !s_enabled && !s_running && s_outline_win == 0
    s_user_disabled = true
    return
  endif
  s_enabled = false
  s_user_disabled = true   # 记录用户主动关闭
  # 先失效当前会话；随后即使旧 channel 中已有回调排队，也不能重新绘制或调度请求。
  var job_to_stop = s_job
  s_running = false
  s_job = v:null
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
  if s_outline_win != 0
    OutlineClose()
  endif
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
  if job_to_stop != v:null
    try
      call job_stop(job_to_stop, 'term')
      Log('Daemon stopped')
    catch
    endtry
  endif
  # 清理缩进参考线
  DisableIndentGuides()
  # 清理面包屑
  s_bc_items = []
  s_breadcrumb_cache = ''
  if s_bc_timer != 0
    try | timer_stop(s_bc_timer) | catch | endtry
    s_bc_timer = 0
  endif
  SetWinbar('')
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
  if !s_running
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
export def Breadcrumb(): string
  return s_breadcrumb_cache
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
        s_outline_state_buf = buf
      endif
      s_outline_src_buf = buf
      s_outline_src_win = win_getid()
      s_last_outline_sig = ''
      ScheduleSymbols(buf)
    else
      s_outline_src_buf = 0
      s_outline_src_win = 0
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
  if had_cache && s_running && s_protocol_version >= 2
    Send({type: 'close_buffer', buf: buf})
  endif
  for state in [s_inflight_sync, s_pending_ast, s_inflight_syms, s_inflight_hl,
      s_pending_syms, s_pending_hl, s_oversized_notified]
    if has_key(state, buf)
      remove(state, string(buf))
    endif
  endfor
  for state in [s_inflight_revision, s_sent_changedtick, s_skipped_changedtick,
      s_req_timers, s_sync_timers]
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
  if buf == s_outline_src_buf
    s_outline_src_buf = 0
    s_outline_src_win = 0
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

  var [vstart, vend] = VisibleRangeForBufSymbols(buf)
  var render_limit = get(g:, 'simpletreesitter_outline_max_items', 1000)
  var scan_limit = max([render_limit, get(g:, 'simpletreesitter_outline_scan_max_items', 5000)])
  Send({type: 'symbols', buf: buf, lang: lang, lstart: vstart, lend: vend, max_items: scan_limit})
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

# =============== 渲染符号侧边栏（树形 + 高亮） ===============
def ApplySymbols(buf: number, syms: list<dict<any>>)
  if s_outline_win == 0 || s_outline_buf == 0 || s_outline_src_buf != buf
    return
  endif
  if !bufexists(s_outline_buf)
    return
  endif

  # 符号 + 折叠状态 + 影响渲染的配置都没变时，跳过整树重建/setline/逐行 prop。
  # symbols 事件常以相同内容重复触发，这一步避免无谓的全量重绘。
  var sig_parts: list<string> = ['buf=' .. buf, string(len(syms))]
  for s in syms
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
  ]))
  var sig = join(sig_parts, '|')
  if sig ==# s_last_outline_sig
    return
  endif
  s_last_outline_sig = sig

  var items: list<dict<any>> = syms

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
        lines = ['<no symbols>']
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
enddef

# =============== 侧边栏窗口管理 ===============
export def OutlineOpen()
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
      execute 'file ts-hl-outline'
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

export def OutlineClose()
  if s_outline_win != 0
    try
      if win_gotoid(s_outline_win)
        execute 'close'
      endif
    catch
    endtry
  endif
  s_outline_win = 0
  s_outline_buf = 0
  s_outline_items = []
  s_outline_linemap = []
  s_outline_idx_to_lnum = {}
  s_last_outline_sig = ''
  s_outline_src_buf = 0
  s_outline_src_win = 0
  s_outline_state_buf = 0
  s_outline_collapsed = {}
  Log('[ts-hl] outline closed')

  # 全局暂停 -> 恢复：关闭后主动刷新所有活跃缓冲
  if get(g:, 'simpletreesitter_suspend_highlight_on_outline', 0)
    ResumeAllHighlights()
  endif
enddef

export def OutlineToggle()
  if s_outline_win != 0
    OutlineClose()
  else
    OutlineOpen()
  endif
enddef

export def OutlineRefresh()
  if s_outline_src_buf == 0 || !bufexists(s_outline_src_buf)
    return
  endif
  ScheduleSymbols(s_outline_src_buf)
enddef

export def OutlineJump()
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
  # 用缓存的 items 重新渲染
  var save_cursor = line('.')
  ApplySymbols(s_outline_src_buf, s_outline_items)
  cursor(min([save_cursor, line('$')]), 1)
enddef

# 新增：WinClosed 事件回调（导出），用于判断关闭的是否为 outline 窗口
export def OnWinClosed(wid_str: string)
  var wid = 0
  try
    wid = str2nr(wid_str)
  catch
    wid = 0
  endtry
  if wid != 0 && wid == s_outline_win
    # 如果关闭的是 outline 窗口，则走统一的清理逻辑
    # 注意：此时窗口已被关闭，OutlineClose 内部 win_gotoid(s_outline_win) 会失败，但不影响清理状态
    OutlineClose()
  endif
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
  Send({
    type: 'highlight',
    buf: buf,
    lang: lang,
    lstart: hstart,
    lend: hend,
    rainbow: get(g:, 'simpletreesitter_rainbow_brackets', 1) ? true : false,
    max_spans: get(g:, 'simpletreesitter_max_props', 20000),
  })
  Log('Requested highlight (range-only) for buffer ' .. buf .. ' ...')
enddef
