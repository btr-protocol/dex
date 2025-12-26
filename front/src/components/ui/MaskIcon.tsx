import { cn } from '@utils/cn';

interface MaskIconProps {
  src: string;
  size?: 'xs' | 'sm' | 'md' | 'lg' | 'xl' | number;
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
  // Build custom size styles if width, height or numeric size is provided
  const isNumericSize = typeof size === 'number';
  const customSize = (width || height || isNumericSize) ? {
    width: width || (isNumericSize ? `${size}px` : 'auto'),
    height: height || (isNumericSize ? `${size}px` : 'auto'),
  } : undefined;

  return (
    <div
      className={cn(!customSize && typeof size === 'string' && SIZE_MAP[size as keyof typeof SIZE_MAP], className)}
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
