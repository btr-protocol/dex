import { WalletProvider } from '@lib/wallet';
import { RouterProvider, useRouter } from '@lib/router';
import { ThemeProvider } from '@lib/theme';
import { SettingsProvider } from '@lib/settings';
import { ExternalLinkProvider } from '@lib/external-links';
import { enableConsoleIntegration, addNotification } from '@lib/notifications';
import { Notifications } from '@components/Notifications';
import { BgRenderer } from '@components/BgRenderer';
import Header from '@/components/layout/Header';
import Footer from '@/components/layout/Footer';
import DisclaimerPage, { useDisclaimer } from '@/pages/DisclaimerPage';
import { useEffect, lazy, Suspense, useState } from 'react';
import { ROUTES } from '@/constants/navigation';

// Lazy load all route pages
const SwapPage = lazy(() => import('@/pages/SwapPage'));
const EarnPage = lazy(() => import('@/pages/EarnPage'));
const VotePage = lazy(() => import('@/pages/VotePage'));
const MetricsPage = lazy(() => import('@/pages/MetricsPage'));
const AddAssetPage = lazy(() => import('@/pages/AddAssetPage'));
const DocsPage = lazy(() => import('@/pages/DocsPage'));
const ChartPage = lazy(() => import('@/pages/ChartPage'));

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
      return <ChartPage />;
    }

    if (path === ROUTES.DOCS || path.startsWith(ROUTES.DOCS + '/')) {
      // Extract slug from path like /docs/1.1.6-Toxic-Flow-Mitigation
      const slug = path === ROUTES.DOCS
        ? 'overview'
        : path.replace(ROUTES.DOCS + '/', '').toLowerCase();
      return <DocsPage slug={slug} />;
    }

    switch (path) {
      case ROUTES.HOME:
      case ROUTES.SWAP:
        return <SwapPage />;
      case ROUTES.EARN:
        return <EarnPage />;
      case ROUTES.VOTE:
        return <VotePage />;
      case ROUTES.METRICS:
        return <MetricsPage />;
      case ROUTES.ADD_ASSET:
        return <AddAssetPage />;
      default:
        return <SwapPage />;
    }
  };

  // Chart route renders standalone without shell
  if (path === ROUTES.CHART) {
    return (
      <Suspense fallback={null}>
        <ChartPage />
      </Suspense>
    );
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
            <Suspense fallback={
              <div className="flex items-center justify-center min-h-[60vh]">
                <div className="animate-pulse text-muted-foreground">Loading...</div>
              </div>
            }>
              {renderPage()}
            </Suspense>
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
