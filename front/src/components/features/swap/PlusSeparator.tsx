/**
 * PlusSeparator component - visual separator between tokens with plus icon
 */

import { BorderedThemedIcon, plusIcon } from '@/components/ui/BorderedThemedIcon';

export function PlusSeparator() {
  return (
    <div className="relative h-0">
      <div className="absolute left-1/2 -translate-x-1/2 -top-[1.1rem] p-1">
        <BorderedThemedIcon icon={plusIcon} size={20} color="primary" />
      </div>
    </div>
  );
}
