import { Icon } from '@components/ui/Icon';
import { useState, useEffect } from 'preact/hooks';
import { useRouter } from '@lib/router';
import { MaskIcon } from '@components/ui/MaskIcon';
import { WalletButton } from '@components/features/wallet';
import { SearchModal } from '@components/features/search';
import { SettingsModal, NotificationsModal } from '@components/features/modals';
import { Badge } from '@components/ui/Badge';
import { Tooltip } from '@components/ui/Tooltip';
import { useNotifications, useNotificationLog, clearLog } from '@lib/notifications';
import { LogLevel, type INotification } from '@/types/notification';
import { headerNavigation, ROUTES } from '@/constants/navigation';

export function Header() {
  const { path, navigate } = useRouter();
  const [showSearch, setShowSearch] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [showNotifications, setShowNotifications] = useState(false);
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false);
  const toastNotifications = useNotifications();
  const logNotifications = useNotificationLog();

  // Cmd+K / Ctrl+K to open search
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setShowSearch(true);
      }
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, []);

  // Map persistent log notifications to INotification format
  const mappedNotifications: INotification[] = logNotifications.map(n => ({
    id: n.id,
    message: n.message || n.title,
    level: n.type === 'error' ? LogLevel.ERROR
         : n.type === 'warning' ? LogLevel.WARNING
         : n.type === 'success' ? LogLevel.INFO
         : LogLevel.INFO,
    timestamp: n.timestamp,
  }));

  const isActive = (itemPath: string) => {
    if (itemPath === ROUTES.HOME) return path === ROUTES.HOME;
    return path.startsWith(itemPath);
  };

  return (
    <>
      <header className="fixed top-0 w-full h-12 flex items-center z-50">
        <nav className="max-w-7xl h-full mx-auto w-full flex items-center justify-between gap-6 px-3 border border-t-0 rounded-b-lg backdrop-blur-md bg-bg-0/80 border-border">
          {/* Logo */}
          <div
            className="flex items-center gap-2 cursor-pointer"
            onClick={() => navigate(ROUTES.HOME)}
          >
            <MaskIcon
              src="/brand/logo.svg"
              width="6rem"
              height="2rem"
              color="var(--fg-0)"
              aria-label="Logo"
            />
          </div>

          {/* Nav - Desktop */}
          <nav className="hidden md:flex items-center gap-1">
            {headerNavigation.map((item) => (
              <Tooltip key={item.path} content={item.description || item.title} side="bottom">
                <button
                  onClick={() => navigate(item.path)}
                  className={`px-3 py-1.5 text-base font-medium font-title rounded-md transition-colors ${
                    isActive(item.path)
                      ? 'text-primary bg-primary/10'
                      : 'text-muted-foreground hover:text-foreground hover:bg-muted/50'
                  }`}
                >
                  {item.title}
                </button>
              </Tooltip>
            ))}
          </nav>

          {/* Mobile Menu Button */}
          <button
            onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
            className="md:hidden p-2 text-muted-foreground hover:text-foreground hover:bg-bg-2 rounded-md transition-colors"
            aria-label="Toggle menu"
          >
            <Icon name={mobileMenuOpen ? 'x' : 'bars-3'} className="w-5 h-5" />
          </button>

          {/* Actions - Desktop */}
          <div className="hidden md:flex items-center border border-border rounded-sm overflow-hidden bg-bg-1">
            {/* Search button (fake input) */}
            <Tooltip content="Search (⌘K)" side="bottom">
              <button
                onClick={() => setShowSearch(true)}
                className="hidden md:flex toolbar-btn flex-center-gap-2 px-3 min-w-[200px] justify-start text-muted-foreground border-r border-border rounded-l-sm"
              >
                <Icon name="magnifying-glass" className="w-4 h-4" />
                <span className="text-sm">Search</span>
                <Badge variant="code" className="ml-auto">⌘K</Badge>
              </button>
            </Tooltip>

            {/* Notifications */}
            <Tooltip content="Notifications" side="bottom">
              <button
                onClick={() => setShowNotifications(true)}
                className="toolbar-btn border-r border-border relative"
              >
                <Icon name="bell" className="w-4 h-4" />
                {(() => {
                  const criticalCount = logNotifications.filter(n =>
                    n.type === 'error' || n.type === 'warning'
                  ).length;
                  return criticalCount > 0 && (
                    <span className={`absolute -top-1 -right-1 flex items-center justify-center rounded-full ${
                      criticalCount > 99
                        ? 'w-3 h-3 bg-destructive'
                        : 'w-4 h-4 bg-primary text-black text-[10px] font-bold'
                    }`}>
                      {criticalCount <= 99 && criticalCount}
                    </span>
                  );
                })()}
              </button>
            </Tooltip>

            {/* Settings */}
            <Tooltip content="Settings" side="bottom">
              <button
                onClick={() => setShowSettings(true)}
                className="toolbar-btn border-r border-border"
              >
                <Icon name="gear" className="w-4 h-4" />
              </button>
            </Tooltip>

            {/* Connect */}
            <WalletButton className="!rounded-none !rounded-r-sm" />
          </div>

          {/* Mobile Menu */}
          {mobileMenuOpen && (
            <div className="md:hidden absolute top-12 left-0 right-0 bg-bg-0 border-b border-border shadow-lg z-50">
              <nav className="flex flex-col p-2 space-y-1">
                {headerNavigation.map((item) => (
                  <button
                    key={item.path}
                    onClick={() => {
                      navigate(item.path);
                      setMobileMenuOpen(false);
                    }}
                    className={`px-4 py-2 text-left text-base font-medium font-title rounded-md transition-colors ${
                      isActive(item.path)
                        ? 'text-primary bg-primary/10'
                        : 'text-muted-foreground hover:text-foreground hover:bg-muted/50'
                    }`}
                  >
                    {item.title}
                  </button>
                ))}
              </nav>
            </div>
          )}
        </nav>
      </header>

      <SearchModal
        isOpen={showSearch}
        onClose={() => setShowSearch(false)}
        onOpenSettings={() => {
          setShowSearch(false);
          setShowSettings(true);
        }}
      />
      <SettingsModal isOpen={showSettings} onClose={() => setShowSettings(false)} />
      <NotificationsModal
        isOpen={showNotifications}
        onClose={() => setShowNotifications(false)}
        notifications={mappedNotifications}
        onClearAll={clearLog}
      />
    </>
  );
}
