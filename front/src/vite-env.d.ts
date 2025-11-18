/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly DEV: boolean
  readonly PROD: boolean
  readonly MODE: string
  readonly VITE_WC_PROJECT_ID?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
  readonly hot?: {
    accept: (cb?: () => void) => void
    on: (event: string, cb: () => void) => void
  }
}
