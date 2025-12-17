import { useState, useEffect } from 'preact/hooks';
import { BaseModal } from '@components/ui/BaseModal';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { ArrowRight, ExternalLink, Settings, Zap, Link2, FileText, Repeat2, TrendingUp, Plus } from 'lucide-react';
import { searchGrouped, initializeSearch } from '@lib/search';
import { useRouter } from '@lib/router';
import { MaskIcon } from '@components/ui/MaskIcon';

interface SearchModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  onOpenSettings?: (section?: string) => void;
}

const getFeatureIcon = (title: string) => {
  switch (title) {
    case 'Swap':
      return Repeat2;
    case 'Liquidity':
      return Zap;
    case 'Stake':
      return TrendingUp;
    case 'Metrics':
      return FileText;
    case 'Add Asset':
      return Plus;
    case 'Documentation':
      return FileText;
    default:
      // Check if it's a token swap (e.g., "Swap ETH")
      if (title.startsWith('Swap ')) {
        return Repeat2;
      }
      return null;
  }
};

// Extract token symbol from "Swap TOKEN" title
const getTokenFromTitle = (title: string): string | null => {
  if (title.startsWith('Swap ')) {
    return title.replace('Swap ', '').toLowerCase();
  }
  return null;
};

const getSettingsIcon = (title: string) => {
  switch (title) {
    case 'Max Slippage':
    case 'Detail Route':
      return 'slippage'; // Execution icon
    case 'Theme':
      return 'theme'; // Theme icon
    case 'Hide Small Balances':
    case 'Hide Unsupported Tokens':
    case 'Animate Background':
      return 'interface'; // Interface icon
    default:
      return 'settings'; // Default icon
  }
};

const getLinkIcon = (title: string): string | null => {
  switch (title) {
    case 'Telegram':
      return '/icons/telegram.svg';
    case 'Github':
      return '/icons/github.svg';
    case 'X':
      return '/icons/x.svg';
    case 'Docs':
      return '/icons/docs.svg';
    default:
      return null;
  }
};

