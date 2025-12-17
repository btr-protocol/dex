/**
 * SocialLinkButton - Consolidated social media link button
 * Replaces 4+ identical social link patterns across DisclaimerPage, Footer, etc.
 */
import { Tooltip } from '@components/ui/Tooltip';
import { MaskIcon } from '@components/ui/MaskIcon';

interface SocialLinkButtonProps {
  icon: string;
  url: string;
  title: string;
  onClick?: (url: string) => void;
  tooltip?: boolean;
  variant?: 'default' | 'disclaimer';
  className?: string;
}

export function SocialLinkButton({
  icon,
  url,
  title,
  onClick,
  tooltip = true,
  variant = 'default',
  className = '',
}: SocialLinkButtonProps) {
  const handleClick = () => {
    onClick?.(url);
  };

  const baseClasses = 'text-muted-foreground hover:text-foreground transition-colors';
  const variantClasses = variant === 'disclaimer'
    ? 'w-10 h-10'
    : 'flex items-center justify-center';

  const button = (
    <button
      onClick={handleClick}
      className={`${baseClasses} ${variantClasses} ${className}`}
      aria-label={title}
    >
      {variant === 'disclaimer' ? (
        <img
          src={icon}
          alt={title}
          className="w-10 h-10"
          style={{ filter: 'invert(0.6)' }}
        />
      ) : (
        <MaskIcon src={icon} size="md" color="var(--fg-2)" />
      )}
    </button>
  );

  if (tooltip) {
    return (
      <Tooltip content={title} side="top">
        {button}
      </Tooltip>
    );
  }

  return button;
}
