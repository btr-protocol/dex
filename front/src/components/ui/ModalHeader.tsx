/**
 * ModalHeader component - handles both input and title header variants
 */

import { useRef, useEffect } from 'preact/hooks';
import { JSX } from 'preact';
import { type ComponentChildren } from 'preact';
import { Icon } from '@components/ui/Icon';
import { CloseButton } from './CloseButton';

interface ModalHeaderProps {
  title: string;
  headerType: 'input' | 'title';
  headerIcon?: ComponentChildren;
  headerRight?: ComponentChildren;
  onClose: (open: boolean) => void;
  /** For headerType='input' only */
  placeholder?: string;
  searchValue?: string;
  onSearchChange?: (value: string) => void;
  onSearchKeyDown?: (e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => void;
  isOpen?: boolean;
  bg?: string;
}

export function ModalHeader({
  title,
  headerType,
  headerIcon,
  headerRight,
  onClose,
  placeholder,
  searchValue,
  onSearchChange,
  onSearchKeyDown,
  isOpen,
  bg = 'bg-bg-2',
}: ModalHeaderProps) {
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen && headerType === 'input' && inputRef.current) {
      setTimeout(() => inputRef.current?.focus(), 100);
    }
  }, [isOpen, headerType]);

  return (
    <div className={`shrink-0 ${bg} border-b border-border rounded-t-lg`}>
      <div className="flex items-center gap-3 pl-3 pr-3 h-12">
        {headerType === 'input' ? (
          <>
            <Icon name="magnifying-glass" className="w-4 h-4 text-muted-foreground shrink-0" />
            <input
              ref={inputRef}
              type="text"
              placeholder={placeholder || 'Search...'}
              value={searchValue || ''}
              onChange={(e) => onSearchChange?.((e.target as HTMLInputElement).value)}
              onKeyDown={onSearchKeyDown}
              className="flex-1 bg-transparent border-0 focus:outline-none text-sm min-w-0 h-8 font-title font-medium"
            />
          </>
        ) : (
          <h2 className="text-sm font-semibold flex-1 flex items-center gap-2 text-foreground">
            {headerIcon && <span className="text-foreground">{headerIcon}</span>}
            {title}
          </h2>
        )}

        {headerRight && (
          <div className="flex items-center gap-2 shrink-0">{headerRight}</div>
        )}

        <CloseButton onClick={() => onClose(false)} size={18} />
      </div>
    </div>
  );
}
