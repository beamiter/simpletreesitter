set nocompatible
set nomore
set hidden
call delete('/tmp/simpletreesitter-vim-errors.log')

let s:root = getcwd()
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpletreesitter_daemon_path = s:root . '/target/debug/ts-hl-daemon'
let g:simpletreesitter_debounce = 10
let g:simpletreesitter_scroll_debounce = 10
let g:simpletreesitter_outline_fancy = 0
let g:simpletreesitter_outline_spacing = 0

function! s:AutoloadInfo() abort
  let l:matches = getscriptinfo({'name': 'autoload/simpletreesitter.vim'})
  call assert_equal(1, len(l:matches), 'simpletreesitter autoload script is not sourced exactly once')
  return getscriptinfo({'sid': l:matches[0].sid})[0]
endfunction

function! s:State() abort
  return s:AutoloadInfo().variables
endfunction

function! s:CallPrivate(name, args) abort
  let l:sid = s:AutoloadInfo().sid
  return call(function(printf('<SNR>%d_%s', l:sid, a:name)), a:args)
endfunction

" A plugin must not replace a key the user mapped before it loaded.
nnoremap <leader>th :let g:simpletreesitter_user_mapping_won = 1<CR>
runtime plugin/simpletreesitter.vim

call assert_equal(2, exists(':TsHlStatus'))
for s:auto_ft in ['lua', 'html', 'css', 'markdown']
  call assert_true(index(g:simpletreesitter_auto_enable_filetypes, s:auto_ft) >= 0,
        \ s:auto_ft . ' must auto-enable by default')
endfor
call assert_equal(2, exists(':TsHlNextSymbol'))
call assert_equal(2, exists(':TsHlPrevSymbol'))
call assert_equal(2, exists(':TsHlOutlineFilter'))
call assert_match('simpletreesitter_user_mapping_won', maparg('<leader>th', 'n'))
call assert_notequal('', maparg('<Plug>(simpletreesitter-toggle)', 'n'))
call assert_notequal('', maparg('<Plug>(simpletreesitter-next-symbol)', 'n'))
call assert_notequal('', maparg('<Plug>(simpletreesitter-prev-symbol)', 'n'))
call assert_match('v:count1', maparg('<Plug>(simpletreesitter-next-symbol)', 'n'),
      \ 'next-symbol <Plug> mapping must preserve a user count')

enew
call setline(1, ['pub fn main() {', '    let answer = 42;', '}'])
setfiletype rust
let s:source = bufnr()
call simpletreesitter#Enable()
sleep 300m

let s:props = prop_list(1, {'bufnr': s:source})
call assert_true(len(s:props) > 0, 'Rust source did not receive text properties')
for s:prop in s:props
  call assert_match('^SimpleTreeSitter_', get(s:prop, 'type', ''))
endfor

call simpletreesitter#OutlineOpen()
sleep 300m
let s:window_count = winnr('$')
let s:outline = bufnr('ts-hl-outline')
call assert_true(s:outline > 0, 'outline buffer was not created')
call assert_match('main', join(getbufline(s:outline, 1, '$'), "\n"))

" Open is idempotent and must not orphan a second outline window.
call simpletreesitter#OutlineOpen()
sleep 100m
call assert_equal(s:window_count, winnr('$'))
call assert_equal(1, len(win_findbuf(s:outline)))

" Outline filtering projects the last raw response locally, before the render
" limit, and does not allocate/send another symbols request. Selection in the
" outline and focus in the source split survive filtering and clearing.
let s:outline_win = win_findbuf(s:outline)[0]
call win_execute(s:outline_win, 'let g:simpletreesitter_filter_map = maparg("/", "n")')
call assert_match('OutlinePromptFilter', g:simpletreesitter_filter_map,
      \ 'Outline / mapping does not open the filter prompt')
call assert_false(s:CallPrivate('OutlineItemMatches', [
      \ {'name': 17, 'kind': 23, 'container_name': 42}, '17']),
      \ 'outline filter stringified malformed numeric symbol fields')
