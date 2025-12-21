/**
 * Typography Micro-Components
 * Consolidates common text patterns
 */
import { cn } from '@utils/cn';
import type { ReactNode } from 'react';

interface TextProps {
  children: ReactNode;
  className?: string;
  as?: 'span' | 'p' | 'div' | 'label';
}

// text-xs text-muted-foreground (20+ instances)
export function Caption({ children, className, as: Tag = 'span' }: TextProps) {
  return (
    <Tag className={cn('text-xs text-muted-foreground', className)}>
      {children}
    </Tag>
  );
}

// text-sm text-muted-foreground (16+ instances)
export function Label({ children, className, as: Tag = 'span' }: TextProps) {
  return (
    <Tag className={cn('text-sm text-muted-foreground', className)}>
      {children}
    </Tag>
  );
}

// text-xs text-fg-2 (common for section headers)
export function SectionHeader({ children, className }: TextProps) {
  return (
    <h2 className={cn('font-semibold text-xs text-fg-2 uppercase tracking-wide font-title', className)}>
      {children}
    </h2>
  );
}
