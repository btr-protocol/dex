import { ComponentChildren, JSX } from "preact"
import { cn } from "@utils/cn"
import { cva } from "@utils/cva"
import {
  type Size,
  BORDER_RADIUS,
  SIZE_HEIGHTS,
  SIZE_TEXT,
  SIZE_ICON_WIDTHS,
  SIZE_GAPS
} from '@/constants/design'

export interface ButtonProps extends JSX.HTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "primary" | "outlined" | "ghost" | "glass"
  size?: Size
  leftIcon?: ComponentChildren
  rightIcon?: ComponentChildren
  disabled?: boolean
}

const buttonVariants = cva(
  "inline-flex items-center justify-center font-medium font-title transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        default: "bg-muted hover:bg-muted/80 text-fg-1",
        primary: "bg-primary text-black hover:bg-primary/90 font-semibold",
        outlined: "border border-border hover:border-primary/60 hover:bg-primary/10 text-fg-2",
        ghost: "hover:bg-accent hover:text-accent-foreground",
        glass: "bg-white/5 border border-white/10 hover:bg-white/10 text-fg-2",
      },
      size: SIZE_HEIGHTS,
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
    compoundVariants: [
      {
        variant: "primary",
        size: "lg",
        className: "text-xl",
      },
    ],
  }
)

const PADDING_X = {
  xs: { base: "px-2", left: "pl-1.5", right: "pr-1.5" },
  sm: { base: "px-3", left: "pl-2", right: "pr-2" },
  default: { base: "px-4", left: "pl-3", right: "pr-3" },
  lg: { base: "px-6", left: "pl-4", right: "pr-4" },
  xl: { base: "px-8", left: "pl-6", right: "pr-6" },
  "compact-xl": { base: "px-4", left: "pl-3", right: "pr-3" },
}

export function Button({
  className,
  variant = "default",
  size = "default",
  leftIcon,
  rightIcon,
  children,
  ...props
}: ButtonProps) {
  // Optimization: Pre-calculate icon-only state
  const isIconOnly = !children && (!!leftIcon || !!rightIcon)

  // Compose dynamic classes
  const dynamicClasses = cn(
    SIZE_TEXT[size],
    !isIconOnly && SIZE_GAPS[size],
    isIconOnly ? SIZE_ICON_WIDTHS[size] : [
      (PADDING_X as any)[size].base,
      leftIcon && (PADDING_X as any)[size].left,
      rightIcon && (PADDING_X as any)[size].right
    ],
    size === "compact-xl" && "py-1.5"
  )

  return (
    <button
      className={buttonVariants({
        variant: variant as any,
        size,
        className: cn(BORDER_RADIUS, dynamicClasses, className)
      })}
      {...props}
    >
      {leftIcon && <span className="shrink-0">{leftIcon}</span>}
      {children}
      {rightIcon && <span className="shrink-0 text-fg-3">{rightIcon}</span>}
    </button>
  )
}
