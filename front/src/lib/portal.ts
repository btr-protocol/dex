import { FunctionalComponent, ComponentChildren, VNode } from 'preact'
import { useEffect, useRef } from 'preact/hooks'

/**
 * Custom portal implementation for Preact
 * Renders children into a DOM node outside the component tree
 * Useful for modals, tooltips, and dropdowns that need to escape overflow/z-index stacking
 */
export const Portal: FunctionalComponent<{ children: ComponentChildren }> = ({ children: _children }) => {
  const containerRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    if (!containerRef.current) {
      const container = document.createElement('div')
      document.body.appendChild(container)
      containerRef.current = container
    }

    return () => {
      if (containerRef.current && containerRef.current.parentNode) {
        containerRef.current.parentNode.removeChild(containerRef.current)
        containerRef.current = null
      }
    }
  }, [])

  if (!containerRef.current) return null

  return containerRef.current as any as VNode
}

/**
 * Manual portal rendering - directly append to container
 * Use in components that need more control over portal lifecycle
 */
export function createPortalContainer(id: string): HTMLDivElement {
  let container = document.getElementById(id) as HTMLDivElement
  if (!container) {
    container = document.createElement('div')
    container.id = id
    document.body.appendChild(container)
  }
  return container
}

export function removePortalContainer(id: string): void {
  const container = document.getElementById(id)
  if (container && container.parentNode) {
    container.parentNode.removeChild(container)
  }
}
