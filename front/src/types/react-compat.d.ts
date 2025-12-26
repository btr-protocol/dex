import 'preact/compat'

declare module 'preact' {
  // Extend ComponentChildren to exclude bigint for React compatibility
  export type ComponentChildren =
    | VNode<any>
    | object
    | string
    | number
    | big_int
    | null
    | undefined
    | boolean
}

declare module 'preact/compat' {
  // Ensure React.Suspense is available
  export const Suspense: any
}
