set nocompatible

filetype plugin indent on

" Basic editing defaults.
set tabstop=4
set shiftwidth=4
set expandtab
set autochdir
set number
set cursorline
set ai
set bs=2
set updatetime=100
set history=100
set ruler

" Makefiles use tabs.
au FileType make setlocal noexpandtab

" Search behavior.
set hlsearch
set incsearch
set ignorecase
syntax enable

" Fold markers.
set foldmethod=marker
set foldmarker={{{,}}}

" Theme: install vim-one to enable this colorscheme.
set background=dark
set termguicolors
silent! colorscheme one

" Optional cscope and tags support.
if has("cscope")
   set csprg=/usr/bin/cscope
   set csto=0
   set cst
   set nocsverb
   if !empty($CSCOPE_DB) && filereadable($CSCOPE_DB)
       cs add $CSCOPE_DB
   endif
   set csverb
endif
set tags=./tags;,tags

" Tag navigation.
map <C-Z> :tprev<CR>
map <C-X> :tnext<CR>

" Save and restore Vim sessions.
" Usage: :call SaveSess() or :call SaveSess('project-name')
function! SaveSess(...)
    let l:name = a:0 ? a:1 : 'default'
    call mkdir(expand('~/vim_sessions'), 'p')
    execute 'mksession! ' . fnameescape(expand('~/vim_sessions/' . l:name . '.vim'))
endfunction

" Statusline.
let s:hidden = 0
function! Togglelaststatus()
    if s:hidden == 0
        let s:hidden = 1
        set laststatus=0
    else
        let s:hidden = 0
        set laststatus=2
    endif
endfunction
nnoremap <S-h> :call Togglelaststatus()<CR>
set laststatus=2
set statusline=
set statusline+=%#LineNr#
set statusline+=%#PmenuSel#
set statusline+=\ %F
set statusline+=%m
set statusline+=%=
set statusline+=%#CursorColumn#
set statusline+=\ %y
set statusline+=%{GitStatus()}
set statusline+=\ %p%%
set statusline+=\ %l:%c
set statusline+=\ 

function! GitStatus()
    if exists('*GitGutterGetHunkSummary')
        let [l:add, l:modified, l:removed] = GitGutterGetHunkSummary()
        return printf(' +%d ~%d -%d ', l:add, l:modified, l:removed)
    endif
    return ''
endfunction

" Wildmenu and mouse support.
set wildmenu
set wildoptions=pum
set wildmode=longest:full,full
set mouse=a

" Open man pages in a split window.
runtime! ftplugin/man.vim

" Optional fzf Vim integration. Install fzf.vim (or ~/.fzf) to enable it.
if isdirectory(expand('~/.fzf'))
  set rtp+=~/.fzf
endif

if exists(':FZF') == 2
  if exists(':Files') == 2
    nnoremap <C-p> :FZF<CR>
    nnoremap <leader>f :Files<CR>
    nnoremap <leader>g :GFiles<CR>
    nnoremap <leader>w :Windows<CR>
  endif

  if exists('$TMUX')
    let g:fzf_layout = {'tmux': '90%,70%'}
  else
    let g:fzf_layout = {'window': {'width': 0.9, 'height': 0.6}}
  endif
  let g:fzf_action = {
    \ 'enter': 'tab split',
    \ 'ctrl-s': 'split',
    \ 'ctrl-v': 'vsplit',
    \ 'ctrl-e': 'edit'
    \ }
  let g:fzf_history_dir = '~/.local/share/fzf-history'

  function! s:build_quickfix_list(lines)
    call setqflist(map(copy(a:lines), '{ "filename": v:val, "lnum": 1 }'))
    copen
    cc
  endfunction
  let g:fzf_action['ctrl-q'] = function('s:build_quickfix_list')

  function! s:rg_handler(line)
    if empty(a:line)
      return
    endif
    let l:parts = split(a:line, ':')
    execute 'edit +' . l:parts[1] . ' ' . fnameescape(l:parts[0])
  endfunction

  let s:rg_opts = ['--delimiter=:', '--preview', 'fzf-preview.sh {1} {2}', '--no-sort']

  function! s:rg_fzf(pattern)
    let l:command = 'rg --line-number --color=never ' . shellescape(a:pattern)
    let l:previous = $FZF_DEFAULT_COMMAND
    try
      let $FZF_DEFAULT_COMMAND = l:command
      call fzf#run(fzf#wrap({
        \ 'options': s:rg_opts,
        \ 'sink': function('s:rg_handler')
        \ }))
    finally
      let $FZF_DEFAULT_COMMAND = l:previous
    endtry
  endfunction
  command! -nargs=* Rg call s:rg_fzf(<q-args>)
  nnoremap <leader>r :Rg<Space>
endif

" Plugin settings.
let g:taboo_tab_format = ' %I%f%m '
let g:taboo_renamed_tab_format = ' %I%l%m '
set sessionoptions+=tabpages,globals

let g:airline_extensions = ['tabline']
let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique'
let g:airline_powerline_fonts = 1
let g:airline_disable_statusline = 1
let g:airline#extensions#tabline#show_splits = 0
let g:airline#extensions#tabline#show_buffers = 0
let g:airline#extensions#tabline#show_tab_nr = 0
let g:airline#extensions#tabline#show_tab_type = 0
let g:airline#extensions#scrollbar#enabled = 1
let g:airline#extensions#taboo#enabled = 1
