import type { JSX } from 'preact';
import { MaskIcon } from './MaskIcon';

export interface IconDef {
  name: string;
  bgSvg: string;
  fgSvg: string;
}

interface ThemedIconProps {
  icon: IconDef;
  className?: string;
  bgColor?: string;
  fgColor?: string;
  color?: string;
  size?: number;
  hoverColor?: string;
}

/**
 * BorderedThemedIcon component that layers background and foreground SVGs using MaskIcon
 * Supports efficient theming via CSS variables or explicit colors
 * Automatically changes color on hover when in a group-hover context
 *
 * @example
 * <BorderedThemedIcon icon={plusIcon} />
 * <BorderedThemedIcon icon={doubleDownIcon} bgColor="var(--bg-2)" fgColor="var(--fg-1)" hoverColor="var(--primary)" />
 */
export function BorderedThemedIcon({
  icon,
  className = '',
  bgColor = 'var(--bg-1)',
  fgColor = 'var(--fg-3)',
  color,
  size = 20,
  hoverColor = 'var(--primary)',
}: ThemedIconProps) {
  // If color prop is provided, use it as fgColor
  const resolvedFgColor = color === 'primary' ? 'var(--primary)' : color || fgColor;
  const sizeStr = `${size}px`;

  return (
    <div
      className={`bordered-icon group/icon relative inline-flex items-center justify-center transition-colors ${className}`}
      style={{
        width: sizeStr,
        height: sizeStr,
        '--icon-fg-base': resolvedFgColor,
        '--icon-fg-hover': hoverColor,
      } as JSX.CSSProperties}
    >
      {/* Background layer - full size */}
      <MaskIcon
        src={icon.bgSvg}
        width={sizeStr}
        height={sizeStr}
        color={bgColor}
        aria-label={`${icon.name} background`}
        className="absolute inset-0"
      />

      {/* Foreground layer - with 10% padding to show background border */}
      <div className="absolute inset-0 p-[10%] icon-fg-wrapper">
        <MaskIcon
          src={icon.fgSvg}
          width="100%"
          height="100%"
          color={resolvedFgColor}
          aria-label={`${icon.name} foreground`}
          className="transition-colors group-hover/icon:[background-color:var(--icon-fg-hover)]"
        />
      </div>
    </div>
  );
}

// Icon definitions using SVG files
export const plusIcon: IconDef = {
  name: 'plus',
  bgSvg: '/icons/plus-bg.svg',
  fgSvg: '/icons/plus.svg',
};

export const doubleDownIcon: IconDef = {
  name: 'double-down',
  bgSvg: '/icons/double-down-bg.svg',
  fgSvg: '/icons/double-down.svg',
};
