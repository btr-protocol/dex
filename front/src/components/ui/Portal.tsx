import { useRef, useEffect } from 'preact/hooks';
import { render } from 'preact';
import type { ComponentChildren } from 'preact';

interface PortalProps {
  children: ComponentChildren;
  className?: string;
  style?: Record<string, any>;
  containerId?: string;
}

export function Portal({ children, className, style, containerId }: PortalProps) {
  const containerRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!containerRef.current) {
      containerRef.current = document.createElement('div');
      if (containerId) containerRef.current.id = containerId;
      document.body.appendChild(containerRef.current);
    }

    const el = (
      <div className={className} style={style}>
        {children}
      </div>
    );

    render(el, containerRef.current);

    return () => {
      if (containerRef.current?.parentNode) {
        containerRef.current.parentNode.removeChild(containerRef.current);
        containerRef.current = null;
      }
    };
  }, [children, className, style, containerId]);

  return null;
}
