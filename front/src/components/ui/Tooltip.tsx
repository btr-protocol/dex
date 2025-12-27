import { ComponentChildren } from 'preact';
import { useState, useRef, useEffect } from 'preact/hooks';
import { render } from 'preact';

// Simple portal that renders outside the component tree
function TooltipPortal({ coords, getTransform, getArrowStyles, arrow, content }: any) {
  const containerRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!containerRef.current) {
      containerRef.current = document.createElement('div');
      document.body.appendChild(containerRef.current);
    }

    const el = (
      <div
        className="floating-panel rounded-xs whitespace-nowrap pointer-events-none font-medium"
        style={{
          left: coords.x,
          top: coords.y,
          transform: getTransform(),
        }}
      >
        {arrow && <div style={getArrowStyles() as any} />}
        {content}
      </div>
    );

    render(el, containerRef.current);

    return () => {
      if (containerRef.current?.parentNode) {
        containerRef.current.parentNode.removeChild(containerRef.current);
        containerRef.current = null;
      }
    };
  }, [coords, getTransform, getArrowStyles, arrow, content]);

  return null;
}

interface TooltipProps {
  content: string;
  children: ComponentChildren;
  position?: 'top' | 'bottom' | 'left' | 'right';
  side?: 'top' | 'bottom' | 'left' | 'right'; // Alias for position
  asChild?: boolean; // When true, renders as block instead of inline-block
  delay?: number; // Delay in ms before showing tooltip (default: 0)
  arrow?: boolean; // Show arrow pointer (default: true)
}

/**
 * Consistent tooltip component used across the app
 * Handles dynamic positioning, arrow pointers, and delayed showing
 *
 * @example
 * <Tooltip content="Copy" side="top" arrow>
 *   <button>Copy Button</button>
 * </Tooltip>
 */
export function Tooltip({ content, children, position, side, asChild, delay = 0, arrow = true }: TooltipProps) {
  const [visible, setVisible] = useState(false);
  const [coords, setCoords] = useState({ x: 0, y: 0 });
  const triggerRef = useRef<HTMLDivElement>(null);
  const timeoutRef = useRef<number>();
  const pos = position || side || 'top';

  // Handle delayed show
  const handleMouseEnter = () => {
    if (delay > 0) {
      timeoutRef.current = window.setTimeout(() => setVisible(true), delay);
    } else {
      setVisible(true);
    }
  };

  const handleMouseLeave = () => {
    if (timeoutRef.current) {
      clearTimeout(timeoutRef.current);
    }
    setVisible(false);
  };

  // Cleanup timeout on unmount
  useEffect(() => {
    return () => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
    };
  }, []);

  // Calculate position with viewport boundary checking
  useEffect(() => {
    if (visible && triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      const gap = arrow ? 12 : 8; // More gap with arrow
      let x = rect.left + rect.width / 2;
      let y = rect.top;

      switch (pos) {
        case 'top':
          y = rect.top - gap;
          break;
        case 'bottom':
          y = rect.bottom + gap;
          break;
        case 'left':
          x = rect.left - gap;
          y = rect.top + rect.height / 2;
          break;
        case 'right':
          x = rect.right + gap;
          y = rect.top + rect.height / 2;
          break;
      }

      // Clamp x to keep tooltip within viewport (estimate 150px max tooltip width)
      const tooltipHalfWidth = 75;
      const viewportWidth = window.innerWidth;
      if (x - tooltipHalfWidth < 8) {
        x = tooltipHalfWidth + 8;
      } else if (x + tooltipHalfWidth > viewportWidth - 8) {
        x = viewportWidth - tooltipHalfWidth - 8;
      }

      setCoords({ x, y });
    }
  }, [visible, pos, arrow]);

  const getTransform = () => {
    switch (pos) {
      case 'top':
        return 'translate(-50%, -100%)';
      case 'bottom':
        return 'translate(-50%, 0)';
      case 'left':
        return 'translate(-100%, -50%)';
      case 'right':
        return 'translate(0, -50%)';
    }
  };

  // Arrow pointer styles based on position - using rotated square for border support
  const getArrowStyles = () => ({
    position: 'absolute' as const,
    width: '8px',
    height: '8px',
    background: 'var(--bg-1)',
    border: '1px solid var(--border-color)',
    transform: 'rotate(45deg)',
    ...(pos === 'top' && {
      bottom: '-5px',
      left: '50%',
      marginLeft: '-4px',
      borderTop: 'none',
      borderLeft: 'none',
    }),
    ...(pos === 'bottom' && {
      top: '-5px',
      left: '50%',
      marginLeft: '-4px',
      borderBottom: 'none',
      borderRight: 'none',
    }),
    ...(pos === 'left' && {
      right: '-5px',
      top: '50%',
      marginTop: '-4px',
      borderBottom: 'none',
      borderLeft: 'none',
    }),
    ...(pos === 'right' && {
      left: '-5px',
      top: '50%',
      marginTop: '-4px',
      borderTop: 'none',
      borderRight: 'none',
    }),
  });

  return (
    <div
      ref={triggerRef}
      className={`${asChild ? 'block w-full' : 'inline-block'}`}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      {children}
      {visible && content && <TooltipPortal
        coords={coords}
        getTransform={getTransform}
        getArrowStyles={getArrowStyles}
        arrow={arrow}
        content={content}
      />}
    </div>
  );
}
