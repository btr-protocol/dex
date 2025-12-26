import { ComponentChildren } from 'preact';
import { cn } from '@utils/cn';

interface IconLabelProps {
  icon: ComponentChildren;
  label: ComponentChildren;
  iconSize?: 'xs' | 'sm' | 'md' | 'lg';
  gap?: 1 | 1.5 | 2 | 3 | 4;
  className?: string;
}

const ICON_SIZE_MAP = {
  xs: 'w-3 h-3',
  sm: 'w-4 h-4',
  md: 'w-5 h-5',
  lg: 'w-6 h-6',
};

const GAP_MAP = {
  1: 'gap-1',
  1.5: 'gap-1.5',
  2: 'gap-2',
  3: 'gap-3',
  4: 'gap-4',
};

export function IconLabel({
  icon,
  label,
  iconSize = 'sm',
  gap = 2,
  className,
}: IconLabelProps) {
  return (
    <div className={cn('flex items-center', GAP_MAP[gap], className)}>
      <div className={ICON_SIZE_MAP[iconSize]}>{icon}</div>
      {label}
    </div>
  );
}
