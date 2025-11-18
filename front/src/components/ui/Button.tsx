import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cn } from "@utils/cn"

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: "default" | "primary" | "outline" | "ghost"
  size?: "sm" | "lg" | "default"
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant = "default", size = "default", asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    return (
      <Comp
        className={cn(
          "inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:pointer-events-none disabled:opacity-50",
          {
            "bg-primary text-primary-foreground hover:bg-primary/90": variant === "primary",
            "bg-muted hover:bg-muted/80": variant === "default",
            "border border-primary/40 hover:border-primary/60 hover:bg-primary/10": variant === "outline",
            "hover:bg-accent hover:text-accent-foreground": variant === "ghost",
          },
          {
            "h-8 px-3 text-xs": size === "sm",
            "h-10 px-4": size === "default",
            "h-11 px-8": size === "lg",
          },
          className
        )}
        ref={ref}
        {...props}
      />
    )
  }
)
Button.displayName = "Button"

export { Button }
