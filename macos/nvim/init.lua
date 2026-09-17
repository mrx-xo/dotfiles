-- ╔══════════════════════════════════════════════════════════╗
-- ║  Minimal nvim config — vanilla first, plugins later     ║
-- ╚══════════════════════════════════════════════════════════╝
--
-- UPGRADE PATH — when vanilla gets annoying, add these:
--
--   telescope.nvim     fuzzy file finder + live grep (ivy/counsel equivalent)
--   oil.nvim           edit directories like buffers, way nicer than :Explore
--   treesitter grammars auto-install parsers for yaml/json/toml/dockerfile/lua/bash
--   lualine.nvim       statusline that doesn't look like 2003
--   a colorscheme      catppuccin, tokyonight, kanagawa, gruvbox-material
--
-- All of the above would go through lazy.nvim (package manager).
-- Total: ~100 extra lines. Do it when you're ready.

-- ── Leader ─────────────────────────────────────────────────
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- ── Bootstrap lazy.nvim ──────────────────────────────────
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

-- ── Options ────────────────────────────────────────────────
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true

vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.smartindent = true

vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.hlsearch = true
vim.opt.incsearch = true

vim.opt.splitright = true
vim.opt.splitbelow = true

vim.opt.clipboard = "unnamedplus"
vim.opt.undofile = true
vim.opt.swapfile = false

vim.opt.scrolloff = 8
vim.opt.termguicolors = true
vim.opt.updatetime = 250
vim.opt.timeoutlen = 400

-- ── Keymaps ────────────────────────────────────────────────
-- clear search highlight
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")

-- better window navigation
vim.keymap.set("n", "<C-h>", "<C-w>h")
vim.keymap.set("n", "<C-j>", "<C-w>j")
vim.keymap.set("n", "<C-k>", "<C-w>k")
vim.keymap.set("n", "<C-l>", "<C-w>l")

-- move lines up/down in visual mode
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv")
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv")

-- keep cursor centered when scrolling
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")

-- file explorer
vim.keymap.set("n", "<leader>e", vim.cmd.Ex)

-- buffers
vim.keymap.set("n", "<leader>bn", "<cmd>bnext<CR>")
vim.keymap.set("n", "<leader>bp", "<cmd>bprevious<CR>")
vim.keymap.set("n", "<leader>bd", "<cmd>bdelete<CR>")



-- ── Plugins ──────────────────────────────────────────────
require("lazy").setup({
  -- your plugins go here as tables, e.g.:
   { "coder/claudecode.nvim", dependencies = { "folke/snacks.nvim" }, config = true },
   {
     "nvim-orgmode/orgmode",
     event = "VeryLazy",
     ft = { "org" },
     config = function()
       require("orgmode").setup({
        org_agenda_files = "",
        org_default_notes_file = "~/roaming/notes/refile.org",
      })
    end,

   },
})
