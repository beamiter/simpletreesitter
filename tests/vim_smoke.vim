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
call assert_match('simpletreesitter_user_mapping_won', maparg('<leader>th', 'n'))
call assert_notequal('', maparg('<Plug>(simpletreesitter-toggle)', 'n'))

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

" Switching to an unsupported buffer clears every old outline line and jump map.
enew
setfiletype text
sleep 100m
call assert_equal(['<outline unsupported for this filetype>'], getbufline(s:outline, 1, '$'))
call assert_equal(s:window_count, winnr('$'))

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

" Events already queued by the old job must be fenced off after Disable.
call s:CallPrivate('OnDaemonEvent', [json_encode({
      \ 'type': 'error',
      \ 'buf': s:source,
      \ 'message': 'buffer not cached',
      \ }), s:old_generation])
call s:CallPrivate('OnDaemonEvent', [json_encode({
      \ 'type': 'hello',
      \ 'protocol_version': 2,
      \ }), s:old_generation])
sleep 100m
let s:disabled_state = s:State()
call assert_false(s:disabled_state.s_running, 'old daemon callback restarted the daemon after Disable')
call assert_equal(0, s:disabled_state.s_protocol_version, 'old daemon callback mutated disabled protocol state')
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
let s:closed_generation = s:State().s_daemon_generation
call prop_clear(1, line('$'), {'bufnr': s:closed})
call simpletreesitter#OnBufClose(s:closed)
call s:CallPrivate('OnDaemonEvent', [json_encode({
      \ 'type': 'ok',
      \ 'op': 'set_text',
      \ 'buf': s:closed,
      \ 'revision': s:closed_revision,
      \ }), s:closed_generation])
call s:CallPrivate('OnDaemonEvent', [json_encode({
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
      \ }), s:closed_generation])
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

let s:size_file = '/tmp/simpletreesitter-size-preflight.txt'
call writefile(['123456'], s:size_file, 'b')
execute 'edit ' . fnameescape(s:size_file)
setlocal fileencoding=utf-8 fileformat=unix nobomb nomodified
call assert_false(&l:endofline)
call assert_equal(6, getfsize(s:size_file))
call assert_false(s:CallPrivate('BufferTextExceedsLimit', [bufnr(), 6]))
call assert_true(s:CallPrivate('BufferTextExceedsLimit', [bufnr(), 5]))
call delete(s:size_file)

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simpletreesitter-vim-errors.log')
  cquit
endif
qa!
