set nocompatible
set nomore

" Option readers used to assume numbers/bools.  A vimrc string such as
" debounce='off' or folds='0' threw E1013 on the first timer, treated '0' as
" truthy, or compared max_buffer_bytes as the wrong type.

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' . fnameescape(s:root)
let g:simpletreesitter_auto_enable_filetypes = []
let g:simpletreesitter_log_file = tempname()
runtime plugin/simpletreesitter.vim
" Force autoload so script-locals exist without starting the daemon.
call simpletreesitter#Status()

function! s:Sid() abort
  return getscriptinfo({'name': 'autoload/simpletreesitter.vim'})[0].sid
endfunction

function! s:Call(name, ...) abort
  return call(function(printf('<SNR>%d_%s', s:Sid(), a:name)), get(a:, 1, []))
endfunction

let g:simpletreesitter_debounce = 'off'
call assert_equal(120, s:Call('ConfNumber', ['simpletreesitter_debounce', 120]),
      \ 'a string debounce must fall back instead of throwing')
unlet g:simpletreesitter_debounce

let g:simpletreesitter_scroll_debounce = 'fast'
call assert_equal(300, s:Call('ConfNumber', ['simpletreesitter_scroll_debounce', 300]))
unlet g:simpletreesitter_scroll_debounce

let g:simpletreesitter_scope_debounce = 'off'
call assert_equal(50, s:Call('ConfNumber', ['simpletreesitter_scope_debounce', 50]))
unlet g:simpletreesitter_scope_debounce

let g:simpletreesitter_folds = '0'
call assert_false(s:Call('FoldsEnabled'), 'folds=0 as a string must stay off')
let g:simpletreesitter_folds = 'on'
call assert_true(s:Call('FoldsEnabled'), 'folds=on must enable')
unlet g:simpletreesitter_folds

let g:simpletreesitter_indent_guides = '0'
call assert_false(s:Call('ConfFlag', ['simpletreesitter_indent_guides', 0]))
unlet g:simpletreesitter_indent_guides

let g:simpletreesitter_incremental_sync = 'off'
call assert_false(s:Call('ConfFlag', ['simpletreesitter_incremental_sync', 1]))
unlet g:simpletreesitter_incremental_sync

let g:simpletreesitter_rainbow_brackets = 'off'
call assert_false(s:Call('ConfFlag', ['simpletreesitter_rainbow_brackets', 1]))
unlet g:simpletreesitter_rainbow_brackets

let g:simpletreesitter_match_words = 'off'
call assert_false(s:Call('ConfFlag', ['simpletreesitter_match_words', 1]))
unlet g:simpletreesitter_match_words

let g:simpletreesitter_max_buffer_bytes = 'off'
enew
call assert_equal(5242880, s:Call('MaxBufferBytes', [bufnr('%')]),
      \ 'a string byte ceiling must fall back')
unlet g:simpletreesitter_max_buffer_bytes

let g:simpletreesitter_auto_enable_filetypes = 'rust'
call assert_equal(['rust'], s:Call('AutoEnableFiletypes'),
      \ 'a string auto-enable list must be treated as one filetype')
unlet g:simpletreesitter_auto_enable_filetypes
call simpletreesitter#Disable()

" :TsHlHealth used to claim the plugin still speaks protocol v6.
call s:Call('OnDaemonEvent', [{'type': 'hello', 'protocol_version': 7}])
let s:health = execute('call simpletreesitter#Health()')
call assert_true(s:health =~# 'plugin speaks v7',
      \ 'Health still advertised v6: ' .. s:health)
call assert_true(s:health =~# '\[OK\] protocol: v7',
      \ 'protocol v7 must be OK: ' .. s:health)

call s:Call('OnDaemonEvent', [{'type': 'hello', 'protocol_version': 6}])
call assert_true(execute('messages') =~# 'daemon protocol is v6',
      \ 'a v6 hello must still warn that install.sh is needed')

if len(v:errors) > 0
  call writefile(v:errors, '/tmp/simpletreesitter-vim-options-errors.log')
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
