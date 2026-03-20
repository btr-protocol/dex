import { ComponentChildren } from 'preact';
import { useState, useRef, useEffect } from 'preact/hooks';
import { Portal } from './Portal';
import { calculatePosition, getTransform, getArrowStyles } from '@/utils/positioning';
import { cn } from '@utils/cn';

export type InteractionMode = 'hover' | 'hover-delay' | 'click' | 'auto';

export interface FloatingPanelProps {
  content: ComponentChildren;
  children: ComponentChildren;
  position?: 'top' | 'bottom' | 'left' | 'right';
  side?: 'top' | 'bottom' | 'left' | 'right';
  mode?: InteractionMode;
  delay?: number;
  asChild?: boolean;
  arrow?: boolean;
  maxWidth?: string;
  tooltipMode?: boolean;
}

/**
 * Unified floating panel component supporting both tooltip and popover behavior.
 *
 * Modes:
 * - 'hover': Show on hover (desktop only)
 * - 'hover-delay': Show on hover with delay (desktop only)
 * - 'click': Toggle on click
 * - 'auto': Hover on desktop, click on mobile
 *
 * @example
 * <FloatingPanel mode="hover" content="Tooltip">...</FloatingPanel>
 * <FloatingPanel mode="auto" content={<div>Popover</div>}>...</FloatingPanel>
 */
export function FloatingPanel({
  content,
  children,
  position,
  side,
  mode = 'auto',
  delay = 0,
  asChild,
  arrow = true,
  maxWidth = 'auto',
  tooltipMode = false,
}: FloatingPanelProps) {
  const [visible, setVisible] = useState(false);
  const [coords, setCoords] = useState({ x: 0, y: 0 });
  const triggerRef = useRef<HTMLDivElement>(null);
  const timeoutRef = useRef<number>();
  const pos = position || side || 'top';
  const isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);

  // Determine actual interaction mode
  const actualMode = mode === 'auto'
    ? (isMobile ? 'click' : 'hover')
    : mode;

  // Hover handlers
  const handleMouseEnter = () => {
    if (actualMode === 'click') return;

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
    if (actualMode !== 'click') {
      setVisible(false);
    }
  };

  // Click handler
  const handleClick = () => {
    if (actualMode === 'click') {
      setVisible(prev => !prev);
    }
  };

  // Close on outside click (click mode only)
  useEffect(() => {
    if (visible && actualMode === 'click') {
      const handleClickOutside = (e: MouseEvent) => {
        if (triggerRef.current && !triggerRef.current.contains(e.target as Node)) {
          setVisible(false);
        }
      };
      document.addEventListener('click', handleClickOutside);
      return () => document.removeEventListener('click', handleClickOutside);
    }
  }, [visible, actualMode]);

  // Calculate position with viewport clamping
  useEffect(() => {
    if (visible && triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      const gap = arrow ? 12 : 8;
      const estimatedWidth = tooltipMode ? 150 : 300;
      const estimatedHeight = tooltipMode ? 50 : 200;

      const { x, y } = calculatePosition(rect, pos, gap, {
        clampToViewport: true,
        estimatedWidth,
        estimatedHeight,
      });

      setCoords({ x, y });
    }
  }, [visible, pos, arrow, tooltipMode]);

  // Cleanup timeout
  useEffect(() => {
    return () => {
      if (timeoutRef.current) {
        clearTimeout(timeoutRef.current);
      }
    };
  }, []);

  const panelClassName = cn(
    'floating-panel',
    tooltipMode && 'rounded-xs whitespace-nowrap pointer-events-none font-medium',
    !tooltipMode && 'pointer-events-auto'
  );

  return (
    <div
      ref={triggerRef}
      className={cn(asChild ? 'block w-full' : 'inline-block')}
      onMouseEnter={actualMode !== 'click' ? handleMouseEnter : undefined}
      onMouseLeave={actualMode !== 'click' ? handleMouseLeave : undefined}
      onClick={actualMode === 'click' ? handleClick : undefined}
    >
      {children}
      {visible && content && (
        <Portal
          className={panelClassName}
          style={{
            left: coords.x,
            top: coords.y,
            transform: getTransform(pos),
            maxWidth: maxWidth === 'auto' ? undefined : maxWidth,
          }}
        >
          {arrow && <div style={getArrowStyles(pos, true) as any} />}
          {content}
        </Portal>
      )}
    </div>
  );
}

// Backward-compatible exports
export function Tooltip(props: Omit<FloatingPanelProps, 'mode' | 'tooltipMode'>) {
  return <FloatingPanel mode="hover" tooltipMode={true} {...props} />;
}

export function Popover(props: Omit<FloatingPanelProps, 'mode' | 'tooltipMode'>) {
  return <FloatingPanel mode="auto" {...props} />;
}
