import { useState, useRef, useEffect, ReactNode, cloneElement, ComponentType } from 'react';
import { createPortal } from 'preact/compat';
import { ChevronDown, Check } from 'lucide-react';
import type { LucideProps } from 'lucide-react';
import { cn } from '@utils/cn';
import { Button, ButtonProps } from './Button';
import { Tooltip } from './Tooltip';
import { type Size, DROPDOWN_ITEM_SIZES, SIZE_CHECK } from '@/constants/design';
import { renderIcon, isStringIcon } from '@utils/iconHelpers';
import { DropdownItem } from '@/types/ui';

export type { DropdownItem } from '@/types/ui';

interface DropdownProps<T = string> {
  items: DropdownItem<T>[];
  value: T | T[];
  onChange: (value: T | T[]) => void;
  mode?: 'single' | 'multi';
  /** Render custom trigger, or use default button */
  trigger?: ReactNode;
  /** Label shown in default trigger */
  placeholder?: string;
  /** Size variant */
  size?: Size;
  /** Style variant - maps to Button styleVariant */
  styleVariant?: ButtonProps['styleVariant'];
  /** Direction to open */
  side?: 'top' | 'bottom' | 'auto';
  /** Additional className for trigger */
  className?: string;
  /** Controlled open state */
  open?: boolean;
  onOpenChange?: (open: boolean) => void;
  /** Footer content (e.g., "Clear all" button) */
  footer?: ReactNode;
  /** Min width of dropdown panel */
  minWidth?: number;
}

