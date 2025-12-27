import { useState, useEffect } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { Checkbox } from '@components/ui/Checkbox';
import { MaskIcon } from '@components/ui/MaskIcon';
import { MarkdownRenderer } from '@components/features/docs';
import { useExternalLink } from '@lib/external-links';
import { socialLinks } from '@/constants/navigation';

const DISCLAIMER_KEY = 'btr-disclaimer-accepted';
const DISCLAIMER_EXPIRY_KEY = 'btr-disclaimer-expiry';
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

interface DisclaimerPageProps {
  onAccept: () => void;
}

export function DisclaimerPage({ onAccept }: DisclaimerPageProps) {
  const [hideFor30Days, setHideFor30Days] = useState(false);
  const { openExternalLink } = useExternalLink();

  const handleAccept = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    if (hideFor30Days) {
      localStorage.setItem(DISCLAIMER_EXPIRY_KEY, String(Date.now() + THIRTY_DAYS_MS));
    }
    onAccept();
  };

  return (
    <div
      style={{
        position: 'relative',
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        padding: '2rem 1rem',
        overflow: 'auto',
        zIndex: 10,
      }}
    >
      {/* Logo */}
      <div style={{ marginBottom: '3rem', marginTop: '1rem' }}>
        <MaskIcon
          src="/brand/logo.svg"
          size={64}
          color="var(--fg-1)"
        />
      </div>

      {/* Content Box - Blur background with border */}
      <div
        className="w-full max-w-4xl border border-border rounded-xs backdrop-blur-md max-h-[50vh] overflow-y-auto mb-3"
        style={{ backgroundColor: 'rgba(27, 27, 27, 0.3)' }}
      >
        <div className="p-6">
          <MarkdownRenderer
            content=""
            slug="risk-disclaimer"
            className="text-sm"
          />
        </div>
      </div>

      {/* Actions Row - Checkbox + Button + Social Icons aligned */}
      <div style={{ width: '100%', maxWidth: '56rem', display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: '1.5rem', marginBottom: '1rem' }}>
        {/* Social Icons - Left aligned */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '1.5rem' }}>
          {socialLinks.map((link) => (
            <Button
              key={link.title}
              variant="ghost"
              size="sm"
              onClick={() => openExternalLink(link.path)}
              className="p-2"
              aria-label={link.title}
            >
              <MaskIcon src={link.icon!} size={20} color="var(--fg-2)" />
            </Button>
          ))}
        </div>

        {/* Controls - Right aligned */}
        <div style={{ display: 'flex', alignItems: 'center', gap: '1.5rem' }}>
          <label
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: '0.75rem',
              cursor: 'pointer',
            }}
          >
            <Checkbox
              checked={hideFor30Days}
              onCheckedChange={(checked) => setHideFor30Days(checked === true)}
            />
            <span style={{ color: 'var(--fg-2)', fontSize: '0.875rem' }}>Hide for 30 days</span>
          </label>

          <Button
            variant="primary"
            size="default"
            onClick={handleAccept}
          >
            Proceed
          </Button>
        </div>
      </div>
    </div>
  );
}

export function useDisclaimer() {
  const [accepted, setAccepted] = useState(false);

  useEffect(() => {
    const disclaimerAccepted = localStorage.getItem(DISCLAIMER_KEY) === 'true';
    const expiryStr = localStorage.getItem(DISCLAIMER_EXPIRY_KEY);

    if (disclaimerAccepted) {
      // Check if there's an expiry and if it has passed
      if (expiryStr) {
        const expiry = parseInt(expiryStr, 10);
        if (Date.now() > expiry) {
          // Expired, clear and show disclaimer again
          localStorage.removeItem(DISCLAIMER_KEY);
          localStorage.removeItem(DISCLAIMER_EXPIRY_KEY);
          setAccepted(false);
          return;
        }
      }
      setAccepted(true);
    }
  }, []);

  const accept = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    setAccepted(true);
  };

  return { accepted, accept };
}
