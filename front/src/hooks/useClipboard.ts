import { useState, useCallback } from 'preact/hooks';
import { addNotification } from '@lib/notifications';

export function useClipboard() {
  const [copied, setCopied] = useState(false);

  const copy = useCallback(async (text: string, successMessage?: string) => {
    try {
      await navigator.clipboard.writeText(text);
      if (successMessage) {
        addNotification('success', successMessage);
      }
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
      return true;
    } catch (error) {
      console.error('Failed to copy to clipboard:', error);
      return false;
    }
  }, []);

  return { copy, copied };
}
