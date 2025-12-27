import { WalletProvider } from '@lib/wallet';
import { RouterProvider, useRouter } from '@lib/router';
import { ThemeProvider } from '@lib/theme';
import { SettingsProvider } from '@lib/settings';
import { ExternalLinkProvider } from '@lib/external-links';
import { enableConsoleIntegration, addNotification } from '@lib/notifications';
import { Notifications } from '@components/Notifications';
import { BgRenderer } from '@components/BgRenderer';
import { Header } from '@/components/layout/Header';
import { Footer } from '@/components/layout/Footer';
import { DisclaimerPage, useDisclaimer } from '@/pages/DisclaimerPage';
import { useEffect, useState } from 'preact/hooks';
import { ROUTES } from '@/constants/navigation';

// Lazy loading helper for route pages
function LazyPage({ load, componentName = 'default' }: { load: () => Promise<any>; componentName?: string }) {
  const [Component, setComponent] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let active = true;
    load().then(mod => {
      if (active) {
        const comp = componentName === 'default' ? mod.default : mod[componentName];
        setComponent(() => comp);
        setLoading(false);
      }
    }).catch(e => {
      if (active) {
        console.error('Failed to load page:', e);
        setLoading(false);
      }
    });
    return () => { active = false; };
  }, [load, componentName]);

  if (loading) return <div className="flex-center min-h-screen"><div className="animate-spin">Loading...</div></div>;
  if (!Component) return <div className="flex-center min-h-screen text-red-500">Failed to load page</div>;
  return <Component />;
}

// Memoized lazy loaders to prevent recreating on each render
const SwapPageLazy = () => <LazyPage load={() => import('@/pages/SwapPage')} componentName="SwapPage" />;
const EarnPageLazy = () => <LazyPage load={() => import('@/pages/EarnPage')} componentName="EarnPage" />;
const VotePageLazy = () => <LazyPage load={() => import('@/pages/VotePage')} componentName="VotePage" />;
const MetricsPageLazy = () => <LazyPage load={() => import('@/pages/MetricsPage')} componentName="MetricsPage" />;
const AddAssetPageLazy = () => <LazyPage load={() => import('@/pages/AddAssetPage')} componentName="AddAssetPage" />;
const DocsPageLazy = () => <LazyPage load={() => import('@/pages/DocsPage')} componentName="DocsPage" />;
const ChartPageLazy = () => <LazyPage load={() => import('@/pages/ChartPage')} componentName="ChartPage" />;

// Detect if user agent is a bot/crawler
function isBot(): boolean {
  if (typeof navigator === 'undefined') return true;
  const botPattern = /(bot|crawler|spider|crawling|googlebot|bingbot|slurp|duckduckbot|baiduspider|yandexbot|facebookexternalhit|twitterbot|rogerbot|linkedinbot|embedly|quora|showyoubot|outbrain|pinterest|slackbot|vkshare|w3c_validator|whatsapp)/i;
  return botPattern.test(navigator.userAgent);
}

function AppContent() {
  const { accepted: disclaimerAccepted, accept: acceptDisclaimer } = useDisclaimer();
  const { path } = useRouter();
  const [shouldRenderBackground, setShouldRenderBackground] = useState(true);

  useEffect(() => {
    // Check if user is a bot - skip background rendering for bots
    if (isBot()) {
      setShouldRenderBackground(false);
    }
  }, []);

  useEffect(() => {
    // Enable console integration
    enableConsoleIntegration();

    // Show welcome notification
    if (disclaimerAccepted) {
      addNotification('info', 'This app stores no cookies nor tracks your data. Stay safe, anon.');
    }
  }, [disclaimerAccepted]);

  const renderPage = () => {
    // Chart page is standalone - no header/footer/disclaimer
    if (path === ROUTES.CHART) {
      return <ChartPageLazy />;
    }

    if (path === ROUTES.DOCS || path.startsWith(ROUTES.DOCS + '/')) {
      // DocsPageLazy handles slug extraction from path
      return <DocsPageLazy />;
    }

    switch (path) {
      case ROUTES.HOME:
      case ROUTES.SWAP:
        return <SwapPageLazy />;
      case ROUTES.EARN:
        return <EarnPageLazy />;
      case ROUTES.VOTE:
        return <VotePageLazy />;
      case ROUTES.METRICS:
        return <MetricsPageLazy />;
      case ROUTES.ADD_ASSET:
        return <AddAssetPageLazy />;
      default:
        return <SwapPageLazy />;
    }
  };

  // Chart route renders standalone without shell
  if (path === ROUTES.CHART) {
    return <ChartPageLazy />;
  }

  return (
    <div className="min-h-screen bg-background text-foreground flex flex-col relative">
      {shouldRenderBackground && <BgRenderer />}

      {!disclaimerAccepted ? (
        <DisclaimerPage onAccept={acceptDisclaimer} />
      ) : (
        <>
          <Header />
          <main className="flex-1 relative z-10 pt-12 pb-10">
            {renderPage()}
          </main>
          <Footer />
        </>
      )}

      <Notifications />
    </div>
  );
}

export default function App() {
  return (
    <ThemeProvider>
      <SettingsProvider>
        <ExternalLinkProvider>
          <WalletProvider>
            <RouterProvider>
              <AppContent />
            </RouterProvider>
          </WalletProvider>
        </ExternalLinkProvider>
      </SettingsProvider>
    </ThemeProvider>
  );
}
