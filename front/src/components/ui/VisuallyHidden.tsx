import { Ref } from "preact"
import type { HTMLAttributes } from "preact/compat"

interface VisuallyHiddenProps extends HTMLAttributes<HTMLSpanElement> {
  ref?: Ref<HTMLSpanElement>
}

export function VisuallyHidden({ className, ref, ...props }: VisuallyHiddenProps) {
  return (
    <span
      ref={ref}
      className={className || "sr-only"}
      {...props}
    />
  )
}
