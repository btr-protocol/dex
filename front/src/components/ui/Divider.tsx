/**
 * Divider - Simple dividing line component
 * Replaces 73 instances of <div className="border-t border-border" />
 */
import { cn } from '@utils/cn';

interface DividerProps {
  orientation?: 'horizontal' | 'vertical';
  className?: string;
}

export function Divider({
  orientation = 'horizontal',
  className = '',
}: DividerProps) {
  if (orientation === 'vertical') {
    return (
      <div
        className={cn('border-r border-border', className)}
        style={{ height: '100%' }}
      />
    );
  }

  return <div className={cn('border-t border-border', className)} />;
}
