import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { ModalActions } from '@components/ui/ModalActions';
import { AlertTriangle } from 'lucide-react';

interface ExternalLinkModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  url: string;
  onConfirm: () => void;
}

export function ExternalLinkModal({ isOpen, onClose, url, onConfirm }: ExternalLinkModalProps) {
  const domain = url ? new URL(url).hostname : '';

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={(open) => !open && onClose(false)}
      title="External link"
      headerType="title"
      headerIcon={<AlertTriangle className="w-4 h-4 text-fg-2" />}
      maxWidth="max-w-sm"
      contrastHeader={false}
      footerControls={
        <ModalActions
          onCancel={() => onClose(false)}
          onConfirm={onConfirm}
          confirmLabel="Continue"
          className="flex-1"
        />
      }
    >
      <div className={`${MODAL_PADDING} py-4 space-y-2`}>
        <p className="text-sm text-muted-foreground">
          You're navigating to <span className="font-mono text-foreground">{domain}</span>
        </p>
        <p className="text-xs text-fg-3">
          BTR is not responsible for content or security of third-party sites.
        </p>
      </div>
    </BaseModal>
  );
}
