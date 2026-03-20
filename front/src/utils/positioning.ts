export type Position = 'top' | 'bottom' | 'left' | 'right';

export interface PositionResult {
  x: number;
  y: number;
  transform: string;
}

export interface PositionOptions {
  clampToViewport?: boolean;
  estimatedWidth?: number;
  estimatedHeight?: number;
}

export function calculatePosition(
  rect: DOMRect,
  pos: Position,
  gap = 12,
  options?: PositionOptions
): PositionResult {
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

  // Clamp to viewport if requested
  if (options?.clampToViewport) {
    const width = options.estimatedWidth || 200;
    const height = options.estimatedHeight || 100;
    const viewportWidth = window.innerWidth;
    const viewportHeight = window.innerHeight;

    // Horizontal clamping: keep panel fully visible
    x = Math.max(width / 2 + 8, Math.min(x, viewportWidth - width / 2 - 8));

    // Vertical clamping: keep panel fully visible
    y = Math.max(height / 2 + 8, Math.min(y, viewportHeight - height / 2 - 8));
  }

  return {
    x,
    y,
    transform: getTransform(pos),
  };
}

export function getTransform(pos: Position): string {
  switch (pos) {
    case 'top': return 'translate(-50%, -100%)';
    case 'bottom': return 'translate(-50%, 0)';
    case 'left': return 'translate(-100%, -50%)';
    case 'right': return 'translate(0, -50%)';
  }
}

export function getArrowStyles(pos: Position, useBorder = true): Record<string, any> {
  const baseStyle = {
    position: 'absolute',
    width: '8px',
    height: '8px',
  };

  if (!useBorder) {
    return { ...baseStyle, borderStyle: 'solid' };
  }

  const arrow = {
    top: { bottom: '-5px', left: '50%', marginLeft: '-4px', borderTop: 'none', borderLeft: 'none' },
    bottom: { top: '-5px', left: '50%', marginLeft: '-4px', borderBottom: 'none', borderRight: 'none' },
    left: { right: '-5px', top: '50%', marginTop: '-4px', borderBottom: 'none', borderLeft: 'none' },
    right: { left: '-5px', top: '50%', marginTop: '-4px', borderTop: 'none', borderRight: 'none' },
  };

  return { ...baseStyle, ...arrow[pos] };
}
