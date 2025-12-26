/**
 * ImageWithFallback - Image with automatic fallback to default logo
 * Replaces 3+ icon loading patterns with fallback handler
 */
import { JSX } from 'preact';

interface ImageWithFallbackProps extends JSX.HTMLAttributes<HTMLImageElement> {
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
  const handleError = (e: Event) => {
    const target = e.currentTarget as HTMLImageElement;
    target.src = fallbackSrc;
    onLoadError?.(e);
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
