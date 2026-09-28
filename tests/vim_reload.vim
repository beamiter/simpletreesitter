vim9script

# Sourcing plugin/simpletreesitter.vim a second time must leave it working.
#
# A plugin manager sources plugin/ again when the vimrc is reloaded.  The script
# is guarded, so nothing is redefined -- but plain `vim9script` deletes every
# script-local function and variable before the guard reaches `finish`, and the
# commands, autocommands and g: functions defined the first time round go on
# referring to them.  Here that was E117 from the
# User SimpleRemoteBufferRead handler, and text-object mappings that could no
# longer be installed.
#
# Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_reload.vim

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
const SCRIPT = ROOT .. '/plugin/simpletreesitter.vim'
const ERRORS = '/tmp/simpletreesitter-vim-reload-errors.log'
execute 'set runtimepath^=' .. fnameescape(ROOT)
delete(ERRORS)

# What the script owns, as Vim sees it.
def ScriptItems(): dict<list<string>>
  for info in getscriptinfo()
    if resolve(fnamemodify(info.name, ':p')) ==# SCRIPT
      var detail = getscriptinfo({sid: info.sid})[0]
      return {
        functions: sort(copy(detail.functions)),
        variables: sort(keys(detail.variables)),
      }
    endif
  endfor
  return {functions: [], variables: []}
enddef

# No daemon is needed to check what the script keeps; nothing here opens a
# buffer that would start one.  The log is private all the same: the default
# path belongs to whatever Vim the developer happens to have open.
g:simpletreesitter_auto_enable_filetypes = []
g:simpletreesitter_log_file = tempname()
execute 'source ' .. fnameescape(SCRIPT)
var before = ScriptItems()
assert_true(!empty(before.functions),
  'the script defines no script-local function: this test checks nothing')

execute 'source ' .. fnameescape(SCRIPT)
assert_equal(before, ScriptItems(),
  'sourcing the script again deleted script-local items')

# The handler SimpleRemote's event is bound to is script-local.
assert_true(index(before.functions
  ->mapnew((_, name) => substitute(name, '^<SNR>\d\+_', '', '')),
  'OnRemoteBufferRead') >= 0, 'OnRemoteBufferRead is no longer script-local')
assert_true(exists('#TsHlAutoStart#User#SimpleRemoteBufferRead'),
  'the SimpleRemoteBufferRead autocommand is gone')

if !empty(v:errors)
  writefile(v:errors, ERRORS)
  cquit
endif
qa!
