import { useState } from 'preact/hooks';
import { useRouter } from '@lib/router';
import { useExternalLink } from '@lib/external-links';
import { useHealthMonitor } from '@hooks/useHealthMonitor';
import { useWallet } from '@lib/wallet';
import { getChain } from '@sdk/eth';
import { HealthPopover } from '@components/shared/metrics';
import { MaskIcon } from '@components/ui/MaskIcon';
import { Tooltip } from '@components/ui/Tooltip';
import { footerNavigation } from '@/constants/navigation';

function StatusBeacon({ status }: { status: 'healthy' | 'degraded' | 'down' }) {
  const color = status === 'healthy' ? 'var(--green)' : status === 'degraded' ? 'var(--yellow)' : 'var(--red)';

  return (
    <div className="relative w-3 h-3 shrink-0">
      {/* Pulsing animation */}
      <div
        className="absolute inset-0 rounded-full animate-ping opacity-75"
        style={{ backgroundColor: color }}
      />
      {/* Static dot */}
      <div
        className="absolute inset-0 rounded-full"
        style={{ backgroundColor: color }}
      />
    </div>
  );
}

function getStatusColor(status: 'healthy' | 'degraded' | 'down'): string {
  return status === 'healthy' ? 'var(--green)' : status === 'degraded' ? 'var(--yellow)' : 'var(--red)';
}

export function Footer() {
  const { navigate } = useRouter();
  const { openExternalLink } = useExternalLink();
  const { chainId } = useWallet();
  const health = useHealthMonitor();
  const currentYear = new Date().getFullYear();
  const [logoHover, setLogoHover] = useState(false);

  const chainName = chainId ? getChain(chainId)?.name || 'Ethereum' : 'Ethereum';

  const handleScrollTop = () => {
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  const handleSocialClick = (link: typeof footerNavigation.social[0]) => {
    if (link.isExternal) {
      openExternalLink(link.path);
    } else {
      navigate(link.path);
    }
  };

  return (
    <footer className="fixed bottom-0 w-full h-10 flex items-center z-50 font-light text-sm">
      <nav className="px-3 max-w-7xl h-full mx-auto flex items-center justify-between border border-b-0 rounded-t-lg backdrop-blur-md bg-bg-0/80 border-border w-full">
        {/* Left: Social Links + Health Status */}
        <div className="flex items-center gap-3">
          {/* Social Links */}
          <div className="flex items-center gap-1">
            {footerNavigation.social.map((link) => (
              <Tooltip key={link.title} content={link.description || link.title} side="top">
                <button
                  onClick={() => handleSocialClick(link)}
                  aria-label={link.title}
                  className="p-1 hover:opacity-80 transition-opacity"
                >
                  <MaskIcon src={link.icon!} size={20} color="var(--fg-3)" className="hover:brightness-125" />
                </button>
              </Tooltip>
            ))}
          </div>

          {/* Health Status Popover */}
          <HealthPopover api={health.api} static={health.static} rpc={health.rpc} chainName={chainName}>
            <button className="flex items-center gap-1.5 text-xs transition-colors font-mono">
              <StatusBeacon status={health.api.status} />
              <span style={{ color: getStatusColor(health.api.status) }}>
                {health.api.latency !== null ? `${health.api.latency}ms` : '—'}
              </span>
            </button>
          </HealthPopover>
        </div>

        {/* Right: Legal Links + Copyright + Logo */}
        <div className="flex items-center gap-4">
          {/* Legal Links - ToS and Disclaimer only */}
          {footerNavigation.legal.map((route) => (
            <button
              key={route.title}
              onClick={() => navigate(route.path)}
              className="text-fg-2 pt-0.5 hover:text-foreground transition-colors"
            >
              {route.title}
            </button>
          ))}

          {/* Copyright */}
          <button
            className="text-fg-2 pt-0.5 cursor-pointer hover:text-foreground font-title"
            onClick={handleScrollTop}
          >
            © {currentYear}
          </button>

          {/* Logo */}
          <button
            className="cursor-pointer"
            onClick={handleScrollTop}
            onMouseEnter={() => setLogoHover(true)}
            onMouseLeave={() => setLogoHover(false)}
          >
            <MaskIcon
              src="/brand/logo.svg"
              width="5rem"
              height="1.8rem"
              color={logoHover ? 'var(--fg-1)' : 'var(--fg-3)'}
              aria-label="Logo"
              className="transition-all duration-200"
            />
          </button>
        </div>
      </nav>
    </footer>
  );
}
