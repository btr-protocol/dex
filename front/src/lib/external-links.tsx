import { createContext } from 'preact';
import { useContext, useState } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';
import { ExternalLinkModal } from '@components/ExternalLinkModal';

const ExternalLinkCtx = createContext<{ openExternalLink: (url: string) => void }>({ openExternalLink: () => {} });

export function ExternalLinkProvider({ children }: { children: ReactNode }) {
  const [url, setUrl] = useState<string | null>(null);

  const open = (target: string) => {
    try {
      const targetUrl = new URL(target, window.location.origin);
      const isInternal = targetUrl.hostname === window.location.hostname;

      if (!isInternal) {
        setUrl(target);
      } else {
        window.open(target, '_blank', 'noopener,noreferrer');
      }
    } catch { console.warn('Invalid URL', target); }
  };

  return (
    <ExternalLinkCtx.Provider value={{ openExternalLink: open }}>
      {children}
      <ExternalLinkModal
        isOpen={!!url}
        url={url || ''}
        onClose={() => setUrl(null)}
        onConfirm={() => { window.open(url!, '_blank', 'noopener,noreferrer'); setUrl(null); }}
      />
    </ExternalLinkCtx.Provider>
  ) as JSX.Element;
}

export const useExternalLink = () => useContext(ExternalLinkCtx);
