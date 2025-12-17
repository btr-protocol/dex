/**
 * ImageWithFallback - Image with automatic fallback to default logo
 * Replaces 3+ icon loading patterns with fallback handler
 */
import { ImgHTMLAttributes } from 'react';

interface ImageWithFallbackProps extends ImgHTMLAttributes<HTMLImageElement> {
  fallbackSrc?: string;
  onLoadError?: (e: Event) => void;
}

export function ImageWithFallback({
  src,
  fallbackSrc = '/brand/logo-b.svg',
  alt = '',
  onLoadError,
  ...props
}: ImageWithFallbackProps) {
  const handleError = (e: React.SyntheticEvent<HTMLImageElement>) => {
    e.currentTarget.src = fallbackSrc;
    onLoadError?.(e.nativeEvent);
  };

  return (
    <img
      src={src}
      alt={alt}
      onError={handleError}
      {...props}
    />
  );
}
