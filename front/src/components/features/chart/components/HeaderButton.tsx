import { Icon } from '@components/ui/Icon';
import { Tooltip } from '@components/ui/FloatingPanel';

interface HeaderButtonProps {
  iconName: string;
  onClick: () => void;
  tooltip: string;
  danger?: boolean;
}

export function HeaderButton({
  iconName,
  onClick,
  tooltip,
  danger,
}: HeaderButtonProps) {
  return (
    <Tooltip content={tooltip} side="top">
      <button
        onClick={onClick}
        className={`w-4 h-4 flex items-center justify-center rounded-xs hover:bg-bg-2 text-fg-2 transition-colors ${
          danger ? 'hover:text-red' : 'hover:text-primary'
        }`}
      >
        <Icon name={iconName} className="w-2.5 h-2.5" />
      </button>
    </Tooltip>
  );
}
