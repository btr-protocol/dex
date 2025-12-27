/**
 * SearchSection component for rendering a group of search results
 */

import type { ComponentChildren } from 'preact';
import { Icon } from '@components/ui/Icon';

interface SearchSectionProps {
  title: string;
  icon: string;
  children: ComponentChildren;
  dividerVisible?: boolean;
}

export function SearchSection({ title, icon, children, dividerVisible = true }: SearchSectionProps) {
  return (
    <>
      <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
        <Icon name={icon} className="w-3.5 h-3.5" />
        {title}
      </div>
      <div className="flex flex-col gap-1 mb-4">
        {children}
      </div>
      {dividerVisible && <div className="h-px bg-border mb-4" />}
    </>
  );
}
