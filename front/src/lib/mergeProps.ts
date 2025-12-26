import { VNode } from 'preact'

/**
 * Utility to merge props and create composite components (asChild pattern)
 * Combines refs, class names, handlers, and other attributes intelligently
 */
export function mergeProps(
  childElement: any,
  mergedProps: Record<string, any>
): any {
  if (!childElement) return childElement

  const {
    ref,
    className,
    style,
    onClick,
    onPointerDown,
    onKeyDown,
    ...otherProps
  } = mergedProps

  const childProps = childElement.props || {}
  const mergedClassName = [childProps.className, className]
    .filter(Boolean)
    .join(' ')

  const mergedStyle = {
    ...childProps.style,
    ...style,
  }

  // Merge event handlers
  const mergedEventHandlers: Record<string, any> = {}

  // Click handler
  if (onClick || childProps.onClick) {
    mergedEventHandlers.onClick = (e: any) => {
      childProps.onClick?.(e)
      if (!e.defaultPrevented) {
        onClick?.(e)
      }
    }
  }

  // PointerDown handler (for click-outside detection)
  if (onPointerDown || childProps.onPointerDown) {
    mergedEventHandlers.onPointerDown = (e: any) => {
      childProps.onPointerDown?.(e)
      if (!e.defaultPrevented) {
        onPointerDown?.(e)
      }
    }
  }

  // KeyDown handler
  if (onKeyDown || childProps.onKeyDown) {
    mergedEventHandlers.onKeyDown = (e: any) => {
      childProps.onKeyDown?.(e)
      if (!e.defaultPrevented) {
        onKeyDown?.(e)
      }
    }
  }

  // Merge refs
  const mergedRef = (el: any) => {
    if (childProps.ref) {
      if (typeof childProps.ref === 'function') {
        childProps.ref(el)
      } else {
        childProps.ref.current = el
      }
    }
    if (ref) {
      if (typeof ref === 'function') {
        ref(el)
      } else {
        ref.current = el
      }
    }
  }

  return {
    ...childElement,
    props: {
      ...childProps,
      ...otherProps,
      ref: mergedRef,
      className: mergedClassName || undefined,
      style: Object.keys(mergedStyle).length > 0 ? mergedStyle : undefined,
      ...mergedEventHandlers,
    },
  }
}

/**
 * Helper to clone child element with merged props
 * Used in Button with asChild pattern
 */
export function cloneWithProps(
  element: VNode<any> | null | undefined,
  props: Record<string, any>
): VNode<any> | null | undefined {
  if (!element) return element
  return mergeProps(element, props)
}
