import { useState, useEffect } from 'preact/hooks';
import { Button } from '@components/ui/Button';
import { Checkbox } from '@components/ui/Checkbox';
import { MultiInput } from '@components/ui/MultiInput';
import { MarkdownRenderer } from '@components/features/docs';
import { MaskIcon } from '@components/ui/MaskIcon';
import { Tooltip } from '@components/ui/FloatingPanel';
import { useWallet } from '@lib/wallet';
import { useAuth, checkInvite, signDisclaimer, needsDisclaimerSignature, formatSimpleMessage, generateSIWEMessage } from '@lib/auth';
import { addNotification } from '@lib/notifications';
import { useExternalLink } from '@lib/external-links';
import { socialLinks } from '@/constants/navigation';

const DISCLAIMER_KEY = 'btr-disclaimer-accepted';
const DISCLAIMER_EXPIRY_KEY = 'btr-disclaimer-expiry';
const THIRTY_DAYS_MS = 30 * 24 * 60 * 60 * 1000;

interface DisclaimerPageProps {
  onAccept: () => void;
}

export function DisclaimerPage({ onAccept }: DisclaimerPageProps) {
  const { address, sign, connect } = useWallet();
  const { user, checkSession, isLoading: authLoading } = useAuth();
  const { openExternalLink } = useExternalLink();
  const [showDisclaimer, setShowDisclaimer] = useState(true);
  const [showGuardInput, setShowGuardInput] = useState(false);
  const [inviteCode, setInviteCode] = useState(['', '', '', '', '']);
  const [inviteCodeError, setInviteCodeError] = useState<string | null>(null);
  const [rememberFor30Days, setRememberFor30Days] = useState(false);
  const [authenticating, setAuthenticating] = useState(false);
  const [signingDisclaimer, setSigningDisclaimer] = useState(false);
  const [hasScrolledToBottom, setHasScrolledToBottom] = useState(false);

  // Check if user has valid disclaimer signature on mount
  useEffect(() => {
    if (user && !needsDisclaimerSignature(user)) {
      // Backend says disclaimer is valid, skip UI disclaimer
      setShowDisclaimer(false);
      if (import.meta.env.VITE_GUARDED === 'true') {
        setShowGuardInput(true);
      }
    }
  }, [user]);

  // Step 1: UI Disclaimer (local storage only, no signature)
  const handleAcceptUIDisclaimer = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    const expiryMs = rememberFor30Days ? THIRTY_DAYS_MS : 24 * 60 * 60 * 1000;
    localStorage.setItem(DISCLAIMER_EXPIRY_KEY, String(Date.now() + expiryMs));
    addNotification('success', 'Terms accepted. Proceed to enter.');
    setShowDisclaimer(false);
  };

  const handleVerifyCode = async () => {
    const codeString = inviteCode.join('');
    if (codeString.length !== 6) {
      setInviteCodeError('Please enter all 6 characters');
      return;
    }

    setInviteCodeError(null);

    // Only check if invite code is valid, don't authenticate yet
    const checkResult = await checkInvite(codeString);

    if (!checkResult.valid) {
      setInviteCodeError(checkResult.message || 'Invalid invite code. Please try again.');
      return;
    }

    // Show wallet connect buttons
    setShowGuardInput(true);
    addNotification('success', 'Invite verified! Connect wallet to continue.');
  };

  const handleConnect = async () => {
    try {
      await connect();
    } catch (err) {
      setInviteCodeError(err instanceof Error ? err.message : 'Failed to connect wallet');
    }
  };

  const handleCodeChange = (values: string[]) => {
    setInviteCode(values);
    setInviteCodeError(null);
  };

  const handleEnterWithWallet = async () => {
    if (!address) {
      setInviteCodeError('Please connect wallet first');
      return;
    }

    // Check if user needs to sign disclaimer
    const needsSignature = user ? needsDisclaimerSignature(user) : true;
    if (needsSignature) {
      // Prompt to sign disclaimer first
      setSigningDisclaimer(true);
      const siweMsg = generateSIWEMessage(address);
      const message = formatSimpleMessage(siweMsg);
      try {
        const signature = await sign(message);
        const result = await signDisclaimer(address, signature);
        if (result.success) {
          await checkSession();
          setSigningDisclaimer(false);
          addNotification('success', 'Disclaimer signed! Welcome.');
          onAccept();
        } else {
          setInviteCodeError(result.message || 'Failed to sign disclaimer');
          setSigningDisclaimer(false);
        }
      } catch (err) {
        setInviteCodeError(err instanceof Error ? err.message : 'Failed to sign disclaimer');
        setSigningDisclaimer(false);
      }
      return;
    }

    // Already signed, just authenticate with invite
    setAuthenticating(true);
    const codeString = inviteCode.join('');
    const siweMsg = generateSIWEMessage(address);
    const message = formatSimpleMessage(siweMsg);
    try {
      const signature = await sign(message);
      // This will create user and set them as invited
      const result = await fetch(`${import.meta.env.VITE_AUTH_API || 'http://localhost:4001'}/api/auth/invite`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          inviteCode: codeString,
          signature,
          message,
          address: address.toLowerCase(),
        }),
      });
      const data = await result.json();
      if (result.ok) {
        await checkSession();
        addNotification('success', 'Welcome! You can now access the app.');
        onAccept();
      } else {
        setInviteCodeError(data.message || 'Authentication failed');
      }
    } catch (err) {
      setInviteCodeError(err instanceof Error ? err.message : 'Failed to authenticate');
    }
    setAuthenticating(false);
  };

  const shortAddress = address ? `${address.slice(0, 6)}...${address.slice(-4)}` : '';

  return (
    <div className="relative flex-1 flex flex-col items-center justify-center p-[2rem_1rem] overflow-auto z-10">
      <div className="w-full max-w-2xl">
        {/* Logo - Left aligned */}
        <div className="mb-3">
          <MaskIcon
            src="/brand/logo.svg"
            width="14rem"
            height="4rem"
            className="text-foreground"
            color="var(--fg-0)"
          />
        </div>

        {/* Content Box - Blur background with border */}
        <div className="w-full max-w-4xl border border-border rounded-md backdrop-blur-md max-h-[50vh] min-h-[20rem] mb-3 flex flex-col relative overflow-hidden">
          {/* Step 1: UI Disclaimer (local storage only) */}
          {showDisclaimer ? (
            <MarkdownRenderer
              slug="risk-disclaimer"
              className="text-sm text-fg-2 p-6 pb-4"
              maxHeight="50vh"
              onScrollToBottom={setHasScrolledToBottom}
              footerSlot={
                <label className="flex items-center gap-3 cursor-pointer pt-4 mt-4 border-t border-border/50">
                  <Checkbox
                    checked={rememberFor30Days}
                    onCheckedChange={(checked) => setRememberFor30Days(checked === true)}
                  />
                  <span className="text-fg-2 text-sm">
                    Remember for 30 days
                  </span>
                </label>
              }
            />
          ) : (
            <>
              {/* Step 2: Invite code (if guarded) */}
              <h1 className="text-3xl font-bold text-fg-2 text-center">
                {import.meta.env.VITE_GUARDED === 'true' ? 'Guarded Launch' : 'Enter Invite Code'}
              </h1>

              {/* Invite code input - XXX-XXX format */}
              <div className="flex justify-center">
                <MultiInput
                  length={6}
                  separator={<span className="text-fg-2 text-xl">-</span>}
                  value={inviteCode}
                  onChange={handleCodeChange}
                  disabled={authLoading || inviteCodeError !== null}
                  error={!!inviteCodeError}
                />
              </div>
              <p className="text-base text-fg-2 text-center">
                Enter your invite code to proceed
              </p>
            </>
          )}
        </div>

        {/* Actions Row - Social Links + Buttons */}
        <div className="w-full flex justify-between items-center gap-2">
          {/* Social Icons - Left aligned */}
          <div className="flex items-center gap-4">
            {socialLinks.map((link) => (
              <Tooltip key={link.title} content={link.title} side="top" arrow>
                <MaskIcon
                  src={link.icon!}
                  size={40}
                  color="var(--fg-3)"
                  hoverColor="var(--fg-2)"
                  onClick={() => openExternalLink(link.path)}
                  aria-label={link.title}
                />
              </Tooltip>
            ))}
          </div>

          {/* Controls - Right aligned */}
          <div className="flex items-center gap-2">
            {showDisclaimer ? (
              <Button
                variant="primary"
                size="lg"
                onClick={handleAcceptUIDisclaimer}
                disabled={!hasScrolledToBottom}
              >
                Agree & Continue
              </Button>
            ) : import.meta.env.VITE_GUARDED === 'true' ? (
              <>
                {!address ? (
                  <Button
                    variant="primary"
                    size="lg"
                    onClick={handleConnect}
                    disabled={authLoading}
                  >
                    Connect to Enter
                  </Button>
                ) : (
                  <>
                    <Button
                      variant="primary"
                      size="default"
                      onClick={handleEnterWithWallet}
                      disabled={authenticating || signingDisclaimer}
                    >
                      {signingDisclaimer ? 'Signing...' :
                        authenticating ? 'Verifying...' :
                          `Enter with ${shortAddress}`
                      }
                    </Button>
                    <Button
                      variant="outlined"
                      size="default"
                      onClick={handleConnect}
                    >
                      Change Wallet
                    </Button>
                  </>
                )}
              </>
            ) : (
              <Button
                variant="primary"
                size="default"
                onClick={handleAcceptUIDisclaimer}
              >
                Enter App
              </Button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

export function useDisclaimer() {
  const [accepted, setAccepted] = useState(false);
  const isGuarded = import.meta.env.VITE_GUARDED === 'true';

  useEffect(() => {
    const disclaimerAccepted = localStorage.getItem(DISCLAIMER_KEY) === 'true';
    const expiryStr = localStorage.getItem(DISCLAIMER_EXPIRY_KEY);

    if (disclaimerAccepted) {
      if (expiryStr) {
        const expiry = parseInt(expiryStr, 10);
        if (Date.now() > expiry) {
          localStorage.removeItem(DISCLAIMER_KEY);
          localStorage.removeItem(DISCLAIMER_EXPIRY_KEY);
          setAccepted(false);
        }
      }
    } else if (isGuarded) {
      setAccepted(false);
    }
  }, [isGuarded]);

  const accept = () => {
    localStorage.setItem(DISCLAIMER_KEY, 'true');
    localStorage.setItem(DISCLAIMER_EXPIRY_KEY, String(Date.now() + THIRTY_DAYS_MS));
    setAccepted(true);
  };

  return { accepted, accept };
}
