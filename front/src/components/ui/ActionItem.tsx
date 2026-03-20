import { Icon } from './Icon';

export interface ActionItemProps {
  icon: string;
  title: string;
  description: string;
  onClick: () => void;
}

export function ActionItem({ icon, title, description, onClick }: ActionItemProps) {
  return (
    <button
      onClick={onClick}
      className="w-full flex items-center gap-3 px-4 py-3 hover:bg-bg-2 transition-colors"
    >
      <Icon name={icon} className="w-5 h-5 text-fg-2" />
      <div className="flex-1 text-left">
        <div className="text-sm font-medium">{title}</div>
        <div className="text-xs text-fg-2">{description}</div>
      </div>
    </button>
  );
}
