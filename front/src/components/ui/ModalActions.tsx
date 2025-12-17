import { Button } from './Button';
import { cn } from '@utils/cn';

interface ModalActionsProps {
  onCancel?: () => void;
  onConfirm?: () => void;
  cancelLabel?: string;
  confirmLabel?: string;
  confirmDisabled?: boolean;
  confirmVariant?: 'primary' | 'secondary' | 'outlined';
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
    <Button styleVariant="outlined" onClick={onCancel}>
      {cancelLabel}
    </Button>
  );

  const confirmButton = onConfirm && (
    <Button
      styleVariant={confirmVariant}
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
