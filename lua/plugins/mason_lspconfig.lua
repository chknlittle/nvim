return {
  "williamboman/mason-lspconfig.nvim",
  dependencies = { "williamboman/mason.nvim", "neovim/nvim-lspconfig" },
  event = { "BufReadPost", "BufNewFile" },
  opts = {
    ensure_installed = { "ts_ls", "rust_analyzer", "pyright" },
  },
}
