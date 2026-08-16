" SimpleRemote integration: virtual remote:// buffers ('buftype' acwrite) and
" the User SimpleRemoteBufferRead event.  Drives the real daemon like
" tests/vim_smoke.vim; simpleremote itself is never on the runtimepath -- the
" event is fired by hand with the documented payload in g:simpleremote_event.
set nocompatible
set nomore
set hidden
call delete('/tmp/simpletreesitter-vim-remote-errors.log')

let s:root = getcwd()
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpletreesitter_daemon_path = s:root . '/target/debug/ts-hl-daemon'
call assert_true(filereadable(g:simpletreesitter_daemon_path),
      \ 'target/debug/ts-hl-daemon is missing -- run `make vim-remote`, not vim directly')
let g:simpletreesitter_debounce = 10
let g:simpletreesitter_scroll_debounce = 10
let g:simpletreesitter_outline_fancy = 0
let g:simpletreesitter_outline_spacing = 0
" A private log path: the default is /tmp/ts-hl.log, which belongs to whatever
" Vim the developer running `make check` happens to have open.
let g:simpletreesitter_log_file = '/tmp/simpletreesitter-vim-remote.log'

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

" Poll until Cond() holds or the budget runs out; the daemon answers
" asynchronously and the machine running this may be slow.
function! s:WaitFor(Cond, message, ms = 3000) abort
  let l:deadline = reltime()
  while reltimefloat(reltime(l:deadline)) * 1000 < a:ms
    if a:Cond()
      return v:true
    endif
    sleep 20m
  endwhile
  call assert_true(a:Cond(), a:message)
  return v:false
endfunction

function! s:HasProps(buf, lnum) abort
  return len(prop_list(a:lnum, {'bufnr': a:buf})) > 0
endfunction

" What simpleremote's ApplyRemoteRead() does once the text arrives: the lines
" are set on the (possibly non-current) buffer, 'buftype' becomes acwrite,
" b:vimrc_remote is filled in, and the event is emitted with the buffer number
" in the payload.
function! s:SimulateRemoteRead(buf, path, lines) abort
  let l:old = len(getbufline(a:buf, 1, '$'))
  call setbufline(a:buf, 1, a:lines)
  if l:old > len(a:lines)
    call deletebufline(a:buf, len(a:lines) + 1, l:old)
  endif
  call setbufvar(a:buf, '&buftype', 'acwrite')
  call setbufvar(a:buf, '&swapfile', 0)
  call setbufvar(a:buf, 'vimrc_remote', {'path': a:path, 'uri': 'remote://' . a:path, 'generation': 1})
  call setbufvar(a:buf, '&modified', 0)
  let g:simpleremote_event = {
        \ 'event': 'SimpleRemoteBufferRead', 'type': 'buffer-read',
        \ 'bufnr': a:buf, 'path': a:path, 'workspace': {},
        \ 'status': 'ssh:devbox', 'time': localtime()}
  doautocmd <nomodeline> User SimpleRemoteBufferRead
endfunction

runtime plugin/simpletreesitter.vim

call assert_true(exists('#TsHlAutoStart#User#SimpleRemoteBufferRead'),
      \ 'the plugin does not listen for User SimpleRemoteBufferRead')

" ---------------------------------------------------------------------------
" 1. The buftype gate: acwrite is a file, every other non-empty buftype is not.
" ---------------------------------------------------------------------------
enew
execute 'file remote:///work/src/main.rs'
call setline(1, ['pub fn main() {', '    let answer = 42;', '}'])
setlocal buftype=acwrite
let s:remote = bufnr()
" simpleremote sets 'buftype' before it runs `filetype detect`, so the FileType
" event -- the plugin's normal attach path -- fires on an acwrite buffer.
setfiletype rust
call assert_true(s:CallPrivate('IsSupportedLang', [s:remote]),
      \ 'a remote:// buffer (buftype acwrite) was rejected')
for s:bt in ['nofile', 'nowrite', 'prompt']
  execute 'setlocal buftype=' . s:bt
  call assert_false(s:CallPrivate('IsSupportedLang', [s:remote]),
        \ 'buftype ' . s:bt . ' must stay unsupported')
