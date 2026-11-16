#!/usr/bin/env python3
"""Real terminal/main-loop viewport regression against the real daemon.

WinScrolled is not emitted by :doautocmd or a sourced -es script. Drive actual
Normal-mode keys and allow Vim to return to its event loop between steps.
"""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parent.parent
VIM = os.environ.get('VIM_TEST_BIN') or shutil.which('vim')
DAEMON = ROOT / 'target/debug/ts-hl-daemon'
assert VIM and DAEMON.is_file(), 'build the daemon and provide full Vim first'

with tempfile.TemporaryDirectory(prefix='treesitter-scroll-') as tmp:
    tmp = Path(tmp)
    marker = tmp / 'done'
    output = tmp / 'state.json'
    setup = tmp / 'setup.vim'
    setup.write_text('''set nocompatible nomore hidden noswapfile
set shortmess+=I
set lines=24 columns=80
let g:simpletreesitter_auto_enable_filetypes = []
let g:simpletreesitter_view_margin = 0
let g:simpletreesitter_debounce = 20
let g:simpletreesitter_scroll_debounce = 20
let g:simpletreesitter_scope_prefetch = 0
let g:simpletreesitter_outline_fancy = 0
let g:scroll_events = 0
execute 'set runtimepath^=' . fnameescape(''' + repr(str(ROOT)) + ''')
let g:simpletreesitter_daemon_path = ''' + repr(str(DAEMON)) + '''
runtime plugin/simpletreesitter.vim
augroup ViewportTest
 autocmd!
 autocmd WinScrolled * let g:scroll_events += 1
augroup END
function! Snapshot(wid) abort
 let l:w = getwininfo(a:wid)[0]
 let l:s = getscriptinfo({'name': 'autoload/simpletreesitter.vim'})[0]
 let l:state = getscriptinfo({'sid': l:s.sid})[0].variables
 let l:props = prop_list(l:w.botline, {'bufnr': l:w.bufnr})
 return {'top': l:w.topline, 'bottom': l:w.botline, 'buf': l:w.bufnr,
       \\ 'range': get(l:state.s_last_ranges, l:w.bufnr, []),
       \\ 'props': len(filter(l:props, 'v:val.type =~# "^SimpleTreeSitter_"')),
       \\ 'cursor': getpos('.'), 'current': win_getid(),
       \\ 'anchor': l:state.s_cursor_win, 'events': g:scroll_events}
endfunction
''')
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    env = dict(os.environ, TERM='xterm-256color')
    proc = subprocess.Popen([VIM, '-Nu', 'NONE', '-n', '-i', 'NONE', '-S', str(setup)],
                            cwd=ROOT, env=env, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    transcript = bytearray()

    def pump(seconds=.01):
        if select.select([master], [], [], seconds)[0]:
            try:
                transcript.extend(os.read(master, 65536))
            except OSError:
                pass

    def command(text):
        marker.unlink(missing_ok=True)
        os.write(master, (':' + text + " | call writefile(['ok'], " + repr(str(marker)) + ")\r").encode())
        deadline = time.monotonic() + 10
        while not marker.exists():
            pump()
            assert proc.poll() is None and time.monotonic() < deadline, 'Vim command stalled: ' + text

    def snapshot(wid):
        command("call writefile([json_encode(Snapshot(" + str(wid) + "))], " + repr(str(output)) + ")")
        return json.loads(output.read_text())

    def highlighted(wid, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = snapshot(wid)
            if state['props'] > 0 and state['range'] and state['range'][1] >= state['bottom']:
                return state
            pump(.02)
        raise AssertionError('visible bottom never highlighted: ' + repr(state))

    try:
        command("call setline(1, repeat(['fn main() { let answer = 42; }'], 20000)) | setlocal filetype=rust | execute 'normal! 10000Gzz'")
        command('call simpletreesitter#Enable()')
        command("call writefile([string(win_getid())], " + repr(str(output)) + ")")
        current = int(output.read_text())
        before = highlighted(current)
        started = time.monotonic()
        os.write(master, b'zt')
        after = highlighted(current, 2)
        assert before['cursor'] == after['cursor'], 'fixture moved the cursor'
        assert after['top'] > before['top'] and after['events'] > before['events'], 'fixture did not scroll'
        print('20k-line current-window scroll ms:', round((time.monotonic() - started) * 1000, 1))

        # The default 120-line margin hides a small stationary-cursor scroll.
        # A tall terminal exposes the same bug without changing that default.
        command('let g:simpletreesitter_view_margin = 120')
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 320, 80, 0, 0))
        command("set lines=320 | execute 'normal! zz'")
        before = highlighted(current)
        os.write(master, b'zt')
        after = highlighted(current, 2)
        assert before['cursor'] == after['cursor'] and after['top'] > before['top']
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        command('set lines=24 | let g:simpletreesitter_view_margin = 0')
        highlighted(current)

        # Another buffer in a non-current split must receive its own refresh,
        # without taking ownership of the user's cursor/breadcrumb context.
        command("vnew | call setline(1, repeat(['fn other() { let answer = 7; }'], 20000)) | setlocal filetype=rust | execute 'normal! 2000Gzz'")
        command("call writefile([string(win_getid())], " + repr(str(output)) + ")")
        background = int(output.read_text())
        highlighted(background)
        command('call win_gotoid(' + str(current) + ')')
        before = snapshot(current)
        command("call win_execute(" + str(background) + ", 'normal! zt')")
        highlighted(background, 2)
        after = snapshot(current)
        assert (after['current'], after['anchor'], after['cursor']) == (before['current'], before['anchor'], before['cursor']), 'background scroll stole cursor context'
        highlighted(current)

        # Two windows on one buffer retain highlighting in both viewports.
        command('call win_gotoid(' + str(background) + ') | buffer ' + str(before['buf']) + " | execute 'normal! 10100Gzz'")
        highlighted(background)
        command('call win_gotoid(' + str(current) + ')')
        command("call win_execute(" + str(background) + ", 'normal! zt')")
        highlighted(background, 2)
        highlighted(current)
        print('PASS: stationary cursor, non-current buffer, shared-buffer splits')
        command('call simpletreesitter#Disable()')
        os.write(master, b':qa!\r')
        deadline = time.monotonic() + 5
        while proc.poll() is None and time.monotonic() < deadline:
            pump()
        assert proc.wait(timeout=1) == 0
    except Exception:
        (ROOT / 'tests/viewport-errors.log').write_bytes(transcript)
        raise
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)
