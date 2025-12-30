/**
 * ModalFooter component - handles multi-section footer layout
 * Sections: navigation shortcuts, custom content, control buttons
 */

import { type ComponentChildren } from 'preact';
import { MODAL_PADDING } from '@components/ui/BaseModal';

interface ModalFooterProps {
  /** Simple footer content (used when only basic footer needed) */
  footer?: ComponentChildren;
  /** Navigation shortcuts (top of footer, same bg as body) */
  footerNav?: ComponentChildren;
  /** Custom content (middle of footer) */
  footerContent?: ComponentChildren;
  /** Control buttons (bottom of footer, aligned right) */
  footerControls?: ComponentChildren;
  /** Use lighter bg for footer vs body (default: true) */
  contrastHeader?: boolean;
}

export function ModalFooter({
  footer,
  footerNav,
  footerContent,
  footerControls,
  contrastHeader = true,
}: ModalFooterProps) {
  // Don't render if no footer content
  if (!footer && !footerNav && !footerContent && !footerControls) {
    return null;
  }

  const footerBg = contrastHeader ? 'bg-bg-2' : 'bg-bg-1';

  // Simple footer mode - just footer content
  if (footer && !footerNav && !footerContent && !footerControls) {
    return (
      <div className="shrink-0 flex flex-col border-t border-border">
        <div className={`${footerBg} ${MODAL_PADDING} py-3 flex items-center gap-2`}>
          {footer as any}
        </div>
      </div>
    );
  }

  // New stacked footer layout
  return (
    <div className="shrink-0 flex flex-col border-t border-border">
      {/* Navigation shortcuts - same bg as body */}
      {footerNav && (
        <div className={`bg-bg-1 ${MODAL_PADDING} py-1.5 flex justify-center ${!footerContent && !footerControls ? 'rounded-b-lg' : ''}`}>
          {footerNav as any}
        </div>
      )}

      {/* Custom content */}
      {footerContent && (
        <div
          className={`${footerBg} ${MODAL_PADDING} py-2.5 ${footerNav ? 'border-t border-border' : ''} ${!footerControls ? 'rounded-b-lg' : ''}`}
        >
          {footerContent as any}
        </div>
      )}

      {/* Control buttons - aligned right */}
      {footerControls && (
        <div
          className={`${footerBg} ${MODAL_PADDING} py-2.5 flex justify-end gap-2 ${footerNav || footerContent ? 'border-t border-border' : ''} rounded-b-lg`}
        >
          {footerControls as any}
        </div>
      )}
    </div>
  );
}
