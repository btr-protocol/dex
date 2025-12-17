import { ReactNode } from 'react';
import { cn } from '@utils/cn';

interface CollapsibleSectionProps {
  id: string;
  title: string | ReactNode;
  isOpen: boolean;
  onToggle: () => void;
  children: ReactNode;
  hasChildren?: boolean;
  showIcon?: boolean;
  indent?: string | number;
  variant?: 'default' | 'nav' | 'toc';
  className?: string;
  titleClassName?: string;
}

/**
 * Generic collapsible section component
 * Consolidates toggle logic from NavPanel, SettingsModal, IndicatorParamsModal
 *
 * @example
 * <CollapsibleSection
 *   id="section-1"
 *   title="Advanced Settings"
 *   isOpen={isOpen}
 *   onToggle={() => setIsOpen(!isOpen)}
 *   variant="nav"
 * >
 *   <div>Content here</div>
 * </CollapsibleSection>
 */
export function CollapsibleSection({
  title,
  isOpen,
  onToggle,
  children,
  hasChildren = true,
  showIcon = true,
  indent,
  variant = 'default',
  className = '',
  titleClassName = '',
}: CollapsibleSectionProps) {
  const baseClasses = {
    default: 'w-full text-left text-sm py-1 rounded',
    nav: 'w-full text-left text-sm py-1 rounded flex items-center gap-1.5',
    toc: 'w-full text-left text-sm py-1 rounded flex items-center gap-1.5',
  };

  const activeClasses = {
    default: 'text-primary bg-primary/10',
    nav: 'text-primary bg-primary/10',
    toc: 'text-primary bg-primary/10',
  };

  const inactiveClasses = {
    default: 'text-fg-2 hover:text-fg-1',
    nav: 'text-fg-2 hover:text-fg-1',
    toc: 'text-fg-2 hover:text-fg-1',
  };

  const isActive = isOpen;
  const buttonClasses = cn(
    baseClasses[variant],
    isActive ? activeClasses[variant] : inactiveClasses[variant],
    titleClassName
  );

  const indentStyle = indent ? { paddingLeft: typeof indent === 'number' ? `${indent}rem` : indent } : undefined;

  return (
    <div className={className}>
      <button
        onClick={onToggle}
        className={buttonClasses}
        style={indentStyle}
      >
        {hasChildren && showIcon && (
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
        <span className="break-words">{title}</span>
      </button>
      {isOpen && hasChildren && <div>{children}</div>}
    </div>
  );
}
