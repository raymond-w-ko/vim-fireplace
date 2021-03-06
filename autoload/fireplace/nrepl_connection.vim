" Location:     autoload/nrepl/fireplace_connection.vim

if exists("g:autoloaded_nrepl_fireplace_connection") || &cp
  finish
endif
let g:autoloaded_nrepl_fireplace_connection = 1

let s:python_dir = fnamemodify(expand("<sfile>"), ':p:h:h:h') . '/python'

function! s:function(name) abort
  return function(substitute(a:name,'^s:',matchstr(expand('<sfile>'), '.*\zs<SNR>\d\+_'),''))
endfunction

" Bencode {{{1

function! fireplace#nrepl_connection#bencode(value) abort
  if type(a:value) == type(0)
    return 'i'.a:value.'e'
  elseif type(a:value) == type('')
    return strlen(a:value).':'.a:value
  elseif type(a:value) == type([])
    return 'l'.join(map(copy(a:value),'fireplace#nrepl_connection#bencode(v:val)'),'').'e'
  elseif type(a:value) == type({})
    return 'd'.join(map(
          \ sort(keys(a:value)),
          \ 'fireplace#nrepl_connection#bencode(v:val) . ' .
          \ 'fireplace#nrepl_connection#bencode(a:value[v:val])'
          \ ),'').'e'
  else
    throw "Can't bencode ".string(a:value)
  endif
endfunction

" }}}1

function! s:shellesc(arg) abort
  if a:arg =~ '^[A-Za-z0-9_/.-]\+$'
    return a:arg
  elseif &shell =~# 'cmd'
    throw 'Python interface not working. See :help python-dynamic'
  else
    let escaped = shellescape(a:arg)
    if &shell =~# 'sh' && &shell !~# 'csh'
      return substitute(escaped, '\\\n', '\n', 'g')
    else
      return escaped
    endif
  endif
endfunction

if !exists('s:id')
  let s:vim_id = localtime()
  let s:id = 0
endif
function! s:id() abort
  let s:id += 1
  return 'fireplace-'.hostname().'-'.s:vim_id.'-'.s:id
endfunction

function! fireplace#nrepl_connection#prompt() abort
  return fireplace#input_host_port()
endfunction

function! fireplace#nrepl_connection#open(arg) abort
  if a:arg =~# '^\d\+$'
    let host = 'localhost'
    let port = a:arg
  elseif a:arg =~# ':\d\+$'
    let host = matchstr(a:arg, '.*\ze:')
    let port = matchstr(a:arg, ':\zs.*')
  else
    throw "nREPL: Couldn't find [host:]port in " . a:arg
  endif
  let transport = deepcopy(s:nrepl_transport)
  let transport.host = host
  let transport.port = port
  return fireplace#nrepl#for(transport)
endfunction

function! s:nrepl_transport_close() dict abort
  return self
endfunction

let s:keepalive = tempname()
call writefile([getpid()], s:keepalive)

function! s:nrepl_transport_command(cmd, args) dict abort
  return g:fireplace#_pyexe
        \ . ' ' . s:shellesc(s:python_dir.'/nrepl_fireplace.py')
        \ . ' ' . s:shellesc(self.host)
        \ . ' ' . s:shellesc(self.port)
        \ . ' ' . s:shellesc(s:keepalive)
        \ . ' ' . s:shellesc(a:cmd)
        \ . ' ' . join(map(copy(a:args), 's:shellesc(fireplace#nrepl_connection#bencode(v:val))'), ' ')
endfunction

function! s:nrepl_transport_dispatch(cmd, ...) dict abort
  let in = self.command(a:cmd, a:000)
  let out = system(in)
  if !v:shell_error
    return eval(out)
  endif
  throw 'nREPL: '.out
endfunction

function! s:nrepl_transport_call(msg, terms, sels, ...) dict abort
  let payload = fireplace#nrepl_connection#bencode(a:msg)

  if a:0 && a:1 ==# 'ignore'
    call self.dispatch('send', payload)
    return
  endif

  let response = self.dispatch('call', payload, a:terms, a:sels)
  if !a:0
    return response
  else
    return map(response, 'fireplace#nrepl#callback(v:val, "synchronous", a:000)')
  endif
endfunction

let s:nrepl_transport = {
      \ 'close': s:function('s:nrepl_transport_close'),
      \ 'command': s:function('s:nrepl_transport_command'),
      \ 'dispatch': s:function('s:nrepl_transport_dispatch'),
      \ 'call': s:function('s:nrepl_transport_call')}

if !has(g:fireplace#_py) || $FIREPLACE_NO_IF_PYTHON
  finish
endif

if !exists('s:loaded_plugin_python_scripts')
  exe g:fireplace#_py . ' sys.path.insert(0, "'.escape(s:python_dir, '\"').'")'
  let s:loaded_plugin_python_scripts = 1
  exe g:fireplace#_py . " import nrepl_fireplace"
else
  exe g:fireplace#_py . " reload(nrepl_fireplace)"
endif

exe fireplace#_pyfile . " " . escape(s:python_dir, '\"') ."/nrepl_fireplace_loader.py"

function! s:nrepl_transport_dispatch(command, ...) dict abort
  exe g:fireplace#_py . " fireplace_repl_dispatch(vim.eval('a:command'), *vim.eval('a:000'))"
  if !exists('err')
    return out
  endif
  throw 'nREPL Connection Error: '.err
endfunction
