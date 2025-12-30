import { Icon } from './Icon';
import { cn } from '@utils/cn';

interface CloseButtonProps {
  onClick: () => void;
  size?: number;
  className?: string;
}

export function CloseButton({ onClick, size = 18, className }: CloseButtonProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'opacity-70 hover:opacity-100 transition-opacity focus:outline-none',
        className
      )}
      aria-label="Close"
    >
      <Icon name="x" size={size} />
    </button>
  );
}
