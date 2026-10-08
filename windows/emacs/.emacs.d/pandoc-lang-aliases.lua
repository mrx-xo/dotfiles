-- pandoc Lua filter for markdown-mode previews (markdown-command in init.el).
-- Fence languages agents and READMEs use that pandoc's highlighter does not
-- know, mapped onto the nearest grammar it does, so the code blocks in the
-- browser preview get token classes (and so gruvbox colours) instead of
-- falling back to plain text.
local aliases = {
  elisp = "commonlisp", ["emacs-lisp"] = "commonlisp", lisp = "commonlisp",
  sh = "bash", shell = "bash", console = "bash", fish = "bash",
  ps1 = "powershell", pwsh = "powershell",
  jsonc = "json", yml = "yaml", kbd = "scheme",
}

function CodeBlock(el)
  local lang = el.classes[1]
  if lang and aliases[lang] then
    el.classes[1] = aliases[lang]
  end
  return el
end