export function SearchModal({ isOpen, onClose, onOpenSettings }: SearchModalProps) {
  const [query, setQuery] = useState('');
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [isReady, setIsReady] = useState(false);
  const router = useRouter();
  const navigate = router?.navigate ?? (() => {});

  // Initialize search when modal first opens (lazy load MiniSearch)
  useEffect(() => {
    if (isOpen && !isReady) {
      initializeSearch().then(() => setIsReady(true));
    }
  }, [isOpen, isReady]);

  // Reset state when modal opens
  useEffect(() => {
    if (isOpen) {
      setQuery('');
      setSelectedIndex(0);
    }
  }, [isOpen]);

  const results = searchGrouped(query);
  const filteredFeatures = results.Features.filter(r => r.title !== 'Documentation');
  const allResults = [...filteredFeatures, ...results.Settings, ...results.Links, ...results.Docs];

  // Handle keyboard navigation
  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setSelectedIndex((prev) => (prev + 1) % allResults.length);
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setSelectedIndex((prev) => (prev - 1 + allResults.length) % allResults.length);
    } else if (e.key === 'Enter' && allResults[selectedIndex]) {
      e.preventDefault();
      const result = allResults[selectedIndex];
      handleSelect(result.path, result.cat === 'Settings' ? result.section : undefined);
    }
  };

  const handleSelect = (path: string, settingsSection?: string) => {
    if (path === '/settings' && onOpenSettings) {
      onOpenSettings(settingsSection);
      onClose(false);
    } else if (path.startsWith('http')) {
      window.open(path, '_blank');
    } else {
      navigate(path);
      onClose(false);
    }
  };

  return (
    <BaseModal
      isOpen={isOpen}
      onClose={onClose}
      title="Search"
      headerType="input"
      placeholder="Search features, settings, links, and docs..."
      searchValue={query}
      onSearchChange={setQuery}
      onSearchKeyDown={handleKeyDown}
      footerNav={
        <KeyboardShortcutGroup
          shortcuts={[
            { keys: '↑↓', label: 'Navigate' },
            { keys: 'Enter', label: 'Select' },
            { keys: 'Esc', label: 'Close' },
          ]}
        />
      }
    >
      <div className="p-2">
          {!query.trim() ? (
            <div className="px-4 py-8 text-center text-muted-foreground text-sm">
              Type to search features, settings, links, and documentation
            </div>
          ) : allResults.length === 0 ? (
            <div className="px-4 py-8 text-center text-muted-foreground text-sm">
              No results found for "{query}"
            </div>
          ) : (
            <div className="flex flex-col">
              {filteredFeatures.length > 0 && (
                <>
                  <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
                    <Zap className="w-3.5 h-3.5" />
                    Features
                  </div>
                  <div className="flex flex-col gap-1 mb-4">
                    {filteredFeatures.map((result, idx) => {
                      const globalIndex = idx;
                      const FeatureIcon = getFeatureIcon(result.title);
                      const tokenSymbol = getTokenFromTitle(result.title);
                      return (
                        <button
                          key={result.id}
                          onClick={() => handleSelect(result.path, undefined)}
                          className={`flex items-center gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${
                            selectedIndex === globalIndex
                              ? 'bg-bg-2'
                              : 'hover:bg-bg-2'
                          }`}
                        >
                          {tokenSymbol ? (
                            <img
                              src={`/tokens/${tokenSymbol}.svg`}
                              alt={tokenSymbol}
                              className="w-5 h-5 shrink-0 rounded-full"
                              onError={(e) => {
                                // Fallback to swap icon if token icon not found
                                e.currentTarget.style.display = 'none';
                                e.currentTarget.nextElementSibling?.classList.remove('hidden');
                              }}
                            />
                          ) : null}
                          {tokenSymbol && <Repeat2 className="w-4 h-4 shrink-0 hidden" />}
                          {!tokenSymbol && FeatureIcon && <FeatureIcon className="w-4 h-4 shrink-0" />}
                          <div className="flex-1">
                            <div className="font-semibold text-sm">{result.title}</div>
                            {result.desc && (
                              <div className="text-xs text-muted-foreground mt-0.5 line-clamp-1">
                                {result.desc}
                              </div>
                            )}
                          </div>
                          <ArrowRight className="w-4 h-4 shrink-0" />
                        </button>
                      );
                    })}
                  </div>
                  {(results.Settings.length > 0 || results.Links.length > 0 || results.Docs.length > 0) && (
                    <div className="h-px bg-border mb-4" />
                  )}
                </>
              )}

              {results.Settings.length > 0 && (
                <>
                  <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
                    <Settings className="w-3.5 h-3.5" />
                    Settings
                  </div>
                  <div className="flex flex-col gap-1 mb-4">
                    {results.Settings.map((result, idx) => {
                      const globalIndex = filteredFeatures.length + idx;
                      const iconType = getSettingsIcon(result.title);
                      const getIconPath = (type: string) => {
                        switch (type) {
                          case 'slippage':
                            return '/icons/slippage.svg';
                          case 'theme':
                            return '/icons/settings.svg';
                          case 'interface':
                            return '/icons/settings.svg';
                          default:
                            return '/icons/settings.svg';
                        }
                      };
                      return (
                        <button
                          key={result.id}
                          onClick={() => handleSelect(result.path, result.section)}
                          className={`flex items-center gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${
                            selectedIndex === globalIndex
                              ? 'bg-bg-2'
                              : 'hover:bg-bg-2'
                          }`}
                        >
                          <MaskIcon src={getIconPath(iconType)} size="sm" color="var(--fg-2)" className="shrink-0" />
                          <div className="flex-1">
                            <div className="font-semibold text-sm">{result.title}</div>
                            {result.desc && (
                              <div className="text-xs text-muted-foreground mt-0.5 line-clamp-1">
                                {result.desc}
                              </div>
                            )}
                          </div>
                          <ArrowRight className="w-4 h-4 shrink-0" />
                        </button>
                      );
                    })}
                  </div>
                  {(results.Links.length > 0 || results.Docs.length > 0) && (
                    <div className="h-px bg-border mb-4" />
                  )}
                </>
              )}

              {results.Links.length > 0 && (
                <>
                  <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
                    <Link2 className="w-3.5 h-3.5" />
                    Links
                  </div>
                  <div className="flex flex-col gap-1 mb-4">
                    {results.Links.map((result, idx) => {
                      const globalIndex = filteredFeatures.length + results.Settings.length + idx;
                      const iconPath = getLinkIcon(result.title);
                      return (
                        <button
                          key={result.id}
                          onClick={() => handleSelect(result.path, undefined)}
                          className={`flex items-center gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${
                            selectedIndex === globalIndex
                              ? 'bg-bg-2'
                              : 'hover:bg-bg-2'
                          }`}
                        >
                          {iconPath ? (
                            <MaskIcon src={iconPath} size="sm" color="var(--fg-2)" className="shrink-0" />
                          ) : (
                            <ExternalLink className="w-4 h-4 shrink-0" />
                          )}
                          <div className="flex-1">
                            <div className="font-semibold text-sm">{result.title}</div>
                            {result.desc && (
                              <div className="text-xs text-muted-foreground mt-0.5 line-clamp-1">
                                {result.desc}
                              </div>
                            )}
                          </div>
                          <ExternalLink className="w-3 h-3 shrink-0" />
                        </button>
                      );
                    })}
                  </div>
                  {results.Docs.length > 0 && (
                    <div className="h-px bg-border mb-4" />
                  )}
                </>
              )}

              {results.Docs.length > 0 && (
                <>
                  <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
                    <FileText className="w-3.5 h-3.5" />
                    Docs
                  </div>
                  <div className="flex flex-col gap-1">
                    {results.Docs.map((result, idx) => {
                      const globalIndex = filteredFeatures.length + results.Settings.length + results.Links.length + idx;
                      return (
                        <button
                          key={result.id}
                          onClick={() => handleSelect(result.path, undefined)}
                          className={`flex items-center justify-between gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${
                            selectedIndex === globalIndex
                              ? 'bg-bg-2'
                              : 'hover:bg-bg-2'
                          }`}
                        >
                          <div className="flex-1">
                            <div className="font-semibold text-sm">{result.title}</div>
                            {result.content && (
                              <div
                                className="text-xs text-muted-foreground mt-0.5 line-clamp-2 search-excerpt"
                                dangerouslySetInnerHTML={{ __html: result.content }}
                              />
                            )}
                          </div>
                          <ArrowRight className="w-4 h-4 shrink-0" />
                        </button>
                      );
                    })}
                  </div>
                </>
              )}
            </div>
          )}
        </div>
    </BaseModal>
  );
}
