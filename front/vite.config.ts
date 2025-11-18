import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'
import fs from 'fs'

// Plugin to serve markdown files from ../specs as /docs
function serveDocsPlugin() {
  const specsDir = path.resolve(__dirname, '../specs')

  return {
    name: 'serve-docs',
    configureServer(server: any) {
      server.middlewares.use((req: any, res: any, next: any) => {
        if (req.url?.startsWith('/docs/') && req.url.endsWith('.md')) {
          const filePath = path.join(specsDir, req.url.replace('/docs/', ''))

          if (fs.existsSync(filePath)) {
            const content = fs.readFileSync(filePath, 'utf-8')
            res.setHeader('Content-Type', 'text/markdown; charset=utf-8')
            res.end(content)
            return
          }
        }
        next()
      })
    },
    // For production build, copy specs to dist/docs
    closeBundle() {
      const distDocsDir = path.resolve(__dirname, 'dist/docs')
      if (!fs.existsSync(path.dirname(distDocsDir))) {
        return
      }

      // Copy specs directory to dist/docs
      const copyRecursive = (src: string, dest: string) => {
        if (!fs.existsSync(dest)) {
          fs.mkdirSync(dest, { recursive: true })
        }

        const entries = fs.readdirSync(src, { withFileTypes: true })
        for (const entry of entries) {
          const srcPath = path.join(src, entry.name)
          const destPath = path.join(dest, entry.name)

          if (entry.isDirectory()) {
            copyRecursive(srcPath, destPath)
          } else if (entry.name.endsWith('.md')) {
            fs.copyFileSync(srcPath, destPath)
          }
        }
      }

      copyRecursive(specsDir, distDocsDir)
    }
  }
}

export default defineConfig({
  plugins: [
    react(),
    serveDocsPlugin(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['fonts/*.woff2', 'legal/*.md'],
      manifest: {
        name: 'BTR DEX',
        short_name: 'BTR',
        description: 'Bonding AMM with Makima liquidity shaping',
        theme_color: '#14b8a6',
        background_color: '#0a201d',
        display: 'standalone',
        icons: [
          {
            src: '/icon-192.png',
            sizes: '192x192',
            type: 'image/png',
          },
          {
            src: '/icon-512.png',
            sizes: '512x512',
            type: 'image/png',
          },
        ],
      },
    }),
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
      '@components': path.resolve(__dirname, './src/components'),
      '@hooks': path.resolve(__dirname, './src/hooks'),
      '@lib': path.resolve(__dirname, './src/lib'),
      '@pages': path.resolve(__dirname, './src/pages'),
      '@styles': path.resolve(__dirname, './src/styles'),
      '@utils': path.resolve(__dirname, './src/utils'),
      '@constants': path.resolve(__dirname, './src/constants'),
    }
  },
  server: {
    port: 3000,
    strictPort: false,
    open: true,
    fs: {
      allow: ['..']
    }
  },
  build: {
    target: 'esnext',
    minify: 'esbuild',
    sourcemap: true
  }
})
