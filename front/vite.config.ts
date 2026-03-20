import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import { VitePWA } from 'vite-plugin-pwa'
import { visualizer } from 'rollup-plugin-visualizer'
import path from 'path'
import fs from 'fs'
import { execSync } from 'child_process'
import { logger } from '../sdk/src/utils/logger'

const log = logger.withContext('vite')

// Plugin to watch docs and rebuild search index + compiled markdown on change
function watchDocsPlugin() {
  const docsDir = path.resolve(__dirname, '../docs')
  let debounceTimer: ReturnType<typeof setTimeout> | null = null

  const rebuildAssets = () => {
    if (debounceTimer) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      try {
        log.info('\nDocs changed, rebuilding assets...')
        execSync('bun run build:search-index && bun run build:markdown', { cwd: __dirname, stdio: 'inherit' })
      } catch (err) {
        log.error('Failed to rebuild docs assets:', err)
      }
    }, 500)
  }

  return {
    name: 'watch-docs',
    configureServer(server: any) {
      // Watch the docs directory for changes
      server.watcher.add(docsDir)

      server.watcher.on('change', (filePath: string) => {
        if (filePath.startsWith(docsDir) && filePath.endsWith('.md')) {
          rebuildAssets()
        }
      })

      server.watcher.on('add', (filePath: string) => {
        if (filePath.startsWith(docsDir) && filePath.endsWith('.md')) {
          rebuildAssets()
        }
      })

      server.watcher.on('unlink', (filePath: string) => {
        if (filePath.startsWith(docsDir) && filePath.endsWith('.md')) {
          rebuildAssets()
        }
      })
    },
    // Build search index and compiled markdown on server start
    buildStart() {
      if (process.env.SKIP_PREBUILD === '1') {
        log.info('Skipping docs assets build (SKIP_PREBUILD=1)')
        return
      }
      try {
        execSync('bun run build:search-index && bun run build:markdown', { cwd: __dirname, stdio: 'inherit' })
      } catch (err) {
        log.warn('Failed to build docs assets on start:', err)
      }
    }
  }
}

// Plugin to serve markdown files from ../docs as /docs
function serveDocsPlugin() {
  const docsDir = path.resolve(__dirname, '../docs')

  return {
    name: 'serve-docs',
    configureServer(server: any) {
      server.middlewares.use((req: any, res: any, next: any) => {
        const decodedUrl = decodeURIComponent(req.url || '')

        // Serve markdown docs
        if (decodedUrl.startsWith('/docs/') && decodedUrl.endsWith('.md')) {
          // Extract slug and convert to filename: "2.1-BTR-Token" -> "2.1. BTR Token"
          const slug = decodedUrl.replace('/docs/', '').replace(/\.md$/, '');
          const targetFileName = slug
            .replace(/(\d)-/g, '$1. ')  // "2.1-" -> "2.1. "
            .replace(/-/g, ' ') + '.md';

          // Search recursively for file with matching name
          const findFile = (dir: string): string | null => {
            const items = fs.readdirSync(dir);
            for (const item of items) {
              const fullPath = path.join(dir, item);
              const stat = fs.statSync(fullPath);
              if (stat.isDirectory()) {
                const found = findFile(fullPath);
                if (found) return found;
              } else if (item === targetFileName) {
                return fullPath;
              }
            }
            return null;
          };

          const filePath = findFile(docsDir);
          if (filePath) {
            const content = fs.readFileSync(filePath, 'utf-8')
            res.setHeader('Content-Type', 'text/markdown; charset=utf-8')
            res.end(content)
            return
          } else {
            // Return 404 for nonexistent docs
            res.statusCode = 404
            res.setHeader('Content-Type', 'text/plain')
            res.end('Document not found')
            return
          }
        }
        next()
      })
    },
    // For production build, copy specs to dist/docs
    closeBundle() {
      const distDocsDir = path.resolve(__dirname, 'dist/docs')
      const compiledDocsDir = path.resolve(__dirname, 'public/compiled-docs')
      const distCompiledDocsDir = path.resolve(__dirname, 'dist/compiled-docs')
      const distDir = path.resolve(__dirname, 'dist')

      if (!fs.existsSync(path.dirname(distDocsDir))) {
        return
      }

      // Skip copying raw markdown files - they're already compiled to dist/compiled-docs

      // Copy pre-compiled docs to dist
      if (fs.existsSync(compiledDocsDir)) {
        if (!fs.existsSync(distCompiledDocsDir)) {
          fs.mkdirSync(distCompiledDocsDir, { recursive: true })
        }
        const compiledFiles = fs.readdirSync(compiledDocsDir)
        compiledFiles.forEach(file => {
          fs.copyFileSync(
            path.join(compiledDocsDir, file),
            path.join(distCompiledDocsDir, file)
          )
        })
      }

      // Remove search-index and docs-structure from dist root (they belong in compiled-docs)
      const filesToRemove = ['search-index.json', 'search-index.json.gz', 'docs-structure.json', 'docs-structure.json.gz']
      filesToRemove.forEach(file => {
        const filePath = path.join(distDir, file)
        if (fs.existsSync(filePath)) {
          fs.unlinkSync(filePath)
        }
      })
    }
  }
}

