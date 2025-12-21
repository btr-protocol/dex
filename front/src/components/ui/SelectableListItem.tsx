import type { ReactNode } from 'react';
import { Check } from 'lucide-react';

interface SelectableListItemProps {
  label: string;
  caption?: string;
  icon?: ReactNode;
  badge?: ReactNode;
  selected?: boolean;
  onClick: () => void;
}

export function SelectableListItem({
  label,
  caption,
  icon,
  badge,
  selected = false,
  onClick,
}: SelectableListItemProps) {
  return (
    <button
      onClick={onClick}
      className={`
        w-full px-4 py-3 flex items-center gap-3 hover:bg-bg-2/50 transition-colors text-left
        ${selected ? 'bg-bg-2/30' : ''}
      `}
    >
      {/* Icon */}
      {icon && <div className="flex-shrink-0">{icon}</div>}

      {/* Label & Caption */}
      <div className="flex-1 min-w-0">
        <div className="font-medium text-foreground truncate">{label}</div>
        {caption && <div className="text-xs text-muted-foreground truncate">{caption}</div>}
      </div>

      {/* Badge */}
      {badge && <div className="flex-shrink-0">{badge}</div>}

      {/* Selected check mark */}
      {selected && (
        <div className="flex-shrink-0">
          <Check className="w-5 h-5 text-primary" />
        </div>
      )}
    </button>
  );
}
