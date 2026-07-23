return {
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPost", "BufNewFile" },
  keys = {
    { "<leader>gp", "<cmd>Gitsigns preview_hunk<cr>", desc = "Preview hunk" },
    { "<leader>gu", "<cmd>Gitsigns reset_hunk<cr>", desc = "Reset hunk" },
    { "<leader>gU", "<cmd>Gitsigns reset_buffer<cr>", desc = "Reset buffer" },
    { "<leader>gn", "<cmd>Gitsigns next_hunk<cr>", desc = "Next hunk" },
    { "<leader>gN", "<cmd>Gitsigns prev_hunk<cr>", desc = "Previous hunk" },
  },
  config = function()
    require("gitsigns").setup({
      signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "-" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
    })
  end,
}
