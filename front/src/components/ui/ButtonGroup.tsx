import * as React from "react"
import { cn } from "@utils/cn"

export interface ButtonGroupProps extends React.HTMLAttributes<HTMLDivElement> {
  direction?: "horizontal" | "vertical"
  variant?: "default" | "compact"
}

const ButtonGroup = React.forwardRef<HTMLDivElement, ButtonGroupProps>(
  ({ className, direction = "horizontal", variant = "default", children, ...props }, ref) => {
    const childrenArray = React.Children.toArray(children)

    return (
      <div
        ref={ref}
        className={cn(
          "flex border rounded-sm overflow-hidden",
          direction === "vertical" ? "flex-col" : "items-center",
          variant === "compact" ? "bg-bg-2" : "",
          className
        )}
        style={{ borderColor: 'var(--border-color)' }}
        {...props}
      >
        {React.Children.map(childrenArray, (child, index) => {
          if (!React.isValidElement(child)) return child

          const isFirst = index === 0
          const isLast = index === childrenArray.length - 1

          // Build border and rounding classes
          const borderClass = direction === "vertical"
            ? !isLast ? "border-b" : ""
            : !isLast ? "border-r" : ""

          const roundingClass = direction === "vertical"
            ? isFirst ? "rounded-t-sm rounded-b-none" : isLast ? "rounded-b-sm rounded-t-none" : "rounded-none"
            : isFirst ? "rounded-l-sm rounded-r-none" : isLast ? "rounded-r-sm rounded-l-none" : "rounded-none"

          const borderStyle = !isLast ? { borderColor: 'var(--border-color)' } : {}

          return React.cloneElement(child as React.ReactElement<any>, {
            className: cn(
              (child as React.ReactElement<any>).props.className,
              borderClass,
              roundingClass
            ),
            style: {
              ...(child as React.ReactElement<any>).props.style,
              ...borderStyle
            }
          })
        })}
      </div>
    )
  }
)
ButtonGroup.displayName = "ButtonGroup"

export { ButtonGroup }
