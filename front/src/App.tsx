import { WalletProvider } from '@lib/wallet';
import { RouterProvider, useRouter } from '@lib/router';
import { ThemeProvider } from '@lib/theme';
import { SettingsProvider } from '@lib/settings';
import { ExternalLinkProvider } from '@lib/external-links';
import { addNotification } from '@lib/notifications';
import { Notifications } from '@components/Notifications';
import { BgRenderer } from '@components/BgRenderer';
import { Header } from '@/components/layout/Header';
import { Footer } from '@/components/layout/Footer';
import { DisclaimerPage, useDisclaimer } from '@/pages/DisclaimerPage';
import { useAuth } from '@lib/auth';
import { useEffect, useState } from 'preact/hooks';
import { ROUTES } from '@/constants/navigation';
import { logger } from '@sdk/utils';

const log = logger.withContext('App');

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
        log.error('Failed to load page', e);
        setLoading(false);
      }
    });
    return () => { active = false; };
  }, [load, componentName]);

  if (loading) return <div className="flex-center h-screen"><div className="animate-spin">Loading...</div></div>;
  if (!Component) return <div className="flex-center h-screen text-red-500">Failed to load page</div>;
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
const ArchivistPageLazy = () => <LazyPage load={() => import('@/pages/ArchivistPage')} componentName="ArchivistPage" />;
const AdminPageLazy = () => <LazyPage load={() => import('@/pages/AdminPage')} componentName="AdminPage" />;

// Detect if user agent is a bot/crawler
function isBot(): boolean {
  if (typeof navigator === 'undefined') return true;
  const botPattern = /(bot|crawler|spider|crawling|googlebot|bingbot|slurp|duckduckbot|baiduspider|yandexbot|facebookexternalhit|twitterbot|rogerbot|linkedinbot|embedly|quora|showyoubot|outbrain|pinterest|slackbot|vkshare|w3c_validator|whatsapp)/i;
  return botPattern.test(navigator.userAgent);
}

// Check if route should be publicly accessible without authentication
function isPublicRoute(path: string): boolean {
  const publicRoutes = ['/docs', '/legal'];
  return publicRoutes.some(route => path.startsWith(route));
}

function AppContent() {
  const { accepted: disclaimerAccepted, accept: acceptDisclaimer } = useDisclaimer();
  const { isAuthenticated, isLoading: authLoading } = useAuth();
  const { path } = useRouter();
  const [shouldRenderBackground, setShouldRenderBackground] = useState(true);

  const isGuardedMode = import.meta.env.VITE_GUARDED === 'true';

  useEffect(() => {
    // Check if user is a bot - skip background rendering for bots
    if (isBot()) {
      setShouldRenderBackground(false);
    }
  }, []);

  useEffect(() => {
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

    if (path === ROUTES.ARCHIVIST) {
      return <ArchivistPageLazy />;
    }

    if (path === ROUTES.ADMIN) {
      return <AdminPageLazy />;
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

  // Guarded mode: show disclaimer if not authenticated OR not accepted (wait for auth check)
  // Normal mode: show disclaimer only if not accepted
  // Public routes (/docs, /legal) bypass the guard entirely
  const shouldShowDisclaimer = isGuardedMode
    ? (!isAuthenticated || !disclaimerAccepted) && !authLoading && !isPublicRoute(path)
    : !disclaimerAccepted && !isPublicRoute(path);

  if (shouldShowDisclaimer) {
    return (
      <div className="h-screen bg-bg-0 text-foreground flex flex-col relative">
        {shouldRenderBackground && <BgRenderer />}
        <DisclaimerPage onAccept={acceptDisclaimer} />
        <Notifications />
      </div>
    );
  }

  // Main app
  return (
    <div className="h-screen bg-bg-0 text-foreground flex flex-col relative">
      {shouldRenderBackground && <BgRenderer />}
      <Header />
      <main className="flex-1 relative z-10 pt-12 pb-8 h-full">
        {renderPage()}
      </main>
      <Footer />
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
