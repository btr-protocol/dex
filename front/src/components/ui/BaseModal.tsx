import { useRef, useEffect } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';
import { Dialog, DialogContent, DialogTitle } from '@components/ui/Dialog';
import { VisuallyHidden } from '@components/ui/VisuallyHidden';
import { CloseButton } from '@components/ui/CloseButton';
import { Search } from 'lucide-react';
import { cn } from '@utils/cn';

// Standard modal padding
const MODAL_PX = 'px-4';

export interface BaseModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  title: string;
  headerType: 'input' | 'title';
  /** Icon to display left of title (headerType='title' only) */
  headerIcon?: ReactNode;
  headerRight?: ReactNode;
  children: ReactNode;
  /** @deprecated Use footerNav, footerContent, footerControls instead */
  footer?: ReactNode;
  /** Navigation shortcuts (top of footer, same bg as body) */
  footerNav?: ReactNode;
  /** Custom content (middle of footer) */
  footerContent?: ReactNode;
  /** Control buttons (bottom of footer, aligned right) */
  footerControls?: ReactNode;
  maxWidth?: string;
  /** For headerType='input': placeholder text */
  placeholder?: string;
  /** For headerType='input': controlled value */
  searchValue?: string;
  /** For headerType='input': onChange handler */
  onSearchChange?: (value: string) => void;
  /** For headerType='input': onKeyDown handler */
  onSearchKeyDown?: (e: React.KeyboardEvent<HTMLInputElement>) => void;
  /** Use lighter bg for header/footer vs body (default: true) */
  contrastHeader?: boolean;
}

export function BaseModal({
  isOpen,
  onClose,
  title,
  headerType,
  headerIcon,
  headerRight,
  children,
  footer,
  footerNav,
  footerContent,
  footerControls,
  maxWidth = 'max-w-2xl',
  placeholder,
  searchValue,
  onSearchChange,
  onSearchKeyDown,
  contrastHeader = true,
}: BaseModalProps) {
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (isOpen && headerType === 'input' && inputRef.current) {
      setTimeout(() => inputRef.current?.focus(), 100);
    }
  }, [isOpen, headerType]);

  const headerBg = contrastHeader ? 'bg-bg-2' : 'bg-bg-1';
  const footerBg = contrastHeader ? 'bg-bg-2' : 'bg-bg-1';

  return (
    <Dialog open={isOpen} onOpenChange={onClose}>
      {/* @ts-ignore - variant prop is custom extension */}
      <DialogContent variant="flush" closable={false} className={cn(maxWidth, 'flex flex-col max-h-[80vh]')}>
        {/* Visually hidden title for accessibility */}
        <VisuallyHidden>
          <DialogTitle>{title}</DialogTitle>
        </VisuallyHidden>

        {/* Fixed Header - matches h-8 (sm button size) + borders */}
        <div className={`shrink-0 ${headerBg} border-b border-border`}>
          <div className="flex items-center gap-3 pl-4 pr-3 h-12">
            {headerType === 'input' ? (
              <>
                <Search className="w-4 h-4 text-muted-foreground shrink-0" />
                <input
                  ref={inputRef}
                  type="text"
                  placeholder={placeholder || 'Search...'}
                  value={searchValue || ''}
                  onChange={(e) => onSearchChange?.(e.target.value)}
                  onKeyDown={onSearchKeyDown}
                  className="flex-1 bg-transparent border-0 focus:outline-none text-sm min-w-0 h-8"
                />
              </>
            ) : (
              <h2 className="text-sm font-semibold flex-1 flex items-center gap-2">
                {headerIcon}
                {title}
              </h2>
            )}

            {headerRight && (
              <div className="flex items-center gap-2 shrink-0">{headerRight}</div>
            )}

            {/* Close button */}
            <CloseButton onClick={() => onClose(false)} size="sm" />
          </div>
        </div>

        {/* Scrollable Body */}
        <div className="flex-1 overflow-y-auto min-h-0">{children}</div>

        {/* Fixed Footer - stacked vertical layout */}
        {(footer || footerNav || footerContent || footerControls) && (
          <div className="shrink-0 flex flex-col border-t border-border">
            {/* Legacy footer support */}
            {footer && !footerNav && !footerContent && !footerControls && (
              <div className={`${footerBg} ${MODAL_PX} py-3 flex items-center gap-2`}>
                {footer}
              </div>
            )}
            {/* New stacked footer */}
            {(footerNav || footerContent || footerControls) && (
              <>
                {/* Navigation shortcuts - same bg as body */}
                {footerNav && (
                  <div className={`bg-bg-1 ${MODAL_PX} py-1.5`}>
                    {footerNav}
                  </div>
                )}
                {/* Custom content */}
                {footerContent && (
                  <div className={`${footerBg} ${MODAL_PX} py-2.5 ${footerNav ? 'border-t border-border' : ''}`}>
                    {footerContent}
                  </div>
                )}
                {/* Control buttons - aligned right */}
                {footerControls && (
                  <div className={`${footerBg} ${MODAL_PX} py-2.5 flex justify-end gap-2 ${footerNav || footerContent ? 'border-t border-border' : ''}`}>
                    {footerControls}
                  </div>
                )}
              </>
            )}
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

// Export padding constant for children that need it
export const MODAL_PADDING = MODAL_PX;
