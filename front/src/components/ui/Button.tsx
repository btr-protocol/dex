import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cn } from "@utils/cn"
import {
  type Size,
  BORDER_RADIUS,
  SIZE_HEIGHTS,
  SIZE_TEXT,
  SIZE_ICON_WIDTHS,
  SIZE_GAPS
} from "./sizes"

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "primary" | "outlined" | "ghost" | "glass"
  size?: Size
  asChild?: boolean
  styleVariant?: "outlined" | "glass" // Kept for backward compatibility
  leftIcon?: React.ReactNode
  rightIcon?: React.ReactNode
}

const VARIANTS = {
  default: "bg-muted hover:bg-muted/80",
  primary: "bg-primary text-black hover:bg-primary/90 font-semibold",
  outlined: "border border-border hover:border-primary/60 hover:bg-primary/10 text-fg-2",
  ghost: "hover:bg-accent hover:text-accent-foreground",
  glass: "bg-white/5 border border-white/10 hover:bg-white/10 text-fg-2",
}

const PADDING_X = {
  xs: { base: "px-2", left: "pl-1.5", right: "pr-1.5" },
  sm: { base: "px-3", left: "pl-2", right: "pr-2" },
  default: { base: "px-4", left: "pl-3", right: "pr-3" },
  lg: { base: "px-6", left: "pl-4", right: "pr-4" },
  xl: { base: "px-8", left: "pl-6", right: "pr-6" },
  "compact-xl": { base: "px-4", left: "pl-3", right: "pr-3" },
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default", asChild, styleVariant, leftIcon, rightIcon, children, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    
    // Normalize variant (prioritize styleVariant for legacy support)
    const activeVariant = styleVariant || variant
    
    // Optimization: Pre-calculate icon-only state
    const isIconOnly = !children && (!!leftIcon || !!rightIcon)
    
    // Compose dynamic classes
    const sizeStyles = cn(
      SIZE_HEIGHTS[size],
      SIZE_TEXT[size],
      !isIconOnly && SIZE_GAPS[size],
      isIconOnly ? SIZE_ICON_WIDTHS[size] : [
        PADDING_X[size].base,
        leftIcon && PADDING_X[size].left,
        rightIcon && PADDING_X[size].right
      ],
      size === "compact-xl" && "py-1.5",
      activeVariant === "primary" && size === "lg" && "text-xl"
    )

    return (
      <Comp
        ref={ref}
        className={cn(
          "inline-flex items-center justify-center font-medium font-title transition-colors",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          "disabled:pointer-events-none disabled:opacity-50",
          BORDER_RADIUS,
          VARIANTS[activeVariant as keyof typeof VARIANTS],
          sizeStyles,
          className
        )}
        {...props}
      >
        {leftIcon && <span className="shrink-0">{leftIcon}</span>}
        {children}
        {rightIcon && <span className="shrink-0 text-fg-3">{rightIcon}</span>}
      </Comp>
    )
  }
)

Button.displayName = "Button"

export { Button }
