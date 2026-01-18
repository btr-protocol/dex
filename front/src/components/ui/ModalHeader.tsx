/**
 * ModalHeader component - handles both input and title header variants
 */

import { useRef, useEffect } from 'preact/hooks';
import { JSX } from 'preact';
import { type ComponentChildren } from 'preact';
import { Icon } from '@components/ui/Icon';
import { CloseButton } from './CloseButton';
import { Tooltip } from './Tooltip';

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

  // Focus input when modal opens, with priority for nested modals
  useEffect(() => {
    if (isOpen && headerType === 'input' && inputRef.current) {
      // Short delay to ensure this modal is the topmost
      setTimeout(() => {
        if (inputRef.current && document.activeElement !== inputRef.current) {
          inputRef.current.focus();
        }
      }, 50);
    }
  }, [isOpen, headerType]);

  // Prevent event bubbling from search input to parent modals
  const handleInputChange = (e: JSX.TargetedEvent<HTMLInputElement>) => {
    e.stopPropagation();
    onSearchChange?.((e.target as HTMLInputElement).value);
  };

  const handleInputKeyDown = (e: JSX.TargetedKeyboardEvent<HTMLInputElement>) => {
    e.stopPropagation();
    onSearchKeyDown?.(e);
  };

  return (
    <div className={`shrink-0 ${bg} border-b border-border rounded-t-lg`}>
      <div className="flex items-center gap-3 pl-3 pr-3 h-12">
        {headerType === 'input' ? (
          <>
            <Icon name="magnifying-glass" className="w-4 h-4 text-muted-foreground shrink-0" />
            <div className="relative flex-1 min-w-0">
              <input
                ref={inputRef}
                type="text"
                placeholder={placeholder || 'Search...'}
                value={searchValue || ''}
                onChange={handleInputChange}
                onKeyDown={handleInputKeyDown}
                className="w-full bg-transparent border-0 focus:outline-none text-sm h-8 font-title font-medium pr-6"
              />
              {searchValue && (
                <Tooltip content="Clear" side="bottom">
                  <button
                    type="button"
                    onClick={(e) => {
                      e.stopPropagation();
                      onSearchChange?.('');
                      inputRef.current?.focus();
                    }}
                    className="absolute right-0 top-1/2 -translate-y-1/2 p-1 hover:bg-bg-3 rounded-sm text-muted-foreground hover:text-foreground transition-colors"
                  >
                    <Icon name="x" className="w-3 h-3" />
                  </button>
                </Tooltip>
              )}
            </div>
          </>
        ) : (
          <h2 className="text-sm font-semibold flex-1 flex items-center gap-2 text-foreground">
            {headerIcon && <span className="text-foreground">{headerIcon}</span>}
            {title}
          </h2>
        )}

        <div className="flex items-center shrink-0">
          {headerRight}
          {headerRight && <div className="w-px h-6 bg-border mx-2" />}
          <CloseButton onClick={() => onClose(false)} size={18} />
        </div>
      </div>
    </div>
  );
}
