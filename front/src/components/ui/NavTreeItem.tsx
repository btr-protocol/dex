import { ReactNode } from 'react';
import { cn } from '@utils/cn';

export interface NavItem {
  id: string;
  label: string;
  level: number;
  children?: NavItem[];
}

interface NavTreeItemProps {
  item: NavItem;
  type: 'file' | 'toc';
  isActive: boolean;
  hasActiveChild: boolean;
  isOpen: boolean;
  onToggle: () => void;
  renderChildren?: (() => ReactNode) | null;
  level?: number;
  indent?: (level: number) => number;
}

/**
 * Unified tree navigation item component
 * Consolidates FileItem + TocSection logic from NavPanel
 *
 * @example
 * <NavTreeItem
 *   item={navItem}
 *   type="file"
 *   isActive={isActive}
 *   hasActiveChild={hasActiveChild}
 *   isOpen={isOpen}
 *   onToggle={handleToggle}
 *   renderChildren={renderChildren}
 * />
 */
export function NavTreeItem({
  item,
  type,
  isActive,
  hasActiveChild,
  isOpen,
  onToggle,
  renderChildren,
  level = 0,
  indent,
}: NavTreeItemProps) {
  const hasChildren = !!(item.children?.length || (renderChildren as any));
  const shouldShowChevron = hasChildren;
  const indentValue = indent ? indent(level) : level * 0.75;

  const isHighlighted = isActive || hasActiveChild;

  return (
    <div>
      <button
        onClick={onToggle}
        className={cn(
          'w-full text-left text-sm py-1 rounded flex items-center gap-1.5 transition-colors',
          isHighlighted ? 'text-primary bg-primary/10' : 'text-fg-2 hover:text-fg-1'
        )}
        style={type === 'file' ? { paddingLeft: `${indentValue}rem` } : undefined}
      >
        {shouldShowChevron && (
          <svg
            className={cn('w-3 h-3 shrink-0 transition-transform', isOpen && 'rotate-90')}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              strokeWidth={2}
              d="M9 5l7 7-7 7"
            />
          </svg>
        )}
        <span className="break-words">{item.label}</span>
      </button>
      {isOpen && renderChildren && (
        <div className={type === 'toc' ? 'ml-3' : undefined}>
          {renderChildren()}
        </div>
      )}
    </div>
  );
}
