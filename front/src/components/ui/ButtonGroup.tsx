import * as React from "react"
import { cn } from "@utils/cn"
import { BORDER_RADIUS } from "./sizes"

export interface ButtonGroupProps extends React.HTMLAttributes<HTMLDivElement> {
  direction?: "horizontal" | "vertical"
  variant?: "default" | "compact" | "outlined"
}

const ButtonGroup = React.forwardRef<HTMLDivElement, ButtonGroupProps>(
  ({ className, direction = "horizontal", variant = "default", children, ...props }, ref) => {
    const childrenArray = React.Children.toArray(children)

    // Get border radius class without "rounded-" prefix for child elements
    const radiusSize = BORDER_RADIUS.replace('rounded-', '')

    return (
      <div
        ref={ref}
        className={cn(
          "flex overflow-hidden",
          BORDER_RADIUS,
          direction === "vertical" ? "flex-col" : "items-center",
          variant === "outlined" ? "border border-border" : "",
          variant === "compact" ? "bg-bg-2" : "",
          className
        )}
        {...props}
      >
        {React.Children.map(childrenArray, (child, index) => {
          if (!React.isValidElement(child)) return child

          const isFirst = index === 0
          const isLast = index === childrenArray.length - 1

          // Build border classes for dividers
          const borderClass = direction === "vertical"
            ? !isLast ? "border-b border-border" : ""
            : !isLast ? "border-r border-border" : ""

          // Build rounding classes using the shared radius size
          const roundingClass = direction === "vertical"
            ? isFirst ? `rounded-t-${radiusSize} rounded-b-none` : isLast ? `rounded-b-${radiusSize} rounded-t-none` : "rounded-none"
            : isFirst ? `rounded-l-${radiusSize} rounded-r-none` : isLast ? `rounded-r-${radiusSize} rounded-l-none` : "rounded-none"

          return React.cloneElement(child as React.ReactElement<any>, {
            className: cn(
              (child as React.ReactElement<any>).props.className,
              borderClass,
              roundingClass
            )
          })
        })}
      </div>
    )
  }
)
ButtonGroup.displayName = "ButtonGroup"

export { ButtonGroup }