call assert_true(s:CallPrivate('OutlineItemMatches', [
      \ {'name': 17, 'kind': 23, 'container_name': 'Module'}, 'module']),
      \ 'outline filter lost a valid string field beside malformed fields')
call simpletreesitter#OutlineFilter('needle')
let s:malformed_symbols = [
      \ {'name': 17, 'kind': ['needle'], 'container_name': 42,
      \  'lnum': 1, 'col': 1, 'end_lnum': 1, 'end_col': 2},
      \ {'name': 'needle_survivor', 'kind': 'method', 'container_name': '',
      \  'lnum': 2, 'col': 1, 'end_lnum': 2, 'end_col': 2},
      \ ]
call s:CallPrivate('ApplySymbols', [s:source, s:malformed_symbols])
let s:malformed_lines = join(getbufline(s:outline, 1, '$'), "\n")
call assert_match('needle_survivor', s:malformed_lines,
      \ 'active filter lost the valid symbol beside malformed fields')
call assert_notmatch('17\|\[''needle''\]', s:malformed_lines,
      \ 'active filter stringified a malformed number/list field')
let s:normalized_raw = s:State().s_outline_raw_items
call assert_equal('', s:normalized_raw[0].name)
call assert_equal('', s:normalized_raw[0].kind)
call assert_equal('', s:normalized_raw[0].container_name)
call assert_equal(v:t_string, type(s:normalized_raw[0].name))
call assert_equal(v:t_string, type(s:normalized_raw[0].kind))
call assert_equal(v:t_string, type(s:normalized_raw[0].container_name))
call assert_equal(17, s:malformed_symbols[0].name,
      \ 'outline normalization mutated the accepted caller payload')
call assert_equal(['needle'], s:malformed_symbols[0].kind,
      \ 'outline normalization reused the malformed kind list in place')
call simpletreesitter#OutlineFilter('')
let s:filter_symbols = [
      \ {'name': 'alpha_symbol', 'kind': 'function', 'lnum': 1, 'col': 1,
      \  'end_lnum': 1, 'end_col': 5},
      \ {'name': 'beta_symbol', 'kind': 'function', 'lnum': 2, 'col': 1,
      \  'end_lnum': 2, 'end_col': 5},
      \ ]
let s:old_outline_limit = g:simpletreesitter_outline_max_items
let g:simpletreesitter_outline_max_items = 1
call s:CallPrivate('ApplySymbols', [s:source, s:filter_symbols])
let s:filter_state_before = s:State()
let s:filter_request_counter = s:filter_state_before.s_next_symbol_request_id
let s:filter_request_ids = deepcopy(s:filter_state_before.s_symbol_request_ids)
let s:source_win_before_filter = win_getid()
call simpletreesitter#OutlineFilter('BETA')
call assert_equal(s:source_win_before_filter, win_getid(), 'Outline filter stole source focus')
let s:filtered_lines = getbufline(s:outline, 1, '$')
call assert_match('beta_symbol', join(s:filtered_lines, "\n"))
call assert_notmatch('alpha_symbol', join(s:filtered_lines, "\n"),
      \ 'filter ran after the one-item render limit')
let s:filtered_state = s:State()
call assert_equal(2, len(s:filtered_state.s_outline_raw_items),
      \ 'filter discarded the unfiltered symbols payload')
call assert_equal('BETA', s:filtered_state.s_outline_filter)
call assert_equal(s:filter_request_counter, s:filtered_state.s_next_symbol_request_id,
      \ 'filter allocated a symbols request')
call assert_equal(s:filter_request_ids, s:filtered_state.s_symbol_request_ids,
      \ 'filter changed in-flight request correlation state')

let g:simpletreesitter_outline_max_items = s:old_outline_limit
call win_execute(s:outline_win, 'call cursor(1, 1)')
call simpletreesitter#OutlineFilter('')
let s:restored_lines = getbufline(s:outline, 1, '$')
call assert_match('alpha_symbol', join(s:restored_lines, "\n"))
call assert_match('beta_symbol', join(s:restored_lines, "\n"))
call assert_equal(s:source_win_before_filter, win_getid(), 'clearing filter stole source focus')
let s:beta_line = match(s:restored_lines, 'beta_symbol') + 1
call assert_equal(s:beta_line, getcurpos(s:outline_win)[1],
      \ 'clearing filter did not preserve the selected symbol')

