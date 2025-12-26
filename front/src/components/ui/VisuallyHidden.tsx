import { JSX, Ref } from "preact"

interface VisuallyHiddenProps extends JSX.HTMLAttributes<HTMLSpanElement> {
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
