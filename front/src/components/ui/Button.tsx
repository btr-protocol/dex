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
  variant?: "default" | "primary" | "outlined" | "ghost"
  size?: Size
  asChild?: boolean
  styleVariant?: "outlined" | "glass"
  leftIcon?: React.ReactNode
  rightIcon?: React.ReactNode
}

// Padding lookup - must use explicit class names for Tailwind to detect them
const PADDING_LEFT = {
  xs: { base: 'pl-2', icon: 'pl-1.5' },
  sm: { base: 'pl-3', icon: 'pl-2' },
  default: { base: 'pl-4', icon: 'pl-3' },
  lg: { base: 'pl-6', icon: 'pl-4' },
  xl: { base: 'pl-8', icon: 'pl-6' },
  'compact-xl': { base: 'pl-4', icon: 'pl-3' },
} as const

const PADDING_RIGHT = {
  xs: { base: 'pr-2', icon: 'pr-1.5' },
  sm: { base: 'pr-3', icon: 'pr-2' },
  default: { base: 'pr-4', icon: 'pr-3' },
  lg: { base: 'pr-6', icon: 'pr-4' },
  xl: { base: 'pr-8', icon: 'pr-6' },
  'compact-xl': { base: 'pr-4', icon: 'pr-3' },
} as const

// Padding based on icon presence
const getPadding = (size: Size, hasLeftIcon: boolean, hasRightIcon: boolean, isIconOnly: boolean) => {
  if (isIconOnly) return ''
  const pl = hasLeftIcon ? PADDING_LEFT[size].icon : PADDING_LEFT[size].base
  const pr = hasRightIcon ? PADDING_RIGHT[size].icon : PADDING_RIGHT[size].base
  return `${pl} ${pr}`
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default" as Size, asChild = false, styleVariant, leftIcon, rightIcon, children, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"

    // Detect if button is icon-only (single child that's not text)
    const childArray = React.Children.toArray(children) as React.ReactElement[]
    const isIconOnly = childArray.length === 1 && React.isValidElement(childArray[0]) && !leftIcon && !rightIcon

    // Merge styleVariant into variant classes
    const getVariantClasses = () => {
      if (styleVariant === "outlined" || variant === "outlined") {
        return "border border-border hover:border-primary/60 hover:bg-primary/10 text-fg-2"
      }
      if (styleVariant === "glass") {
        return "bg-white/5 border border-white/10 hover:bg-white/10 text-fg-2"
      }
      switch (variant) {
        case "primary":
          return "bg-primary text-black hover:bg-primary/90"
        case "ghost":
          return "hover:bg-accent hover:text-accent-foreground"
        default:
          return "bg-muted hover:bg-muted/80"
      }
    }

    // Add semibold weight and size adjustments for primary buttons
    const getPrimaryButtonClasses = () => {
      if (variant !== "primary") return ""
      if (size === "lg") return "font-semibold text-xl"
      if (size === "sm" || size === "default") return "font-semibold"
      return ""
    }

    // Compact-xl special padding
    const compactPadding = size === 'compact-xl' ? 'py-1.5' : ''

    const sizeClasses = cn(
      SIZE_HEIGHTS[size],
      isIconOnly ? SIZE_ICON_WIDTHS[size] : getPadding(size, !!leftIcon, !!rightIcon, isIconOnly),
      SIZE_TEXT[size],
      !isIconOnly && SIZE_GAPS[size],
      compactPadding,
      getPrimaryButtonClasses()
    )

    return (
      <Comp
        className={cn(
          "inline-flex items-center justify-center font-medium font-title transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
          BORDER_RADIUS,
          getVariantClasses(),
          sizeClasses,
          className
        )}
        ref={ref}
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