" An accepted empty payload is still a valid raw snapshot; clearing a filter
" must replace the filtered-empty message without issuing a request.
call simpletreesitter#OutlineFilter('nothing')
call s:CallPrivate('ApplySymbols', [s:source, []])
call assert_match('no symbols matching', getbufline(s:outline, 1)[0])
call simpletreesitter#OutlineFilter('')
call assert_equal('<no symbols>', getbufline(s:outline, 1)[0])

" A remembered query applies to the next accepted response without a Send.
call simpletreesitter#OutlineFilter('late_result')
call s:CallPrivate('ApplySymbols', [s:source, [
      \ {'name': 'ignored', 'kind': 'function', 'lnum': 1, 'col': 1},
      \ {'name': 'late_result', 'kind': 'method', 'lnum': 2, 'col': 1},
      \ ]])
call assert_match('late_result', join(getbufline(s:outline, 1, '$'), "\n"))
call assert_notmatch('ignored', join(getbufline(s:outline, 1, '$'), "\n"))

" Switching to an unsupported buffer clears every old outline line and jump map.
enew
setfiletype text
sleep 100m
call assert_equal(['<outline unsupported for this filetype>'], getbufline(s:outline, 1, '$'))
call assert_equal(s:window_count, winnr('$'))
call assert_equal('', s:State().s_outline_filter,
      \ 'switching Outline source retained the previous query')
call assert_equal([], s:State().s_outline_raw_items,
      \ 'switching Outline source retained the previous raw symbols')

execute 'buffer ' . s:source
sleep 300m
call assert_match('main', join(getbufline(s:outline, 1, '$'), "\n"))

" Disable clears owned properties and must not be undone by the permanent
" BufEnter/FileType bootstrap autocmd.
let s:source_revision = getbufinfo(s:source)[0].changedtick
let s:old_generation = get(s:State(), 's_daemon_generation', -1)
call simpletreesitter#Disable()
sleep 100m
call assert_notequal(s:old_generation, s:State().s_daemon_generation,
      \ 'Disable did not invalidate the daemon generation')
call assert_equal([], prop_list(1, {'bufnr': s:source}))
doautocmd BufEnter
sleep 100m
call assert_equal([], prop_list(1, {'bufnr': s:source}))

" Events already queued by the old job must be fenced off after Disable.  The
" job-level fence now lives in the supervisor (see tests/vim_core.vim); what
" this checks is that a leaked event cannot revive a disabled plugin.
call s:CallPrivate('OnDaemonEvent', [{
      \ 'type': 'error',
      \ 'buf': s:source,
      \ 'message': 'buffer not cached',
      \ }])
call s:CallPrivate('OnDaemonEvent', [{
      \ 'type': 'hello',
      \ 'protocol_version': 2,
      \ }])
sleep 100m
call assert_false(simpletreesitter#core#IsRunning(),
      \ 'old daemon callback restarted the daemon after Disable')
call assert_equal([], prop_list(1, {'bufnr': s:source}))

" BufUnload/close tombstones must reject a late ACK before it can revive the
" sent revision and make a following highlight event look current.
enew
call setline(1, ['fn closed_buffer() {}'])
setfiletype rust
let s:closed = bufnr()
call simpletreesitter#Enable()
sleep 100m
let s:closed_revision = getbufinfo(s:closed)[0].changedtick
call prop_clear(1, line('$'), {'bufnr': s:closed})
call simpletreesitter#OnBufClose(s:closed)
call s:CallPrivate('OnDaemonEvent', [{
      \ 'type': 'ok',
      \ 'op': 'set_text',
      \ 'buf': s:closed,
      \ 'revision': s:closed_revision,
      \ }])
call s:CallPrivate('OnDaemonEvent', [{
      \ 'type': 'highlights',
      \ 'buf': s:closed,
      \ 'revision': s:closed_revision,
      \ 'spans': [{
      \   'lnum': 1,
      \   'col': 1,
      \   'end_lnum': 1,
      \   'end_col': 3,
      \   'group': 'TSKeyword',
      \ }],
      \ }])
