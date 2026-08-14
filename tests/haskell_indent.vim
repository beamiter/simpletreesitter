set nocompatible
set nomore

let s:root = getcwd()
execute 'set runtimepath^=' . fnameescape(s:root)
filetype indent on

new
setlocal shiftwidth=2 tabstop=8 expandtab
setfiletype haskell
call assert_equal('GetSimpleTreeSitterHaskellIndent()', &l:indentexpr,
      \ 'SimpleTreeSitter Haskell indent was not selected')

call setline(1, ['main = do', 'putStrLn "hello"', 'if ready', 'then run', 'else stop'])
normal! gg=G
call assert_equal(['main = do', '  putStrLn "hello"', '  if ready',
      \ '  then run', '  else stop'], getline(1, '$'),
      \ 'do/if layout indentation regressed')

silent %delete _
call setline(1, ['describe value =', '| value > 0 = "positive"',
      \ '| otherwise = "zero"'])
normal! gg=G
call assert_equal(['describe value =', '  | value > 0 = "positive"',
      \ '  | otherwise = "zero"'], getline(1, '$'),
      \ 'guard alignment regressed')

if !empty(v:errors)
  call writefile(v:errors, '/tmp/simpletreesitter-haskell-indent-errors.log')
  cquit
endif
qa!
