return {
  "tpope/vim-fugitive",
  cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Gwrite", "Gread", "Ggrep" },
  keys = {
    {
      "<leader>gd",
      function()
        require("config.git_diff").open()
      end,
      desc = "Open Git diff panel",
    },
  },
}
