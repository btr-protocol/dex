import { type ComponentChildren } from 'preact';
import { Dialog, DialogPortal, DialogOverlay, DialogContent, DialogTitle } from '@components/ui/Dialog';
import { VisuallyHidden } from '@components/ui/VisuallyHidden';
import { cn } from '@utils/cn';
import { ModalHeader } from '@components/ui/ModalHeader';
import { ModalFooter } from '@components/ui/ModalFooter';

// Standard modal padding
export const MODAL_PADDING = 'px-4';

export interface BaseModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  title: string;
  headerType: 'input' | 'title';
  /** Icon to display left of title (headerType='title' only) */
  headerIcon?: ComponentChildren;
  headerRight?: ComponentChildren;
  children: ComponentChildren;
  /** Simple footer content */
  footer?: ComponentChildren;
  /** Navigation shortcuts (top of footer, same bg as body) */
  footerNav?: ComponentChildren;
  /** Custom content (middle of footer) */
  footerContent?: ComponentChildren;
  /** Control buttons (bottom of footer, aligned right) */
  footerControls?: ComponentChildren;
  maxWidth?: string;
  /** For headerType='input': placeholder text */
  placeholder?: string;
  /** For headerType='input': controlled value */
  searchValue?: string;
  /** For headerType='input': onChange handler */
  onSearchChange?: (value: string) => void;
  /** For headerType='input': onKeyDown handler */
  onSearchKeyDown?: (e: any) => void;
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
  const headerBg = contrastHeader ? 'bg-bg-2' : 'bg-bg-1';

  return (
    <Dialog open={isOpen} onOpenChange={onClose}>
      <DialogPortal>
        <DialogOverlay />
        {/* @ts-ignore - variant prop is custom extension */}
        <DialogContent variant="flush" closable={false} className={cn(maxWidth, 'flex flex-col max-h-[min(50rem,80vh)] font-title')}>
          {/* Visually hidden title for accessibility */}
          <VisuallyHidden>
            <DialogTitle>{title}</DialogTitle>
          </VisuallyHidden>

          {/* Header */}
          <ModalHeader
            title={title}
            headerType={headerType}
            headerIcon={headerIcon}
            headerRight={headerRight}
            onClose={onClose}
            placeholder={placeholder}
            searchValue={searchValue}
            onSearchChange={onSearchChange}
            onSearchKeyDown={onSearchKeyDown}
            isOpen={isOpen}
            bg={headerBg}
          />

          {/* Scrollable Body */}
          <div className="flex-1 overflow-y-auto overflow-x-hidden min-h-0">{children as any}</div>

          {/* Footer */}
          <ModalFooter
            footer={footer}
            footerNav={footerNav}
            footerContent={footerContent}
            footerControls={footerControls}
            contrastHeader={contrastHeader}
          />
        </DialogContent>
      </DialogPortal>
    </Dialog>
  );
}