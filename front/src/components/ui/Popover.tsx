import { ComponentChildren } from 'preact';
import { useState, useRef, useEffect } from 'preact/hooks';
import { Portal } from './Portal';
import { calculatePosition, getTransform, getArrowStyles } from '@/utils/positioning';

interface PopoverProps {
  content: ComponentChildren;
  children: ComponentChildren;
  position?: 'top' | 'bottom' | 'left' | 'right';
  side?: 'top' | 'bottom' | 'left' | 'right'; // Alias for position
  asChild?: boolean; // When true, renders as block instead of inline-block
  arrow?: boolean; // Show arrow pointer (default: true)
  maxWidth?: string; // Max width of popover content (default: auto)
}

/**
 * Popover component for displaying richer content than tooltips
 * Supports ComponentChildren content (not just strings)
 *
 * @example
 * <Popover content={<div>Complex content</div>} side="bottom">
 *   <button>Open Popover</button>
 * </Popover>
 */
export function Popover({
  content,
  children,
  position,
  side,
  asChild,
  arrow = true,
  maxWidth = 'auto',
}: PopoverProps) {
  const [visible, setVisible] = useState(false);
  const [coords, setCoords] = useState<{ x: number; y: number } | null>(null);
  const triggerRef = useRef<HTMLDivElement>(null);
  const pos = position || side || 'bottom';
  const isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);

  // Calculate position
  useEffect(() => {
    if (visible && triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      const gap = arrow ? 12 : 8;
      const { x, y } = calculatePosition(rect, pos, gap);
      setCoords({ x, y });
    }
  }, [visible, pos, arrow]);

  // Close on outside click
  useEffect(() => {
    const handleClickOutside = (e: MouseEvent) => {
      if (triggerRef.current && !triggerRef.current.contains(e.target as Node)) {
        setVisible(false);
      }
    };

    if (visible) {
      document.addEventListener('click', handleClickOutside);
      return () => document.removeEventListener('click', handleClickOutside);
    }
  }, [visible]);

  return (
    <div
      ref={triggerRef}
      className={`${asChild ? 'block w-full' : 'inline-block'}`}
      onClick={isMobile ? () => setVisible(!visible) : undefined}
      onMouseEnter={!isMobile ? () => setVisible(true) : undefined}
      onMouseLeave={!isMobile ? () => setVisible(false) : undefined}
    >
      {children}
      {visible && content && coords && (
        <Portal
          className="floating-panel pointer-events-auto"
          style={{
            left: coords.x,
            top: coords.y,
            transform: getTransform(pos),
            maxWidth: maxWidth,
          }}
        >
          {arrow && <div style={getArrowStyles(pos, true) as any} />}
          {content}
        </Portal>
      )}
    </div>
  );
}
