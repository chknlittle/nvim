return {
  "bfrg/vim-cuda-syntax",
  ft = { "cuda", "ptx" },
  init = function()
    vim.filetype.add({
      extension = {
        ptx = "ptx",
      },
    })
  end,
}
