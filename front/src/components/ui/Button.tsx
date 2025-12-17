import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cn } from "@utils/cn"

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "primary" | "outline" | "ghost"
  size?: "sm" | "lg" | "default" | "xs" | "compact-xl" | "compact-md"
  asChild?: boolean
  /** @deprecated Use icon + children instead */
  leftIcon?: React.ReactNode
  /** @deprecated Use icon + children instead */
  rightIcon?: React.ReactNode
  styleVariant?: "outlined" | "glass"
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default", asChild = false, leftIcon, rightIcon, styleVariant, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"

    // Merge styleVariant into variant classes
    const getVariantClasses = () => {
      if (styleVariant === "outlined") {
        return "border border-primary/40 hover:border-primary/60 hover:bg-primary/10"
      }
      if (styleVariant === "glass") {
        return "bg-white/5 border border-white/10 hover:bg-white/10"
      }
      switch (variant) {
        case "primary":
          return "bg-primary text-primary-foreground hover:bg-primary/90"
        case "outline":
          return "border border-primary/40 hover:border-primary/60 hover:bg-primary/10"
        case "ghost":
          return "hover:bg-accent hover:text-accent-foreground"
        default:
          return "bg-muted hover:bg-muted/80"
      }
    }

    const getSizeClasses = () => {
      switch (size) {
        case "xs":
          return "h-6 px-2 text-xs"
        case "sm":
          return "h-8 px-3 text-xs"
        case "lg":
          return "h-11 px-8"
        case "compact-md":
          return "h-7 px-2.5 text-xs"
        case "compact-xl":
          return "h-9 px-4 text-sm"
        default:
          return "h-10 px-4"
      }
    }

    return (
      <Comp
        className={cn(
          "inline-flex items-center justify-center gap-2 rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
          getVariantClasses(),
          getSizeClasses(),
          className
        )}
        ref={ref}
        {...props}
      >
        {leftIcon}
        {props.children}
        {rightIcon}
      </Comp>
    )
  }
)
Button.displayName = "Button"

export { Button }
