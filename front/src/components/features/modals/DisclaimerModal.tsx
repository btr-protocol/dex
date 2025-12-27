import { useEffect, useState } from 'preact/hooks';
import { Dialog, DialogContent } from '@components/ui/Dialog';
import { Button } from '@components/ui/Button';
import { Icon } from '@components/ui/Icon';

const DISCLAIMER_KEY = 'btr-disclaimer-accepted';

interface DisclaimerModalProps {
  onAccept: () => void;
}

export function DisclaimerModal({ onAccept }: DisclaimerModalProps) {
  const [content, setContent] = useState<string>('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Load Risk Disclaimer markdown
    fetch('/legal/Risk Disclaimer.md')
      .then(res => res.text())
      .then(text => {
        setContent(text);
        setLoading(false);
      })
      .catch(err => {
        console.error('Failed to load disclaimer:', err);
        setContent('# Error\nFailed to load disclaimer content.');
        setLoading(false);
      });
  }, []);

  const handleAccept = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    onAccept();
  };

  const handleBack = () => {
    window.history.back();
  };

  // Convert markdown to HTML (simple implementation)
  const renderMarkdown = (md: string) => {
    return md
      .split('\n')
      .map((line, i) => {
        // Headers
        if (line.startsWith('# ')) {
          return <h1 key={i} className="text-3xl font-bold mt-6 mb-4">{line.slice(2)}</h1>;
        }
        if (line.startsWith('## ')) {
          return <h2 key={i} className="text-2xl font-bold mt-5 mb-3">{line.slice(3)}</h2>;
        }
        if (line.startsWith('### ')) {
          return <h3 key={i} className="text-xl font-semibold mt-4 mb-2">{line.slice(4)}</h3>;
        }
        // Italic
        if (line.startsWith('*') && line.endsWith('*') && !line.startsWith('**')) {
          return <p key={i} className="text-gray-400 italic mb-2">{line.slice(1, -1)}</p>;
        }
        // Lists
        if (line.startsWith('- ')) {
          return <li key={i} className="ml-6 mb-1">{line.slice(2)}</li>;
        }
        // Links
        const linkRegex = /\[([^\]]+)\]\(([^)]+)\)/g;
        const hasLink = linkRegex.test(line);
        if (hasLink) {
          const parts = line.split(linkRegex);
          return (
            <p key={i} className="mb-2">
              {parts.map((part, j) => {
                if (j % 3 === 1) {
                  return <a key={j} href={parts[j + 1]} className="text-primary hover:underline">{part}</a>;
                }
                if (j % 3 === 2) return null;
                return part;
              })}
            </p>
          );
        }
        // Empty lines
        if (line.trim() === '') {
          return <div key={i} className="h-2" />;
        }
        // Regular paragraphs
        return <p key={i} className="mb-2">{line}</p>;
      });
  };

  return (
    <Dialog open={true} onOpenChange={() => {}}>
      <DialogContent className="max-w-4xl max-h-[90vh] overflow-hidden flex flex-col p-0">
        {/* Logo Header */}
        <div className="w-full h-20 flex items-center justify-center border-b border-border bg-card">
          <div className="text-4xl font-black tracking-tight">
            <span className="text-white">BTR</span>
          </div>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto px-8 py-6">
          {loading ? (
            <div className="flex items-center justify-center h-full">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary"></div>
            </div>
          ) : (
            <div className="prose prose-invert max-w-none">
              {renderMarkdown(content)}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="border-t border-border px-8 py-4 bg-card">
          <div className="flex items-center justify-between">
            {/* Social Links */}
            <div className="flex gap-4">
              <a
                href="https://github.com/btr-markets"
                target="_blank"
                rel="noopener noreferrer"
                className="text-gray-400 hover:text-white transition-colors"
                title="GitHub"
              >
                <Icon name="github-logo" className="w-6 h-6" />
              </a>
              <a
                href="https://twitter.com/btr_markets"
                target="_blank"
                rel="noopener noreferrer"
                className="text-gray-400 hover:text-white transition-colors"
                title="Twitter"
              >
                <Icon name="twitter-logo" className="w-6 h-6" />
              </a>
              <a
                href="https://t.me/btrsupply"
                target="_blank"
                rel="noopener noreferrer"
                className="text-gray-400 hover:text-white transition-colors"
                title="Telegram"
              >
                <Icon name="paper-plane" className="w-6 h-6" />
              </a>
            </div>

            {/* Action Buttons */}
            <div className="flex gap-3">
              <Button variant="outlined" onClick={handleBack}>
                Back
              </Button>
              <Button variant="primary" onClick={handleAccept}>
                Accept
              </Button>
            </div>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

export function useDisclaimer() {
  const [accepted, setAccepted] = useState(false);

  useEffect(() => {
    const disclaimerAccepted = localStorage.getItem(DISCLAIMER_KEY) === 'true';
    setAccepted(disclaimerAccepted);
  }, []);

  const accept = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    setAccepted(true);
  };

  return { accepted, accept };
}
