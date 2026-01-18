import { useCallback } from 'preact/hooks';

export function useEmail() {
  const openEmail = useCallback((recipient: string, subject: string, body: string) => {
    const mailto = `mailto:${recipient}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
    window.location.href = mailto;
  }, []);

  return { openEmail };
}
