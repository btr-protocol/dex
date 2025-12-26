import { Button } from './Button';
import { cn } from '@utils/cn';

interface ModalActionsProps {
  onCancel?: () => void;
  onConfirm?: () => void;
  cancelLabel?: string;
  confirmLabel?: string;
  confirmDisabled?: boolean;
  confirmVariant?: 'primary' | 'secondary' | 'outlined' | 'glass' | 'default' | 'ghost';
  className?: string;
  reverseOrder?: boolean;
}

export function ModalActions({
  onCancel,
  onConfirm,
  cancelLabel = 'Cancel',
  confirmLabel = 'Confirm',
  confirmDisabled = false,
  confirmVariant = 'primary',
  className,
  reverseOrder = false,
}: ModalActionsProps) {
  const cancelButton = onCancel && (
    <Button variant="outlined" onClick={onCancel}>
      {cancelLabel}
    </Button>
  );

  const confirmButton = onConfirm && (
    <Button
      variant={confirmVariant as any}
      onClick={onConfirm}
      disabled={confirmDisabled}
    >
      {confirmLabel}
    </Button>
  );

  return (
    <div className={cn('flex gap-2 justify-end', className)}>
      {reverseOrder ? (
        <>
          {confirmButton}
          {cancelButton}
        </>
      ) : (
        <>
          {cancelButton}
          {confirmButton}
        </>
      )}
    </div>
  );
}