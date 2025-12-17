/**
 * Flex Layout Micro-Components
 * Consolidates common flex patterns to reduce Tailwind duplication
 */
import { cn } from '@utils/cn';
import type { ReactNode } from 'react';

interface FlexProps {
  children: ReactNode;
  className?: string;
  gap?: '0.5' | '1' | '1.5' | '2' | '3' | '4';
  as?: 'div' | 'section' | 'header' | 'footer' | 'nav';
  onClick?: () => void;
  style?: any;
}

// flex items-center gap-* (36+ instances)
export function FlexRow({ children, className, gap = '2', as: Tag = 'div', onClick, style }: FlexProps) {
  return (
    <Tag className={cn(`flex items-center gap-${gap}`, className)} onClick={onClick} style={style}>
      {children}
    </Tag>
  );
}

// flex items-center justify-between (23+ instances)
export function FlexBetween({ children, className, as: Tag = 'div', onClick, style }: Omit<FlexProps, 'gap'>) {
  return (
    <Tag className={cn('flex items-center justify-between', className)} onClick={onClick} style={style}>
      {children}
    </Tag>
  );
}

// flex items-center justify-center (30+ instances)
export function FlexCenter({ children, className, as: Tag = 'div', onClick, style }: Omit<FlexProps, 'gap'>) {
  return (
    <Tag className={cn('flex items-center justify-center', className)} onClick={onClick} style={style}>
      {children}
    </Tag>
  );
}

// flex flex-col gap-* (7+ instances)
export function FlexCol({ children, className, gap = '2', as: Tag = 'div', style }: FlexProps) {
  return (
    <Tag className={cn(`flex flex-col gap-${gap}`, className)} style={style}>
      {children}
    </Tag>
  );
}
