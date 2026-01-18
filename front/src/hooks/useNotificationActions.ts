import { useCallback } from 'preact/hooks';
import { addNotification } from '@lib/notifications';

export function useNotificationActions() {
  const copy = useCallback((data: unknown, successMessage?: string) => {
    const text = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    navigator.clipboard.writeText(text);
    if (successMessage) addNotification('success', successMessage);
  }, []);

  const download = useCallback((data: unknown, filename: string) => {
    const text = typeof data === 'string' ? data : JSON.stringify(data, null, 2);
    const blob = new Blob([text], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
    URL.revokeObjectURL(url);
  }, []);

  const report = useCallback((data: unknown, recipient = 'tech@btr.supply') => {
    const subject = encodeURIComponent('Log Report');
    const body = encodeURIComponent(typeof data === 'string' ? data : JSON.stringify(data, null, 2));
    window.location.href = `mailto:${recipient}?subject=${subject}&body=${body}`;
  }, []);

  return { copy, download, report };
}
