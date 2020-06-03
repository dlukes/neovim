" The Python provider helper
if exists('s:loaded_pythonx_provider')
  finish
endif

let s:loaded_pythonx_provider = 1
let s:min_python2_version = '2.6'
let s:min_python3_version = '3.3'

function! provider#pythonx#Require(host) abort
  let ver = (a:host.orig_name ==# 'python') ? 2 : 3

  " Python host arguments
  let prog = (ver == '2' ?  provider#python#Prog() : provider#python3#Prog())
  let args = [prog, '-c', 'import sys; sys.path = list(filter(lambda x: x != "", sys.path)); import neovim; neovim.start_host()']


  " Collect registered Python plugins into args
  let python_plugins = remote#host#PluginsForHost(a:host.name)
  for plugin in python_plugins
    call add(args, plugin.path)
  endfor

  return provider#Poll(args, a:host.orig_name, '$NVIM_PYTHON_LOG_FILE')
endfunction

function! s:get_python_executable_from_host_var(major_version) abort
  return expand(get(g:, 'python'.(a:major_version == 3 ? '3' : '').'_host_prog', ''))
endfunction

" TODO: :help globpath() warns that , in path elements needs to be escaped,
" which in turn can lead to problems with trailing backslashes in on Windows
" TODO: a unit test?
" echo To_comma_separated_path('foo,bar\\\;baz\qux\;floob')
function! s:to_comma_separated_path(path) abort
  if has('win32')
    let path_sep = ';'
    " remove backslashes at the end of path items, they would turn into \, and
    " escape the , which globpath() expects as path separator
    let path = substitute(a:path, '\\\+;', ';', 'g')
  else
    let path_sep = ':'
    let path = a:path
  endif

  " escape existing commas, so that they remain part of the individual paths
  let path = substitute(path, ',', '\\,', 'g')

  " deduplicate path items, otherwise globpath() returns even more duplicate
  " matches for some reason
  let already_seen = {}
  let path_list = []
  for item in split(path, path_sep)
    if !has_key(already_seen, item)
      let already_seen[item] = v:true
      call add(path_list, item)
    endif
  endfor

  return join(path_list, ',')
endfunction

" A list of hardcoded versions is useless, min_versions are already specified
" below, this only amounts to maintainer burden as it needs to be updated each
" time a new Python version is released. Return all appropriate python*
" executables on PATH instead. Also, promote this to a public function, so
" that the health checks can use it to retrieve info about all potential
" Python executables available for a given version.
"
" Returns a list of all Python executables found in path.
"
" Takes two optional arguments: a Python major version, and a path as a
" comma-separated string of directories.
"
" If the major version is given, only executables for that version will be
" returned. If no path is given, a deduplicated $PATH will by used by default.
function! provider#pythonx#GetPythonCandidates(...) abort
  let major_version = get(a:, 1, '.')
  let path = get(a:, 2, s:to_comma_separated_path($PATH))
  let starts_with_python = globpath(path, 'python*', v:true, v:true)
  let ext_pat = has('win32') ? '(\\.exe)?' : ''
  let matches_version = printf('v:val =~# "\\v[\\/]python(%s)?(\\.[0-9]+)?%s$"', major_version, ext_pat)
  return filter(starts_with_python, matches_version)
endfunction

" Returns [path_to_python_executable, error_message]
function! provider#pythonx#Detect(major_version) abort
  return provider#pythonx#DetectByModule('neovim', a:major_version)
endfunction

" Returns [path_to_python_executable, error_message]
function! provider#pythonx#DetectByModule(module, major_version) abort
  let python_exe = s:get_python_executable_from_host_var(a:major_version)

  if !empty(python_exe)
    return [exepath(expand(python_exe)), '']
  endif

  let candidates = provider#pythonx#GetPythonCandidates(a:major_version)
  let errors = []

  if empty(candidates)
    call add(errors, 'No candidates for a Python '.a:major_version.' executable found on $PATH.')
  endif

  for exe in candidates
    let [result, error] = provider#pythonx#CheckForModule(exe, a:module, a:major_version)
    if result
      return [exe, error]
    endif
    " Accumulate errors in case we don't find any suitable Python executable.
    call add(errors, error)
  endfor

  " No suitable Python executable found.
  return ['', 'provider/pythonx: Could not load Python '.a:major_version.":\n".join(errors, "\n")]
endfunction

" Returns array: [prog_exitcode, prog_version]
function! s:import_module(prog, module) abort
  let prog_version = system([a:prog, '-c' , printf(
        \ 'import sys; ' .
        \ 'sys.path = list(filter(lambda x: x != "", sys.path)); ' .
        \ 'sys.stdout.write(".".join(str(n) for n in sys.version_info[:2])); ' .
        \ 'import pkgutil; ' .
        \ 'sys.exit(2*int(pkgutil.get_loader("%s") is None))',
        \ a:module)])
  return [v:shell_error, prog_version]
endfunction

" Returns array: [was_success, error_message]
function! provider#pythonx#CheckForModule(prog, module, major_version) abort
  let prog_path = exepath(a:prog)
  " TODO: not necessary if candidates are only existing executables
  " if prog_path ==# ''
  "   return [0, a:prog . ' not found in search path or not executable.']
  " endif

  let min_version = (a:major_version == 2) ? s:min_python2_version : s:min_python3_version

  " Try to load module, and output Python version.
  " Exit codes:
  "   0  module can be loaded.
  "   2  module cannot be loaded.
  "   Otherwise something else went wrong (e.g. 1 or 127).
  let [prog_exitcode, prog_version] = s:import_module(a:prog, a:module)

  if prog_exitcode == 2 || prog_exitcode == 0
    " Check version only for expected return codes.
    if prog_version !~ '^' . a:major_version
      return [0, prog_path . ' is Python ' . prog_version . ' and cannot provide Python '
            \ . a:major_version . '.']
    elseif prog_version =~ '^' . a:major_version && prog_version < min_version
      return [0, prog_path . ' is Python ' . prog_version . ' and cannot provide Python >= '
            \ . min_version . '.']
    endif
  endif

  if prog_exitcode == 2
    return [0, prog_path.' does not have the "' . a:module . '" module. :help provider-python']
  elseif prog_exitcode == 127
    " NOTE: I wouldn't treat this specially, I don't think it's Neovim's job
    " to try and help users with pyenv. Just show the command we ran, the exit
    " code and the output we got, and let them figure it out.
    " This can happen with pyenv's shims.
    return [0, prog_path . ' is probably a dangling pyenv shim: ' . prog_version]
  elseif prog_exitcode
    " NOTE: Why report? An "unknown error" can happen e.g. if there's an
    " executable named python on the PATH which is not actually Python. That's
    " the user's problem, not Neovim's.
    return [0, 'Checking ' . prog_path . ' caused an unknown error. '
          \ . '(' . prog_exitcode . ', output: ' . prog_version . ')'
          \ . ' Report this at https://github.com/neovim/neovim']
  endif

  return [1, '']
endfunction