let s:closed_state = s:State()
call assert_true(get(s:closed_state.s_closed_bufs, string(s:closed), 0))
call assert_false(has_key(s:closed_state.s_sent_changedtick, string(s:closed)), 'late ACK revived a closed buffer revision')
call assert_equal([], prop_list(1, {'bufnr': s:closed}), 'late event redrew a closed buffer')

" A real unload/reload cycle removes the tombstone on the next BufEnter.
setlocal nomodified
enew
execute 'bunload ' . s:closed
call assert_false(bufloaded(s:closed))
call assert_true(get(s:State().s_closed_bufs, string(s:closed), 0))
execute 'buffer ' . s:closed
call assert_true(bufloaded(s:closed))
call assert_false(has_key(s:State().s_closed_bufs, string(s:closed)), 'BufEnter did not clear the closed-buffer tombstone')
call simpletreesitter#Disable()

" The preflight byte counter is exact for modified/unnamed buffers, including
" the final-EOL byte, and also exercises the fast getfsize path for clean files.
enew
call setline(1, ['abc', 'de'])
setlocal noendofline
let s:bytes_buf = bufnr()
call assert_false(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 6]))
call assert_true(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 5]))
setlocal endofline
call assert_false(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 7]))
call assert_true(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 6]))
enew
call assert_false(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 7]))
call assert_true(s:CallPrivate('BufferTextExceedsLimit', [s:bytes_buf, 6]))

" MergeChange composes successive listener changes into one splice that stays
" anchored to the last synced snapshot.
call s:CallPrivate('MergeChange', [999, 2, 4, -1])
let s:splice = s:State().s_pending_splice['999']
call assert_equal({'os': 2, 'oe': 4, 'ne': 3}, s:splice)
call s:CallPrivate('MergeChange', [999, 1, 1, 2])
let s:splice = s:State().s_pending_splice['999']
call assert_equal({'os': 1, 'oe': 4, 'ne': 5}, s:splice)
" Current line 5 maps back to old line 4 (two lines were inserted above, one
" removed), so the composed old range grows to [1, 5).
call s:CallPrivate('MergeChange', [999, 5, 6, 0])
let s:splice = s:State().s_pending_splice['999']
call assert_equal({'os': 1, 'oe': 5, 'ne': 6}, s:splice)
call simpletreesitter#OnBufClose(999)
call assert_false(has_key(s:State().s_pending_splice, '999'))

" End-to-end incremental sync: an edit after the first full sync travels via
" edit_lines and highlights keep tracking the buffer.
enew
call setline(1, ['fn incr_one() {', '    let a = 1;', '}'])
setfiletype rust
let s:incr = bufnr()
call simpletreesitter#Enable()
sleep 300m
call assert_true(len(prop_list(1, {'bufnr': s:incr})) > 0, 'no props before incremental edit')
call setline(2, '    let renamed_variable = 2;')
call listener_flush(s:incr)
" -es 模式下 setline() 不触发 TextChanged，手动模拟自动命令
call simpletreesitter#OnBufEvent(s:incr)
sleep 300m
let s:incr_state = s:State()
call assert_equal(getbufinfo(s:incr)[0].changedtick,
      \ get(s:incr_state.s_sent_changedtick, string(s:incr), -1),
      \ 'incremental edit was not acknowledged')
call assert_false(has_key(s:incr_state.s_pending_splice, string(s:incr)),
      \ 'pending splice survived a completed sync')
call assert_true(len(prop_list(2, {'bufnr': s:incr})) > 0, 'no props after incremental edit')

