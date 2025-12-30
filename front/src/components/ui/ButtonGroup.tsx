import { Ref, cloneElement, isValidElement, ComponentChildren, JSX } from "preact"
import type { HTMLAttributes } from "preact/compat"
import { cn } from "@utils/cn"
import { cva } from "@utils/cva"
import { BORDER_RADIUS } from '@/constants/design'

export interface ButtonGroupProps extends HTMLAttributes<HTMLDivElement> {
  direction?: "horizontal" | "vertical"
  variant?: "default" | "compact" | "outlined"
  ref?: Ref<HTMLDivElement>
}

const buttonGroupVariants = cva(
  `flex overflow-hidden ${BORDER_RADIUS}`,
  {
    variants: {
      direction: {
        horizontal: "items-center",
        vertical: "flex-col",
      },
      variant: {
        default: "",
        compact: "bg-bg-2",
        outlined: "border border-border",
      },
    },
    defaultVariants: {
      direction: "horizontal",
      variant: "default",
    },
  }
);

export function ButtonGroup({ className, direction = "horizontal", variant = "default", children, ...props }: ButtonGroupProps) {
  const childrenArray: ComponentChildren[] = Array.isArray(children) ? children : [children]
  const classNameValue = typeof className === 'string' ? className : undefined;

  // Get border radius class without "rounded-" prefix for child elements
  const radiusSize = BORDER_RADIUS.replace('rounded-', '')

  return (
    <div
      className={buttonGroupVariants({ direction, variant, className: classNameValue })}
      {...props}
    >
      {childrenArray.map((child, index: number) => {
        if (!isValidElement(child)) return child

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

        const childProps = (child as JSX.Element).props as { className?: string; children?: ComponentChildren };
        const existingClassName = childProps.className;
        return cloneElement(child as JSX.Element, {
          className: cn(
            typeof existingClassName === 'string' ? existingClassName : undefined,
            borderClass,
            roundingClass
          )
        })
      })}
    </div>
  )
}
