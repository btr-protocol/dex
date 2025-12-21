import { ReactNode } from 'preact/compat';
import { useState, useRef, useEffect } from 'react';
import { createPortal } from 'preact/compat';

interface PopoverProps {
  content: ReactNode;
  children: ReactNode;
  position?: 'top' | 'bottom' | 'left' | 'right';
  side?: 'top' | 'bottom' | 'left' | 'right'; // Alias for position
  asChild?: boolean; // When true, renders as block instead of inline-block
  arrow?: boolean; // Show arrow pointer (default: true)
  maxWidth?: string; // Max width of popover content (default: auto)
}

/**
 * Popover component for displaying richer content than tooltips
 * Supports ReactNode content (not just strings)
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

  // Arrow pointer styles
  const getArrowStyles = () => {
    const arrowSize = '6px';
    const baseStyles = {
      position: 'absolute',
      width: '0',
      height: '0',
      borderStyle: 'solid',
    };

    switch (pos) {
      case 'top':
        return {
          ...baseStyles,
          bottom: '-6px',
          left: '50%',
          transform: 'translateX(-50%)',
          borderWidth: `${arrowSize} ${arrowSize} 0 ${arrowSize}`,
          borderColor: 'var(--bg-1) transparent transparent transparent',
        };
      case 'bottom':
        return {
          ...baseStyles,
          top: '-6px',
          left: '50%',
          transform: 'translateX(-50%)',
          borderWidth: `0 ${arrowSize} ${arrowSize} ${arrowSize}`,
          borderColor: 'transparent transparent var(--bg-1) transparent',
        };
      case 'left':
        return {
          ...baseStyles,
          right: '-6px',
          top: '50%',
          transform: 'translateY(-50%)',
          borderWidth: `${arrowSize} 0 ${arrowSize} ${arrowSize}`,
          borderColor: 'transparent transparent transparent var(--bg-1)',
        };
      case 'right':
        return {
          ...baseStyles,
          left: '-6px',
          top: '50%',
          transform: 'translateY(-50%)',
          borderWidth: `${arrowSize} ${arrowSize} ${arrowSize} 0`,
          borderColor: 'transparent var(--bg-1) transparent transparent',
        };
    }
  };

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
      {visible && content && coords && createPortal(
        <div
          className="floating-panel pointer-events-auto"
          style={{
            left: coords.x,
            top: coords.y,
            transform: getTransform(),
            maxWidth: maxWidth,
          }}
        >
          {arrow && <div style={getArrowStyles() as any} />}
          {content}
        </div>,
        document.body
      )}
    </div>
  );
}
