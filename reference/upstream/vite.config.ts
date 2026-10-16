import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

// The package is ESM, so `__dirname` does not exist here.
const root = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [react(), tailwindcss()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
  build: {
    // WebView2 tracks Chromium, so there is no need to transpile down.
    target: "chrome110",
    sourcemap: false,
    rollupOptions: {
      input: {
        main: resolve(root, "index.html"),
        widget: resolve(root, "widget.html"),
      },
    },
  },
  resolve: {
    alias: { "@": resolve(root, "src") },
  },
});
