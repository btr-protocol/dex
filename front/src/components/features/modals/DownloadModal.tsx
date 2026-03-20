import { BaseModal, MODAL_PADDING } from '@components/ui/BaseModal';
import { Icon } from '@components/ui/Icon';

interface DownloadModalProps {
  isOpen: boolean;
  onClose: () => void;
  onCopy: () => void;
  onDownload: () => void;
  onEmail: () => void;
}

export function DownloadModal({ isOpen, onClose, onCopy, onDownload, onEmail }: DownloadModalProps) {
  const handleAction = (action: () => void) => {
    action();
    onClose();
  };

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={(open) => !open && onClose()}
      title="Download Notifications"
      headerType="title"
      maxWidth="max-w-sm"
    >
      <div className="divide-y divide-border">
        <button
          onClick={() => handleAction(onCopy)}
          className={`w-full flex items-center gap-3 ${MODAL_PADDING} py-3 hover:bg-bg-2 transition-colors`}
        >
          <Icon name="copy" className="w-5 h-5 text-fg-2" />
          <div className="flex-1 text-left">
            <div className="text-sm font-medium">Copy to Clipboard</div>
            <div className="text-xs text-muted-foreground">Copy notifications as JSON</div>
          </div>
        </button>

        <button
          onClick={() => handleAction(onDownload)}
          className={`w-full flex items-center gap-3 ${MODAL_PADDING} py-3 hover:bg-bg-2 transition-colors`}
        >
          <Icon name="download" className="w-5 h-5 text-fg-2" />
          <div className="flex-1 text-left">
            <div className="text-sm font-medium">Download as JSON</div>
            <div className="text-xs text-muted-foreground">Save as btr-logs.json</div>
          </div>
        </button>

        <button
          onClick={() => handleAction(onEmail)}
          className={`w-full flex items-center gap-3 ${MODAL_PADDING} py-3 hover:bg-bg-2 transition-colors`}
        >
          <Icon name="envelope" className="w-5 h-5 text-fg-2" />
          <div className="flex-1 text-left">
            <div className="text-sm font-medium">Email Report</div>
            <div className="text-xs text-muted-foreground">Send to tech@btr.supply</div>
          </div>
        </button>
      </div>
    </BaseModal>
  );
}