export function Dropdown<T = string>({
  items,
  value,
  onChange,
  mode = 'single',
  trigger,
  placeholder = 'Select...',
  size = 'default',
  styleVariant = 'glass',
  side = 'auto',
  className,
  open: controlledOpen,
  onOpenChange,
  footer,
  minWidth = 120,
}: DropdownProps<T>) {
  const [internalOpen, setInternalOpen] = useState(false);
  const [position, setPosition] = useState<{ top: number; left: number; width: number; openUp: boolean } | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const panelRef = useRef<HTMLDivElement>(null);

  const isControlled = controlledOpen !== undefined;
  const isOpen = isControlled ? controlledOpen : internalOpen;

  const setOpen = (open: boolean) => {
    if (isControlled) {
      onOpenChange?.(open);
    } else {
      setInternalOpen(open);
    }
  };

  const selectedArray = Array.isArray(value) ? value : [value];
  const isSelected = (v: T) => selectedArray.includes(v);

  // Get display label for trigger
  const getDisplayLabel = () => {
    if (mode === 'multi') {
      const count = selectedArray.length;
      return count === 0 ? placeholder : `${count} selected`;
    }
    const selected = items.find(i => i.value === value);
    return selected?.label || placeholder;
  };

  // Calculate position when opening
  useEffect(() => {
    if (isOpen && triggerRef.current) {
      const rect = triggerRef.current.getBoundingClientRect();
      const viewportHeight = window.innerHeight;
      const viewportWidth = window.innerWidth;
      const spaceBelow = viewportHeight - rect.bottom;
      const spaceAbove = rect.top;

      // Determine direction
      let openUp = side === 'top';
      if (side === 'auto') {
        openUp = spaceBelow < 200 && spaceAbove > spaceBelow;
      }

      // Calculate left position - align with trigger, but keep within viewport
      let left = rect.left;
      const panelWidth = Math.max(minWidth, rect.width);
      if (left + panelWidth > viewportWidth - 8) {
        left = viewportWidth - panelWidth - 8;
      }
      if (left < 8) {
        left = 8;
      }

      setPosition({
        top: openUp ? rect.top : rect.bottom + 4,
        left,
        width: rect.width,
        openUp,
      });
    }
  }, [isOpen, side, minWidth]);

  // Close on click outside
  useEffect(() => {
    if (!isOpen) return;

    const handleClickOutside = (e: MouseEvent) => {
      // Check immediately if click is inside trigger or panel
      const isInsideTrigger = triggerRef.current?.contains(e.target as Node);
      const isInsidePanel = panelRef.current?.contains(e.target as Node);

      if (isInsideTrigger || isInsidePanel) {
        return;
      }

      // Close asynchronously to allow any pending click handlers to fire
      requestAnimationFrame(() => setOpen(false));
    };

    const handleEscape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };

    document.addEventListener('mousedown', handleClickOutside);
    document.addEventListener('keydown', handleEscape);
    return () => {
      document.removeEventListener('mousedown', handleClickOutside);
      document.removeEventListener('keydown', handleEscape);
    };
  }, [isOpen]);

  const handleSelect = (itemValue: T, disabled?: boolean) => {
    if (disabled) return;
    if (mode === 'single') {
      onChange(itemValue);
      setOpen(false);
    } else {
      const newValue = isSelected(itemValue)
        ? selectedArray.filter(v => v !== itemValue)
        : [...selectedArray, itemValue];
      onChange(newValue as T[]);
    }
  };

  const itemSizeClasses = DROPDOWN_ITEM_SIZES[size] || DROPDOWN_ITEM_SIZES.default;

  // Default trigger button using Button component
  const defaultTrigger = (
    <Button
      ref={triggerRef}
      onClick={() => setOpen(!isOpen)}
      size={size}
      styleVariant={styleVariant}
      className={cn('justify-between text-left', className)}
      rightIcon={<ChevronDown className={cn(SIZE_CHECK[size], 'transition-transform', isOpen && 'rotate-180')} />}
    >
      <span className="truncate text-left">{getDisplayLabel()}</span>
    </Button>
  );

  // Custom trigger with ref forwarding
  const triggerElement = trigger ? (
    <div ref={triggerRef as any} onClick={() => setOpen(!isOpen)} className={cn('cursor-pointer', className)}>
      {trigger}
    </div>
  ) : defaultTrigger;

  return (
    <>
      {triggerElement}

      {isOpen && position && createPortal(
        <div
          ref={panelRef}
          className="fixed z-dropdown bg-bg-1 border border-border rounded-sm shadow-lg overflow-hidden animate-in fade-in-0 zoom-in-95 duration-100 pointer-events-auto font-title"
          style={{
            top: position.openUp ? 'auto' : position.top,
            bottom: position.openUp ? `calc(100vh - ${position.top}px + 4px)` : 'auto',
            left: position.left,
            minWidth: Math.max(minWidth, position.width),
          }}
          onPointerDown={(e) => e.stopPropagation()}
          onMouseDown={(e) => e.stopPropagation()}
        >
          {/* Items */}
          <div className="max-h-64 overflow-y-auto">
            {items.map(item => {
              const selected = isSelected(item.value);
              const disabled = item.disabled || false;

              const itemButton = (
                <button
                  onPointerDown={(e) => e.stopPropagation()}
                  onClick={(e) => {
                    e.stopPropagation();
                    handleSelect(item.value, disabled);
                  }}
                  disabled={disabled}
                  className={cn(
                    'w-full flex items-center transition-colors font-title font-medium',
                    itemSizeClasses.item,
                    !disabled && 'hover:bg-bg-2',
                    selected && !disabled && 'bg-bg-primary',
                    disabled && 'opacity-50 cursor-not-allowed'
                  )}
                >
                  {item.icon && (
                    isStringIcon(item.icon) ? (
                      <img src={item.icon} alt="" className={cn(itemSizeClasses.icon, 'rounded-xs shrink-0')} />
                    ) : (
                      <span className={cn('shrink-0', selected && !disabled ? 'text-primary' : 'text-muted-foreground')}>
                        {renderIcon(item.icon, itemSizeClasses.icon)}
                      </span>
                    )
                  )}
                  <span className={cn('flex-1 text-left', selected && !disabled && 'text-primary font-medium')}>
                    {item.label}
                  </span>
                  {selected && !disabled && <Check className={cn('shrink-0 text-primary', itemSizeClasses.check)} />}
                </button>
              );

              if (disabled && item.tooltip) {
                return (
                  <Tooltip key={String(item.value)} content={item.tooltip} side="left" asChild>
                    <div className="w-full">
                      {itemButton}
                    </div>
                  </Tooltip>
                );
              }

              return <div key={String(item.value)} className="w-full">{itemButton}</div>;
            })}
            {items.length === 0 && (
              <div className={cn('text-center text-muted-foreground', itemSizeClasses.item)}>
                No options
              </div>
            )}
          </div>

          {/* Footer */}
          {footer && (
            <>
              <div className="border-t border-border" />
              {footer}
            </>
          )}
        </div>,
        document.body
      )}
    </>
  );
}

// Convenience wrapper for toolbar-style dropdowns (like ChartToolbar)
interface ToolbarDropdownProps<T = string> extends Omit<DropdownProps<T>, 'trigger' | 'size'> {
  icon?: ComponentType<LucideProps>;
  label?: string;
  showChevron?: boolean;
  activeColor?: boolean;
}

export function ToolbarDropdown<T = string>({
  icon: Icon,
  label,
  showChevron = true,
  activeColor = false,
  value,
  items,
  ...props
}: ToolbarDropdownProps<T>) {
  const selectedArray = Array.isArray(value) ? value : [value];
  const hasSelection = selectedArray.length > 0 && selectedArray[0] !== undefined;

  return (
    <Dropdown
      {...props}
      value={value}
      items={items}
      size="sm"
      trigger={
        <div className="toolbar-item hover:bg-bg-3">
          {Icon && <Icon className={cn('w-4 h-4', activeColor && hasSelection && 'text-primary')} />}
          {label && <span className={cn(activeColor && hasSelection && 'text-primary')}>{label}</span>}
          {showChevron && <ChevronDown className="w-4 h-4" />}
        </div>
      }
    />
  );
}
