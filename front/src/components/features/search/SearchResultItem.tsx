/**
 * SearchResultItem component for rendering individual search results
 */

import type { ComponentChildren } from 'preact';
import { Icon } from '@components/ui/Icon';

interface SearchResultItemProps {
  isSelected: boolean;
  onClick: () => void;
  icon?: ComponentChildren;
  title: string;
  description?: string;
  rightIcon?: ComponentChildren;
  isDocs?: boolean;
  content?: string;
}

export function SearchResultItem({
  isSelected,
  onClick,
  icon,
  title,
  description,
  rightIcon,
  isDocs = false,
  content,
}: SearchResultItemProps) {
  const justifyClass = isDocs ? 'justify-between' : '';

  return (
    <button
      onClick={onClick}
      className={`flex items-center gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${justifyClass} ${
        isSelected ? 'bg-bg-2' : 'hover:bg-bg-2'
      }`}
    >
      {icon && <div className="shrink-0">{icon}</div>}
      <div className="flex-1">
        <div className="font-semibold text-sm">{title}</div>
        {description && (
          <div className="text-xs text-muted-foreground mt-0.5 line-clamp-1">
            {description}
          </div>
        )}
        {content && (
          <div
            className="text-xs text-muted-foreground mt-0.5 line-clamp-2 search-excerpt"
            dangerouslySetInnerHTML={{ __html: content }}
          />
        )}
      </div>
      {rightIcon && <div className="shrink-0">{rightIcon}</div>}
    </button>
  );
}

/**
 * Render token icon or fallback to swap icon
 */
export function TokenIcon({ symbol, fallback }: { symbol: string; fallback?: ComponentChildren }) {
  return (
    <div className="relative w-4 h-4">
      <img
        src={`/tokens/${symbol}.svg`}
        alt={symbol}
        className="w-5 h-5 shrink-0 rounded-full"
        onError={(e) => {
          // Fallback to swap icon if token icon not found
          e.currentTarget.style.display = 'none';
          e.currentTarget.nextElementSibling?.classList.remove('hidden');
        }}
      />
      {fallback || <Icon name="arrows-left-right" className="w-4 h-4 shrink-0 hidden" />}
    </div>
  );
}
