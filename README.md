# TeXpresso.vim
Neovim mode for TeXpresso

Installation:
1. Install [TeXpresso](https://github.com/let-def/texpresso).
   If installation is successful, you should have `texpresso` binary in your PATH.
2. Clone [TeXpresso.vim](https://github.com/let-def/texpresso.vim.git), and make sure it is in Neovim runtime path.
   For instance:
   ```shell
   $ cd ~/.config/nvim
   $ mkdir start
   $ cd start
   $ git clone https://github.com/let-def/texpresso.vim.git
   ```

Usage:
1. Open a `.tex` file. Launch the viewer:
   `:TeXpresso <path/to/main.tex>`
2. The viewer should let you preview the `.tex` file.
   It should track your position in the buffer (when the cursor moves), and
   any change to the buffer should be reflected quickly in the preview window.

TODO:
- report errors/warnings in vim quickfix buffer
- allow customization: theme, cursor synchronizaiton, bindings, stay-on-top, ..
- simplify initialization, respect Neovim conventions, make code more robust
