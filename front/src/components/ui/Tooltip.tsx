import { ComponentChildren } from 'preact';
import { useState, useRef, useEffect } from 'preact/hooks';
import { Portal } from './Portal';
import { calculatePosition, getTransform, getArrowStyles } from '@/utils/positioning';

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
      const { x, y } = calculatePosition(rect, pos, gap);

      // Clamp x to keep tooltip within viewport (estimate 150px max tooltip width)
      const tooltipHalfWidth = 75;
      const viewportWidth = window.innerWidth;
      const clampedX = Math.max(tooltipHalfWidth + 8, Math.min(x, viewportWidth - tooltipHalfWidth - 8));

      setCoords({ x: clampedX, y });
    }
  }, [visible, pos, arrow]);

  return (
    <div
      ref={triggerRef}
      className={`${asChild ? 'block w-full' : 'inline-block'}`}
      onMouseEnter={handleMouseEnter}
      onMouseLeave={handleMouseLeave}
    >
      {children}
      {visible && content && (
        <Portal
          className="floating-panel rounded-xs whitespace-nowrap pointer-events-none font-medium"
          style={{
            left: coords.x,
            top: coords.y,
            transform: getTransform(pos),
          }}
        >
          {arrow && <div style={getArrowStyles(pos, true) as any} />}
          {content}
        </Portal>
      )}
    </div>
  );
}
