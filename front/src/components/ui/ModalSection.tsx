/**
 * ModalSection - shared component for grouping modal results/items
 * Used in SearchModal, WalletModal, and other modals with categorized content
 */

import type { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import { Icon } from '@components/ui/Icon';

interface ModalSectionProps {
  title: string;
  icon?: string;
  children: ComponentChildren;
}

export function ModalSection({ title, icon, children }: ModalSectionProps) {
  const [isChildHovered, setIsChildHovered] = useState(false);

  return (
    <div className="">
      <div
        className={`text-xs uppercase tracking-wider px-3 py-2 transition-colors flex items-center gap-2 ${
          isChildHovered ? 'text-primary' : 'text-muted-foreground'
        }`}
      >
        {icon && <Icon name={icon} className="w-3.5 h-3.5" />}
        {title}
      </div>
      <div
        onMouseEnter={() => setIsChildHovered(true)}
        onMouseLeave={() => setIsChildHovered(false)}
      >
        {children}
      </div>
    </div>
  );
}
