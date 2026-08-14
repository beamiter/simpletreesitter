" SimpleTreeSitter Haskell indentation
" Maintainer: beamiter

if exists('b:did_indent')
  finish
endif
let b:did_indent = 1

setlocal autoindent
setlocal indentexpr=GetSimpleTreeSitterHaskellIndent()
setlocal indentkeys=!^F,o,O,0],0),0},0=where,0=in\ ,0=then,0=else,0=deriving,0=|
setlocal nosmartindent
let b:undo_indent = 'setlocal autoindent< indentexpr< indentkeys< smartindent<'

if exists('*GetSimpleTreeSitterHaskellIndent')
  finish
endif

function! s:Code(line) abort
  " Haskell line comments require whitespace after -- in the common case.
  " This deliberately stays conservative so operators such as --> survive.
  return substitute(a:line, '\s--\s.*$', '', '')
endfunction

function! s:PreviousCodeLine(lnum) abort
  let l:lnum = prevnonblank(a:lnum)
  while l:lnum > 0 && s:Code(getline(l:lnum)) =~# '^\s*$'
    let l:lnum = prevnonblank(l:lnum - 1)
  endwhile
  return l:lnum
endfunction

function! s:AnchorFor(lnum, pattern) abort
  let l:lnum = a:lnum
  while l:lnum > 0
    let l:text = s:Code(getline(l:lnum))
    if l:text =~# a:pattern
      return indent(l:lnum)
    endif
    if indent(l:lnum) == 0 && l:lnum != a:lnum
      break
    endif
    let l:lnum = s:PreviousCodeLine(l:lnum - 1)
  endwhile
  return -1
endfunction

function! GetSimpleTreeSitterHaskellIndent() abort
  let l:prev = s:PreviousCodeLine(v:lnum - 1)
  if l:prev == 0
    return 0
  endif

  let l:current = getline(v:lnum)
  let l:previous = s:Code(getline(l:prev))
  let l:base = indent(l:prev)
  let l:sw = shiftwidth() > 0 ? shiftwidth() : &tabstop

  " Closing delimiters align with their opener. searchpairpos() ignores nested
  " pairs and gives useful behaviour even before syntax highlighting is ready.
  if l:current =~# '^\s*[])}]'
    let l:close = matchstr(l:current, '^\s*\zs[])}]')
    let l:open = l:close ==# ']' ? '\[' : (l:close ==# ')' ? '(' : '{')
    let l:save = getpos('.')
    call cursor(v:lnum, match(l:current, '[])}]') + 1)
    let l:pos = searchpairpos(l:open, '', '\V' . l:close, 'bnW')
    call setpos('.', l:save)
    if !empty(l:pos) && l:pos[0] > 0
      return indent(l:pos[0])
    endif
  endif

  " `else`, `then`, `in`, `where` and case alternatives close one layout
  " level.  Look for a nearby construct first; otherwise a single shift is a
  " predictable fallback for incomplete code.
  if l:current =~# '^\s*\%(then\|else\|in\|where\|deriving\)\>'
    let l:anchor = s:AnchorFor(l:prev,
          \ '\<\%(if\|let\|where\|data\|newtype\|class\|instance\)\>')
    return l:anchor >= 0 ? l:anchor : max([0, l:base - l:sw])
  endif

  " Sibling guards/case alternatives line up with the previous one.
  if l:current =~# '^\s*|'
    let l:guard = s:AnchorFor(l:prev, '^\s*|')
    return l:guard >= 0 ? l:guard : l:base + l:sw
  endif
  if l:current =~# '^\s*\S.\{-}\s->'
    let l:arm = s:AnchorFor(l:prev, '^\s*\S.\{-}\s->')
    return l:arm >= 0 ? l:arm : l:base
  endif

  " Layout-introducing forms and an unfinished binding/operator continuation.
  if l:previous =~# '\<\%(where\|let\|do\|of\|then\|else\)\>\s*$'
        \ || l:previous =~# '\%(=\|->\|<-\|[!#$%&*+./<>?@\\^|~-]\)\s*$'
        \ || l:previous =~# '[([{]\s*$'
    return l:base + l:sw
  endif

  " Continue comma-separated records/lists at their current layout column.
  if l:previous =~# ',\s*$'
    return l:base
  endif

  return l:base
endfunction