export default defineConfig({
  optimizeDeps: {
    include: [
      'preact',
      'preact/hooks',
      'preact/jsx-runtime',
      'preact/jsx-dev-runtime',
      '@preact/signals',
      'chartist',
      // Include noble/hashes subpaths for @noble/curves compatibility
      '@noble/hashes/sha2',
      '@noble/hashes/utils',
      '@noble/hashes/hmac',
      '@noble/hashes/sha3',
      '@noble/curves/secp256k1',
    ],
  },
  plugins: [
    preact(),
    watchDocsPlugin(),
    serveDocsPlugin(),
    visualizer({
      open: false,
      gzipSize: true,
      brotliSize: true,
      filename: 'dist/stats.html',
      template: 'treemap',
    }),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['fonts/*.woff2', 'legal/*.md'],
      workbox: {
        maximumFileSizeToCacheInBytes: 5 * 1024 * 1024, // 5 MB
      },
      manifest: {
        name: 'BTR DEX',
        short_name: 'BTR',
        description: 'Adaptive Inventory Maker Market (AIMM) AMM',
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
      '@config': path.resolve(__dirname, './src/config'),
      '@hooks': path.resolve(__dirname, './src/hooks'),
      '@lib': path.resolve(__dirname, './src/lib'),
      '@pages': path.resolve(__dirname, './src/pages'),
      '@styles': path.resolve(__dirname, './src/styles'),
      '@utils': path.resolve(__dirname, './src/utils'),
      '@constants': path.resolve(__dirname, './src/constants'),
      '@sdk': path.resolve(__dirname, '../sdk/src'),
    }
  },
  server: {
    port: 3000,
    strictPort: false,
    open: true,
    fs: {
      allow: ['..']
    },
  },
  build: {
    target: 'esnext',
    minify: 'esbuild',
    sourcemap: true,
    modulePreload: {
      // Don't preload lazy chunks
      resolveDependencies: (filename, deps) => {
        return deps.filter(dep =>
          !dep.includes('walletconnect') &&
          !dep.includes('WalletModal') &&
          !dep.includes('SettingsModal') &&
          !dep.includes('SearchModal') &&
          !dep.includes('NotificationsModal') &&
          !dep.includes('tvlc') &&
          !dep.includes('prism') &&
          !dep.includes('search') &&
          !dep.includes('minisearch')
        );
      },
    },
    rollupOptions: {
      output: {
        manualChunks: (id: string) => {
          // Isolate heavy libs for caching
          if (id.includes('@walletconnect') || id.includes('/ox/')) {
            return 'walletconnect';
          }
          if (id.includes('lightweight-charts')) {
            return 'tvlc';
          }
          if (id.includes('minisearch')) {
            return 'search';
          }
          // NB: markdown-wasm, prismjs, asciimath2ml are now build-time only
          if (id.includes('node_modules')) {
            // Core vendor chunk
            return 'vendor';
          }
        },
      },
    },
  }
})
