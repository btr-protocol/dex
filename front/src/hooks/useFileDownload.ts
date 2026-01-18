import { useCallback } from 'preact/hooks';
import { addNotification } from '@lib/notifications';

export function useFileDownload() {
  const download = useCallback((data: BlobPart[], filename: string, type = 'application/json') => {
    const blob = new Blob(data, { type });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
    addNotification('success', `Downloading ${filename}`);
  }, []);

  return { download };
}
