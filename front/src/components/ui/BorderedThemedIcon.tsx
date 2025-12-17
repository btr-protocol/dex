export interface IconDef {
  name: string;
  bgViewBox?: string;
  fgViewBox?: string;
  bgPaths: string[];
  fgPaths: string[];
}

interface ThemedIconProps {
  icon: IconDef;
  className?: string;
  bgColor?: string;
  fgColor?: string;
  color?: string;
  size?: number;
}

/**
 * BorderedThemedIcon component that combines background and foreground SVG paths
 * Supports efficient theming via CSS variables or explicit colors
 *
 * @example
 * <BorderedThemedIcon icon={plusIcon} />
 * <BorderedThemedIcon icon={doubleDownIcon} bgColor="#1a1a1a" fgColor="white" />
 */
export function BorderedThemedIcon({
  icon,
  className = '',
  bgColor = 'var(--bg-1)',
  fgColor = 'var(--fg-3)',
  color,
  size = 20,
}: ThemedIconProps) {
  // If color prop is provided, use it as fgColor
  const resolvedFgColor = color === 'primary' ? 'var(--primary)' : color || fgColor;
  const bgViewBox = icon.bgViewBox || '0 0 20 19';
  const fgViewBox = icon.fgViewBox || '0 0 14 13';

  return (
    <div
      className={`bordered-icon relative inline-flex items-center justify-center ${className}`}
      style={{ width: size, height: size, '--icon-fg': resolvedFgColor, '--icon-bg': bgColor } as React.CSSProperties}
    >
      {/* Background layer */}
      <svg
        width={size}
        height={size}
        viewBox={bgViewBox}
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="absolute inset-0"
      >
        {icon.bgPaths.map((path, i) => (
          <path key={`bg-${i}`} d={path} className="icon-bg" />
        ))}
      </svg>

      {/* Foreground layer */}
      <svg
        width={size}
        height={size}
        viewBox={fgViewBox}
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        className="absolute inset-0 p-[15%]"
      >
        {icon.fgPaths.map((path, i) => (
          <path key={`fg-${i}`} d={path} className="icon-fg" />
        ))}
      </svg>
    </div>
  );
}

// Icon definitions
export const plusIcon: IconDef = {
  name: 'plus',
  bgViewBox: '0 0 20 19',
  fgViewBox: '0 0 14 13',
  bgPaths: ['M14.5 19H5.5V14H0V5H5.5V0H14.5V5H20V14H14.5V19Z'],
  fgPaths: ['M8.5 0H5.5V5H0V8H5.5V13H8.5V8H14V5H8.5V0Z'],
};

export const doubleDownIcon: IconDef = {
  name: 'double-down',
  bgViewBox: '0 0 28 31',
  fgViewBox: '0 0 20 21',
  bgPaths: ['M0 0V21.25L12.6 30.25H15.4L28 21.25V0H24.85L14 7.75L3.15 0H0Z'],
  fgPaths: [
    'M20 9V14L10 21L0 14V9L10 16L20 9Z',
    'M20 0V5L10 12L0 5V0L10 7L20 0Z',
  ],
};
