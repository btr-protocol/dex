import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { ModalActions } from '@components/ui/ModalActions';
import { Icon } from '@components/ui/Icon';

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
      headerIcon={<Icon name="warning" className="w-4 h-4 text-fg-2" />}
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
      <div className={`${MODAL_PADDING} py-4 text-sm text-fg-1`}>
        <p>
          You're navigating to <span className="pl-1.5 font-mono text-foreground">{domain}</span>
        </p>
        <p className="mt-0">
          BTR is not responsible for content or security of third-party sites.
        </p>
      </div>
    </BaseModal>
  );
}
