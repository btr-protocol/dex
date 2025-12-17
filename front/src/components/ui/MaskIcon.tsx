import { cn } from '@utils/cn';

interface MaskIconProps {
  src: string;
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl';
  /** Custom width (e.g., 'w-16', '6rem', 'auto') - overrides size */
  width?: string;
  /** Custom height (e.g., 'h-7', '1.75rem', 'auto') - overrides size */
  height?: string;
  color?: string;
  className?: string;
  'aria-label'?: string;
}

const SIZE_MAP = {
  xs: 'w-3 h-3',
  sm: 'w-4 h-4',
  md: 'w-5 h-5',
  lg: 'w-7 h-7',
  xl: 'w-10 h-10',
};

export function MaskIcon({
  src,
  size = 'sm',
  width,
  height,
  color = 'var(--fg-2)',
  className,
  'aria-label': ariaLabel
}: MaskIconProps) {
  // Build custom size styles if width or height is provided
  const customSize = (width || height) ? {
    width: width || 'auto',
    height: height || 'auto',
  } : undefined;

  return (
    <div
      className={cn(!customSize && SIZE_MAP[size], className)}
      style={{
        ...customSize,
        backgroundColor: color,
        WebkitMaskImage: `url(${src})`,
        WebkitMaskSize: 'contain',
        WebkitMaskRepeat: 'no-repeat',
        WebkitMaskPosition: 'center',
        maskImage: `url(${src})`,
        maskSize: 'contain',
        maskRepeat: 'no-repeat',
        maskPosition: 'center',
      }}
      aria-label={ariaLabel}
    />
  );
}