" Tree-sitter folds: multi-line functions produce nested expr folds, and
" toggling off restores the window's previous fold settings.
let g:simpletreesitter_folds = 0
call simpletreesitter#FoldsToggle()
sleep 300m
call assert_equal('expr', &l:foldmethod, 'foldmethod was not applied')
call assert_match('simpletreesitter#FoldExpr', &l:foldexpr)
call assert_equal('>1', simpletreesitter#FoldExpr(1))
call assert_true(foldlevel(2) > 0, 'line 2 is not inside a fold')
call simpletreesitter#FoldsToggle()
call assert_equal('manual', &l:foldmethod, 'fold settings were not restored')
call assert_equal(0, g:simpletreesitter_folds)

" :TsHlSymbols fills the location list.
call simpletreesitter#SymbolsToLoclist()
sleep 300m
let s:loc = getloclist(win_findbuf(s:incr)[0])
call assert_true(len(s:loc) > 0, 'TsHlSymbols produced an empty location list')
call assert_match('incr_one', join(map(copy(s:loc), 'v:val.text'), ' '))
lclose
call simpletreesitter#Disable()

" Full-buffer symbol navigation is asynchronous, count-aware and wraps.  Two
" requests queued before the first response must coalesce into two steps.
enew
call setline(1, ['fn alpha() {}', 'fn beta() {}', 'fn gamma() {}'])
setfiletype rust
let s:nav = bufnr()
call simpletreesitter#Enable()
sleep 300m

" A protocol-v4 daemon omits request_id. The additive v5 guard must explicitly
" preserve that legacy path, leaving revision/op/kind validation in charge.
call s:CallPrivate('OnDaemonEvent', [{'type': 'hello', 'protocol_version': 4}])
call assert_true(s:CallPrivate('SymbolEventMatchesCurrent', [{
      \ 'type': 'symbols', 'buf': s:nav, 'revision': getbufinfo(s:nav)[0].changedtick,
      \ }, s:nav]), 'protocol-v4 symbol response unexpectedly required request_id')
call s:CallPrivate('OnDaemonEvent', [{'type': 'hello', 'protocol_version': 5}])

" Reserve three tokens as already-retired request identities so the injected
" responses below are genuinely older than the live request, not just unequal.
let s:late_full_token = s:CallPrivate('NextSymbolRequestId', [])
let s:late_partial_token = s:CallPrivate('NextSymbolRequestId', [])
let s:late_error_token = s:CallPrivate('NextSymbolRequestId', [])

call cursor(1, 4)
call simpletreesitter#NextSymbol()
call simpletreesitter#NextSymbol()

" Full, partial and error replies from older requests may arrive after this
" full navigation request. None may clear its purpose/token, consume its jump,
" or move the cursor; the matching real daemon reply below must still win.
let s:token_state = s:State()
let s:expected_symbol_request = get(s:token_state.s_symbol_request_ids, string(s:nav), 0)
call assert_true(s:expected_symbol_request > 0, 'full navigation request has no v5 token')
let s:pending_jump = deepcopy(s:token_state.s_symbol_jump_pending[string(s:nav)])
let s:nav_revision = getbufinfo(s:nav)[0].changedtick
for [s:late_label, s:late_token] in [
      \ ['full', s:late_full_token],
      \ ['partial', s:late_partial_token],
      \ ]
  call s:CallPrivate('OnDaemonEvent', [{
        \ 'type': 'symbols', 'buf': s:nav, 'revision': s:nav_revision,
        \ 'request_id': s:late_token,
        \ 'symbols': [{'name': 'stale_' . s:late_label, 'kind': 'function',
        \   'lnum': 2, 'col': 4}],
        \ }])
  let s:after_late_success = s:State()
  call assert_equal(s:expected_symbol_request,
        \ get(s:after_late_success.s_symbol_request_ids, string(s:nav), 0),
        \ 'late ' . s:late_label . ' response cleared the current token')
  call assert_equal('full', get(s:after_late_success.s_symbol_request_purpose,
        \ string(s:nav), ''), 'late ' . s:late_label . ' response changed request purpose')
  call assert_equal(s:pending_jump, s:after_late_success.s_symbol_jump_pending[string(s:nav)],
        \ 'late ' . s:late_label . ' response consumed the current jump')
  call assert_equal(1, line('.'), 'late ' . s:late_label . ' response moved the cursor')
endfor
call s:CallPrivate('OnDaemonEvent', [{
      \ 'type': 'error', 'buf': s:nav, 'op': 'symbols',
      \ 'request_id': s:late_error_token,
      \ 'message': 'stale symbol failure',
      \ }])
let s:after_late_error = s:State()
call assert_equal(s:expected_symbol_request,
      \ get(s:after_late_error.s_symbol_request_ids, string(s:nav), 0),
      \ 'late symbols error cleared the current token')
call assert_true(get(s:after_late_error.s_inflight_syms, string(s:nav), v:false),
      \ 'late symbols error cleared current inflight state')
call assert_equal(s:pending_jump, s:after_late_error.s_symbol_jump_pending[string(s:nav)],
      \ 'late symbols error consumed the current jump')

sleep 300m
call assert_equal(3, line('.'), 'queued NextSymbol calls did not coalesce or jump to gamma')
call assert_false(has_key(s:State().s_symbol_request_ids, string(s:nav)),
      \ 'matching symbols response left its request token behind')
call simpletreesitter#NextSymbol()
sleep 300m
call assert_equal(1, line('.'), 'NextSymbol did not wrap to alpha')
call simpletreesitter#PrevSymbol(2)
sleep 300m
call assert_equal(2, line('.'), 'counted PrevSymbol did not wrap to beta')

" A completed full-buffer response is cached by revision/config. The next
" command must navigate immediately without another daemon round-trip.
let s:nav_state = s:State()
call assert_true(has_key(s:nav_state.s_full_symbol_cache, string(s:nav)),
      \ 'full symbol response was not cached')
let s:cached_symbols = s:nav_state.s_full_symbol_cache[string(s:nav)].symbols
call simpletreesitter#NextSymbol()
call assert_equal(3, line('.'), 'cached symbol navigation was not immediate')
call assert_false(get(s:State().s_inflight_syms, string(s:nav), v:false),
      \ 'cached navigation unexpectedly sent another symbols request')

" An async response updates only the initiating split. Switching away must not
" steal focus, and moving the source cursor invalidates the captured context.
call cursor(1, 4)
let s:nav_win = win_getid()
let s:nav_tick = getbufinfo(s:nav)[0].changedtick
vnew
let s:other_win = win_getid()
let s:jump = {'steps': 1, 'winid': s:nav_win, 'lnum': 1, 'col': 4,
      \ 'changedtick': s:nav_tick,
      \ 'kinds': copy(g:simpletreesitter_symbol_jump_kinds)}
call s:CallPrivate('JumpToSymbol', [s:nav, s:cached_symbols, s:jump])
call assert_equal(s:other_win, win_getid(), 'symbol response stole current-window focus')
call assert_equal(2, getcurpos(s:nav_win)[1], 'originating split was not updated')
close
call cursor(1, 4)
let s:moved = copy(s:jump)
call cursor(2, 4)
call s:CallPrivate('JumpToSymbol', [s:nav, s:cached_symbols, s:moved])
call assert_equal(2, line('.'), 'stale cursor context performed a surprise jump')

" A typed daemon error must clear only its matching request class. Requesting
" an unfiltered loclist cannot reuse the filtered navigation cache, so this is
" a real inflight full request when the synthetic highlight error arrives.
call simpletreesitter#SymbolsToLoclist()
call assert_equal('full', get(s:State().s_symbol_request_purpose,
      \ string(s:nav), ''), 'loclist did not start a full symbols request')
call s:CallPrivate('OnDaemonEvent', [{'type': 'error', 'buf': s:nav,
      \ 'op': 'highlight', 'message': 'synthetic highlight failure'}])
call assert_equal('full', get(s:State().s_symbol_request_purpose,
      \ string(s:nav), ''), 'unrelated error destroyed symbol request purpose')
sleep 300m
lclose
call simpletreesitter#Disable()

" Oversize preflight can complete after a jump is queued. It must cancel that
" pending action so shrinking the buffer later cannot trigger a stale jump.
enew
let b:simpletreesitter_max_buffer_bytes = 1
call setline(1, ['fn too_large() {}'])
setfiletype rust
let s:oversized = bufnr()
call simpletreesitter#NextSymbol()
sleep 100m
call assert_false(has_key(s:State().s_symbol_jump_pending, string(s:oversized)),
      \ 'oversized buffer left a stale symbol jump queued')
call simpletreesitter#Disable()

" New filetypes route to the daemon languages.
for [s:ft, s:expected] in items({'typescript': 'typescript', 'typescriptreact': 'tsx',
      \ 'json': 'json', 'yaml': 'yaml', 'toml': 'toml'})
  enew
  execute 'setfiletype ' . s:ft
  call assert_equal(s:expected, s:CallPrivate('DetectLang', [bufnr()]),
        \ 'DetectLang failed for ' . s:ft)
endfor

" TypeScript end-to-end: highlights and symbols from the real daemon.
enew
call setline(1, ['interface Shape {', '  area(): number;', '}',
      \ 'function makeShape(): Shape {', '  return { area: () => 1 };', '}'])
setfiletype typescript
let s:ts = bufnr()
call simpletreesitter#Enable()
sleep 300m
call assert_true(len(prop_list(1, {'bufnr': s:ts})) > 0, 'TypeScript received no text properties')
call simpletreesitter#OutlineOpen()
sleep 300m
let s:ts_outline = join(getbufline(bufnr('ts-hl-outline'), 1, '$'), "\n")
call assert_match('makeShape', s:ts_outline)
call assert_match('Shape', s:ts_outline)
call simpletreesitter#OutlineClose()
call simpletreesitter#Disable()

let s:size_file = '/tmp/simpletreesitter-size-preflight.txt'
call writefile(['123456'], s:size_file, 'b')
execute 'edit ' . fnameescape(s:size_file)
setlocal fileencoding=utf-8 fileformat=unix nobomb nomodified
call assert_false(&l:endofline)
call assert_equal(6, getfsize(s:size_file))
call assert_false(s:CallPrivate('BufferTextExceedsLimit', [bufnr(), 6]))
call assert_true(s:CallPrivate('BufferTextExceedsLimit', [bufnr(), 5]))
call delete(s:size_file)

" Breadcrumb text is data, never a statusline format string. Vim parses 'winbar'
" like 'statusline', so a container symbol whose name contains %{...} used to be
" evaluated on the next redraw -- code execution from moving the cursor in an
" untrusted file -- and a plain '%' raised E539 and lost the breadcrumb.
let g:simpletreesitter_breadcrumb = 1
enew
call setline(1, ['# 100% %{execute("let g:pwned = 1")} coverage', 'body text'])
setfiletype markdown
let s:bc = bufnr()
call simpletreesitter#Enable()
sleep 200m
call s:CallPrivate('ScheduleSymbols', [s:bc])
call assert_equal(s:bc, s:State().s_bc_buf, 'breadcrumb did not adopt the current buffer')
let s:hostile = '100% %{execute("let g:pwned = 1")} coverage'
call s:CallPrivate('SetBreadcrumbItems', [s:bc, [
      \ {'name': s:hostile, 'kind': 'namespace', 'lnum': 1, 'col': 1,
      \  'end_lnum': 2, 'end_col': 1}]])
call cursor(2, 1)
call s:CallPrivate('UpdateBreadcrumb', [])
call assert_match('100% ', simpletreesitter#Breadcrumb(),
      \ 'breadcrumb dropped the literal symbol name')
call assert_match('coverage', simpletreesitter#Breadcrumb(),
      \ 'breadcrumb truncated the symbol name at the % item')
call assert_equal('%{simpletreesitter#Breadcrumb()}',
      \ s:CallPrivate('WinbarValue', [simpletreesitter#Breadcrumb()]),
      \ 'breadcrumb text was interpolated into the winbar format string')
call assert_equal('', s:CallPrivate('WinbarValue', ['']),
      \ 'an empty breadcrumb must clear winbar, not evaluate to an empty bar')
if exists('+winbar')
  call assert_equal('%{simpletreesitter#Breadcrumb()}', &l:winbar,
        \ 'winbar does not hold the fixed breadcrumb expression')
endif
redraw
call assert_false(exists('g:pwned'),
      \ 'breadcrumb evaluated a %{} payload taken from a symbol name')
let g:simpletreesitter_breadcrumb = 0
call simpletreesitter#Disable()

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simpletreesitter-vim-errors.log')
  cquit
endif
qa!