endfor
setlocal buftype=acwrite
call assert_true(s:CallPrivate('IsSupportedLang', [s:remote]))
let b:simpletreesitter_disable = 1
call assert_false(s:CallPrivate('IsSupportedLang', [s:remote]),
      \ 'b:simpletreesitter_disable must still opt an acwrite buffer out')
unlet b:simpletreesitter_disable
call assert_true(s:CallPrivate('IsSupportedLang', [s:remote]))

" The FileType event auto-enabled the plugin and the acwrite buffer went
" through the whole pipeline: text properties, Outline, folds, text objects.
call s:WaitFor({-> s:State().s_enabled}, 'rust did not auto-enable on an acwrite buffer')
call assert_true(get(s:State().s_active_bufs, s:remote, v:false),
      \ 'the acwrite buffer is not an active buffer')
call s:WaitFor({-> s:HasProps(s:remote, 1)},
      \ 'the acwrite buffer received no text properties')
for s:prop in prop_list(1, {'bufnr': s:remote})
  call assert_match('^SimpleTreeSitter_', get(s:prop, 'type', ''))
endfor

call simpletreesitter#OutlineOpen()
let s:outline = bufnr('ts-hl-outline')
call assert_true(s:outline > 0, 'outline buffer was not created for the acwrite buffer')
call s:WaitFor({-> join(getbufline(s:outline, 1, '$'), "\n") =~# 'main'},
      \ 'the Outline never listed the acwrite buffer symbols')
call assert_equal(s:remote, s:State().s_outline_src_buf)
call simpletreesitter#OutlineClose()
call assert_equal(1, winnr('$'), 'OutlineClose left a window behind')

" ---------------------------------------------------------------------------
" 2. Re-read of the *current* buffer.  The filetype is already set, so no
"    FileType fires, and TextChanged waits for the next keystroke; the event is
"    what gets the fresh text highlighted.
" ---------------------------------------------------------------------------
sleep 200m
call s:SimulateRemoteRead(s:remote, '/work/src/main.rs',
      \ ['pub fn reread() {', '    let fresh = String::new();', '    let again = 1;', '}'])
call assert_equal('acwrite', &buftype)
call s:WaitFor({-> s:HasProps(s:remote, 2) && s:HasProps(s:remote, 3)},
      \ 'the re-read text of the current remote buffer was not re-highlighted')

" ---------------------------------------------------------------------------
" 3. Read completing for a buffer shown in another window while the cursor
"    (and the Outline) are on a different buffer.  The background buffer is
"    resynced and re-highlighted; the Outline keeps following the cursor.
" ---------------------------------------------------------------------------
let s:remote_win = win_getid()
split
enew
call setline(1, ['pub fn beta() {', '    let b = 2;', '}'])
setfiletype rust
let s:local = bufnr()
let s:local_win = win_getid()
call assert_notequal(s:remote_win, s:local_win)
call simpletreesitter#OutlineOpen()
let s:outline = bufnr('ts-hl-outline')
call s:WaitFor({-> join(getbufline(s:outline, 1, '$'), "\n") =~# 'beta'},
      \ 'the Outline never listed the local buffer symbols')
call assert_equal(s:local_win, win_getid(), 'OutlineOpen moved the cursor')
call assert_equal(s:local, s:State().s_outline_src_buf)
call assert_equal(s:local_win, s:State().s_outline_src_win)
let g:simpletreesitter_breadcrumb = 1
call simpletreesitter#OnBufEvent(s:local)
call s:WaitFor({-> s:State().s_bc_items_buf == s:local},
      \ 'the breadcrumb never adopted the current buffer')
" Let the debounced requests behind that OnBufEvent drain before counting.
call s:WaitFor({-> s:State().s_sym_timer == 0
      \ && !get(s:State().s_inflight_syms, s:local, v:false)
      \ && !get(s:State().s_pending_syms, s:local, v:false)},
      \ 'symbols traffic for the local buffer never settled')
sleep 300m
let s:sym_requests_before = s:State().s_next_symbol_request_id
let s:remote_synced_before = get(s:State().s_sent_changedtick, s:remote, -1)

call s:SimulateRemoteRead(s:remote, '/work/src/main.rs',
      \ ['pub fn gamma() {', '    let g = 3;', '    let h = 4;', '}'])
call assert_equal(s:local, bufnr(), 'the event handler switched buffers')
call assert_equal(s:local_win, win_getid(), 'the event handler switched windows')
call s:WaitFor({-> s:HasProps(s:remote, 2) && s:HasProps(s:remote, 3)},
      \ 'the background remote buffer was not re-highlighted after its read')
call assert_true(get(s:State().s_active_bufs, s:remote, v:false),
      \ 'the background remote buffer is not an active buffer')
call assert_notequal(s:remote_synced_before, get(s:State().s_sent_changedtick, s:remote, -1),
      \ 'the background remote buffer was not resynced')
call assert_equal(s:local, s:State().s_outline_src_buf,
      \ 'a background read retargeted the Outline')
call assert_equal(s:local_win, s:State().s_outline_src_win,
      \ 'a background read retargeted the Outline source window')
call assert_match('beta', join(getbufline(s:outline, 1, '$'), "\n"),
      \ 'the Outline lost the current buffer symbols')
call assert_notmatch('gamma', join(getbufline(s:outline, 1, '$'), "\n"),
      \ 'the Outline shows the background buffer symbols')
call assert_equal(s:local, s:State().s_bc_buf,
      \ 'a background read retargeted the breadcrumb')
call assert_equal(s:local, s:State().s_bc_items_buf,
      \ 'the breadcrumb items were replaced by the background buffer')
call assert_equal(s:sym_requests_before, s:State().s_next_symbol_request_id,
      \ 'a background read issued a symbols request nobody consumes')

" ---------------------------------------------------------------------------
" 4. The same background read, but reached the way simpleremote really reaches
"    it.  A buffer that has not been read yet has no filetype, so
"    ApplyRemoteRead() calls DetectRemoteFiletype(), which for a non-current
"    buffer runs `win_execute(winid, 'filetype detect')`.  win_execute() makes
"    the background window -- and its buffer -- current for the duration, so
"    the FileType autocmd fires with bufnr('%') naming a buffer the cursor was
"    never in.  Nothing cursor-owned may follow it there.
" ---------------------------------------------------------------------------
call assert_equal(s:local_win, win_getid())
" :split remote://... in the background window, still empty and filetype-less:
" the state simpleremote leaves behind while the read is in flight.
call win_gotoid(s:remote_win)
enew
execute 'file remote:///work/src/delta.rs'
let s:fresh = bufnr()
let s:fresh_win = win_getid()
call win_gotoid(s:local_win)
call assert_equal(s:local, bufnr(), 'the cursor did not come back to the local buffer')
call assert_equal('', getbufvar(s:fresh, '&filetype'), 'the unread buffer already has a filetype')
" Entering an unsupported buffer legitimately blanks the Outline; wait until it
" is back on the cursor's buffer before measuring what the read does to it.
call s:WaitFor({-> s:State().s_outline_src_buf == s:local
      \ && join(getbufline(s:outline, 1, '$'), "\n") =~# 'beta'},
      \ 'the Outline did not return to the local buffer')
call s:WaitFor({-> s:State().s_bc_buf == s:local}, 'the breadcrumb did not return to the local buffer')
call simpletreesitter#OnScroll(s:local)
call s:WaitFor({-> simpletreesitter#Breadcrumb() =~# 'beta'},
      \ 'the local breadcrumb was never produced')

" ApplyRemoteRead(): the text and 'buftype' land on the background buffer,
" then `filetype detect` runs in its window, then the event is emitted.
call setbufline(s:fresh, 1, ['pub fn delta() {', '    let d = 4;', '    let e = 5;', '}'])
call setbufvar(s:fresh, '&buftype', 'acwrite')
call setbufvar(s:fresh, '&swapfile', 0)
call setbufvar(s:fresh, 'vimrc_remote',
      \ {'path': '/work/src/delta.rs', 'uri': 'remote:///work/src/delta.rs', 'generation': 1})
call setbufvar(s:fresh, '&modified', 0)
call win_execute(s:fresh_win, 'filetype detect')
call assert_equal('rust', getbufvar(s:fresh, '&filetype'),
      \ '`filetype detect` did not reach the background window')
let g:simpleremote_event = {
      \ 'event': 'SimpleRemoteBufferRead', 'type': 'buffer-read',
      \ 'bufnr': s:fresh, 'path': '/work/src/delta.rs', 'workspace': {},
      \ 'status': 'ssh:devbox', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteBufferRead

call assert_equal(s:local, bufnr(), 'the background detect switched buffers')
call assert_equal(s:local_win, win_getid(), 'the background detect switched windows')
call assert_equal(s:local, s:State().s_bc_buf,
      \ 'a `filetype detect` in a background window stole the breadcrumb')
call assert_equal(s:local, s:State().s_outline_src_buf,
      \ 'a `filetype detect` in a background window retargeted the Outline')
call assert_equal(s:local_win, s:State().s_outline_src_win,
      \ 'a `filetype detect` in a background window retargeted the Outline source window')
" The regression was only visible one CursorMoved later: UpdateBreadcrumb()
" drops the cache and blanks 'winbar' for a window whose buffer is no longer
" s_bc_buf, and nothing restores it until the next edit or BufEnter.
call simpletreesitter#OnScroll(s:local)
sleep 300m
call assert_equal(s:local, s:State().s_bc_buf, 'the breadcrumb did not stay on the cursor buffer')
call assert_match('beta', simpletreesitter#Breadcrumb(),
      \ 'a background `filetype detect` blanked the breadcrumb of the cursor window')
call assert_notmatch('delta', join(getbufline(s:outline, 1, '$'), "\n"),
      \ 'the Outline shows the background buffer symbols')
" The background buffer is still on screen, so it is synced and highlighted --
" that half of the contract must keep working.
call s:WaitFor({-> s:HasProps(s:fresh, 2) && s:HasProps(s:fresh, 3)},
      \ 'the freshly read background remote buffer was not highlighted')
call assert_true(get(s:State().s_active_bufs, s:fresh, v:false),
      \ 'the freshly read background remote buffer is not an active buffer')

" ---------------------------------------------------------------------------
" 5. The user-visible half of the same bug, with no Outline open to paper over
"    it.  Once s_bc_buf had followed the background detect, the very next
"    CursorMoved in the user's own window made UpdateBreadcrumb() drop the
"    cache and blank 'winbar' -- and with no Outline render to pull the state
"    back, it stayed blank until the next edit or BufEnter.
" ---------------------------------------------------------------------------
call simpletreesitter#OutlineClose()
call assert_equal(s:local_win, win_getid(), 'OutlineClose moved the cursor')
call win_gotoid(s:fresh_win)
enew
execute 'file remote:///work/src/epsilon.rs'
let s:fresh2 = bufnr()
let s:fresh2_win = win_getid()
call win_gotoid(s:local_win)
call s:WaitFor({-> s:State().s_bc_buf == s:local}, 'the breadcrumb did not return to the local buffer')
call simpletreesitter#OnScroll(s:local)
call s:WaitFor({-> simpletreesitter#Breadcrumb() =~# 'beta'},
      \ 'the local breadcrumb was never restored')
call setbufline(s:fresh2, 1, ['pub fn epsilon() {', '    let e = 5;', '    let f = 6;', '}'])
call setbufvar(s:fresh2, '&buftype', 'acwrite')
call setbufvar(s:fresh2, '&swapfile', 0)
call setbufvar(s:fresh2, '&modified', 0)
call win_execute(s:fresh2_win, 'filetype detect')
call assert_equal('rust', getbufvar(s:fresh2, '&filetype'))
let g:simpleremote_event = {
      \ 'event': 'SimpleRemoteBufferRead', 'type': 'buffer-read',
      \ 'bufnr': s:fresh2, 'path': '/work/src/epsilon.rs', 'workspace': {},
      \ 'status': 'ssh:devbox', 'time': localtime()}
doautocmd <nomodeline> User SimpleRemoteBufferRead
call assert_equal(s:local, s:State().s_bc_buf,
      \ 'a background `filetype detect` stole the breadcrumb with no Outline open')
" One cursor move in the user's own window is what used to blank the bar.
call simpletreesitter#OnScroll(s:local)
sleep 300m
call assert_match('beta', simpletreesitter#Breadcrumb(),
      \ 'a background `filetype detect` blanked the breadcrumb of the cursor window')
" ('winbar' itself is unavailable in this Vim build, so the cache the option's
" %{} expression reads is the observable: UpdateBreadcrumb() drops it and calls
" SetWinbar('') together.)
call s:WaitFor({-> s:HasProps(s:fresh2, 2)},
      \ 'the second freshly read background remote buffer was not highlighted')

let g:simpletreesitter_breadcrumb = 0

" ---------------------------------------------------------------------------
" 6. A hidden buffer is left to BufEnter, which resyncs by changedtick.  A
"    buffer nobody can see is not worth a highlight round trip.
" ---------------------------------------------------------------------------
call simpletreesitter#OutlineClose()
enew
execute 'file remote:///work/src/hidden.rs'
setlocal buftype=acwrite
setfiletype rust
let s:hidden = bufnr()
call setline(1, ['pub fn hidden() {', '    let z = 0;', '}'])
call simpletreesitter#OnBufEvent(s:hidden)
call s:WaitFor({-> s:HasProps(s:hidden, 1)}, 'the second remote buffer was never highlighted')
sleep 200m
execute 'buffer' s:local
call assert_true(empty(win_findbuf(s:hidden)), 'the hidden buffer is still displayed')
let s:hidden_synced_before = get(s:State().s_sent_changedtick, s:hidden, -1)
call s:SimulateRemoteRead(s:hidden, '/work/src/hidden.rs',
      \ ['pub fn hidden_again() {', '    let z = 1;', '    let y = 2;', '}'])
sleep 300m
call assert_equal(s:hidden_synced_before, get(s:State().s_sent_changedtick, s:hidden, -1),
      \ 'a hidden buffer was resynced by its read event')
call assert_false(s:HasProps(s:hidden, 3), 'a hidden buffer was highlighted by its read event')
" BufEnter is what runs OnBufEvent for the buffer; -es has no main loop to
" fire it, so call the same handler the autocmd calls.
execute 'buffer' s:hidden
call simpletreesitter#OnBufEvent(s:hidden)
call s:WaitFor({-> s:HasProps(s:hidden, 3)},
      \ 'entering the hidden remote buffer did not resync it')

" ---------------------------------------------------------------------------
" 7. Robustness: the handler swallows garbage and never reaches into the
"    emitter -- an unknown buffer, a non-numeric bufnr, a nofile buffer, and
"    a fire with no payload at all.
" ---------------------------------------------------------------------------
let v:errmsg = ''
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': 987654}
doautocmd <nomodeline> User SimpleRemoteBufferRead
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': 'oops'}
doautocmd <nomodeline> User SimpleRemoteBufferRead
unlet g:simpleremote_event
doautocmd <nomodeline> User SimpleRemoteBufferRead
new
setlocal buftype=nofile
setfiletype rust
let s:scratch = bufnr()
let g:simpleremote_event = {'event': 'SimpleRemoteBufferRead', 'bufnr': s:scratch}
doautocmd <nomodeline> User SimpleRemoteBufferRead
sleep 200m
call assert_equal('', v:errmsg, 'the read handler let an error escape')
call assert_false(has_key(s:State().s_sent_changedtick, s:scratch),
      \ 'a nofile buffer was synced because of the read event')
call assert_false(s:HasProps(s:scratch, 1), 'a nofile buffer was highlighted')
close

call delete(g:simpletreesitter_log_file)
call simpletreesitter#Disable()

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simpletreesitter-vim-remote-errors.log')
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
