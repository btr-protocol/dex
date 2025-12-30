/**
 * AddTokenButton component - button to add additional token to swap
 */

import { BorderedThemedIcon, plusIcon } from '@/components/ui/BorderedThemedIcon';

interface AddTokenButtonProps {
  onClick: () => void;
}

export function AddTokenButton({ onClick }: AddTokenButtonProps) {
  return (
    <button onClick={onClick} className="add-token-btn group relative w-full cursor-pointer">
      <div className="absolute left-1/2 -translate-x-1/2 -top-[1.1rem] p-1 transition-colors duration-150">
        <BorderedThemedIcon icon={plusIcon} size={20} fgColor="var(--fg-3)" hoverColor="var(--primary)" className="group-hover:text-primary transition-transform duration-150 group-hover:scale-140" />
      </div>
      <div className="w-full bg-bg-2 rounded-md py-0.5 text-fg-3 border-2 border-dashed border-border transition-all duration-150 group-hover:text-primary group-hover:bg-bg-primary group-hover:border-primary">
        <span className="text-sm font-medium">Add token</span>
      </div>
    </button>
  );
}
