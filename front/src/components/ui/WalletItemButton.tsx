/**
 * WalletItemButton - Consolidated wallet item button (detected, discover, or generic)
 * Consolidates WalletButton and DiscoverWalletButton patterns from WalletModal
 */
import type { ComponentChildren } from 'preact';
import { Icon } from './Icon';
import { Badge } from './Badge';
import { ImageWithFallback } from './ImageWithFallback';
import { Tooltip } from './Tooltip';

type WalletItemVariant = 'detected' | 'discover' | 'default';

interface WalletItemButtonProps {
  name: string;
  icon: string;
  onClick: () => void;
  disabled?: boolean;
  variant?: WalletItemVariant;
  isConnecting?: boolean;
  tooltip?: string;
  rightIcon?: ComponentChildren;
  isHighlighted?: boolean;
}

export function WalletItemButton({
  name,
  icon,
  onClick,
  disabled = false,
  variant = 'default',
  isConnecting = false,
  tooltip,
  rightIcon,
  isHighlighted = false,
}: WalletItemButtonProps) {
  const button = (
    <button
      className={`w-full flex items-center gap-3 h-12 px-3 border-bottom border-border disabled:opacity-50 disabled:cursor-not-allowed font-title transition-colors ${
        isHighlighted ? 'bg-bg-3 hover-primary' : 'bg-bg-2 hover-primary'
      }`}
      onClick={onClick}
      disabled={disabled || isConnecting}
    >
      <div className="w-7 h-7 rounded-xs overflow-hidden flex-shrink-0">
        <ImageWithFallback
          src={icon}
          alt={name}
          className="w-full h-full object-contain"
        />
      </div>
      <span className="font-medium flex-1 text-left text-fg-1 text-sm">
        {name}
      </span>
      {rightIcon || (
        <>
          {variant === 'detected' && <Badge variant="positive">Detected</Badge>}
          {variant === 'discover' && <Icon name="arrow-square-out" className="w-4 h-4 text-fg-2 flex-shrink-0" />}
          {isConnecting && (
            <div className="w-4 h-4 border-2 border-primary border-t-transparent rounded-full animate-spin flex-shrink-0" />
          )}
        </>
      )}
    </button>
  );

  if (tooltip) {
    return (
      <Tooltip content={tooltip} side="top" asChild>
        {button}
      </Tooltip>
    );
  }

  return button;
}
