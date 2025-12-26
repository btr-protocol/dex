import { ComponentChildren } from 'preact';
import { cva } from '@utils/cva';

export interface BadgeProps {
  children: ComponentChildren;
  variant?: 'default' | 'primary' | 'positive' | 'negative' | 'code' | 'secondary';
  className?: string;
}

/**
 * Badge component - unified styling for tags, chips, status labels, and small badges.
 * CANONICAL COMPONENT: Use Badge for ALL tag/chip/badge styling needs.
 *
 * Aliases: tag, chip, label, status-badge, "already paired" indicator, kbd elements
 *
 * Styling (consistent across all variants):
 * - Padding: px-1.5 py-0.5 (tight spacing)
 * - Font: text-xs (font-medium for most, font-mono for code)
 * - Border radius: rounded-xs (5px CSS variable)
 * - Border: border border-border (subtle 1px border)
 * - Display: inline-flex with items-center for alignment
 *
 * Variants:
 * - default: bg-bg-2 text-fg-1 (grey on grey, most common)
 * - primary: bg-primary text-white (primary highlight, active filters, "Current", "Already paired")
 * - positive: bg-green text-white (success/positive states)
 * - negative: bg-red text-white (error/negative states)
 * - code: bg-bg-2 text-fg-1 font-mono (keyboard shortcuts, code snippets)
 */

const badgeVariants = cva(
  'inline-flex items-center gap-1 px-1.5 py-0.5 text-xs rounded-xs',
  {
    variants: {
      variant: {
        default: 'bg-bg-2 text-fg-1 border border-border font-medium',
        primary: 'bg-bg-primary text-primary border border-primary font-medium',
        positive: 'bg-bg-green text-green font-medium',
        negative: 'bg-bg-red text-red font-medium',
        code: 'bg-bg-2 text-fg-1 border border-border font-mono',
        secondary: 'bg-bg-2 text-fg-2 border border-border font-medium',
      },
    },
    defaultVariants: {
      variant: 'default',
    },
  }
);

export function Badge({
  children,
  variant = 'default',
  className,
}: BadgeProps) {
  return (
    <span className={badgeVariants({ variant, className })}>
      {children as any}
    </span>
  );
}
