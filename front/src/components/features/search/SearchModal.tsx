import { useState, useEffect } from 'preact/hooks';
import type { JSX } from 'preact';
import { BaseModal } from '@components/ui/BaseModal';
import { KeyboardShortcutGroup } from '@components/ui/KeyboardShortcut';
import { EmptyState } from '@components/ui/EmptyState';
import { Icon } from '@components/ui/Icon';
import { MaskIcon } from '@components/ui/MaskIcon';
import { searchGrouped, initializeSearch } from '@lib/search';
import { useRouter } from '@lib/router';
import { useModalState } from '@hooks/useModalState';
import { useExternalLink } from '@/lib/external-links';
import { ROUTES } from '@/constants/navigation';
import { ModalSection } from '@components/ui/ModalSection';
import { SearchResultItem, TokenIcon } from './SearchResultItem';
import {
  getFeatureIcon,
  getTokenFromTitle,
  getSettingsIcon,
  getLinkIcon,
  getSettingsIconPath,
} from '@/utils/search';
import { useKeyboardNav } from '@hooks/useKeyboardNav';

interface SearchModalProps {
  isOpen: boolean;
  onClose: (open: boolean) => void;
  onOpenSettings?: (section?: string) => void;
}

export function SearchModal({ isOpen, onClose, onOpenSettings }: SearchModalProps) {
  const [query, setQuery] = useModalState('', isOpen);
  const [selectedIndex, setSelectedIndex] = useModalState(0, isOpen);
  const [isReady, setIsReady] = useState(false);
  const router = useRouter();
  const navigate = router?.navigate ?? (() => {});
  const { openExternalLink } = useExternalLink();

  // Initialize search when modal first opens (lazy load MiniSearch)
  useEffect(() => {
    if (isOpen && !isReady) {
      initializeSearch().then(() => setIsReady(true));
    }
  }, [isOpen, isReady]);

  const results = searchGrouped(query);
  const filteredFeatures = results.Features.filter(r => r.title !== 'Documentation');

  const archivistResult = {
    id: 'archivist-special',
    title: "Archivist",
    desc: 'Chat with BTR AI about the protocol, docs, and codebase',
    path: '/archivist',
    cat: 'Features' as const,
  };

  const allResults = query.trim()
    ? [archivistResult, ...filteredFeatures, ...results.Settings, ...results.Links, ...results.Docs]
    : [archivistResult, ...filteredFeatures];

  // Keyboard navigation hook
  const { handleKeyDown } = useKeyboardNav({
    items: allResults,
    onSelect: (result) => {
      handleSelect(result.path, result.cat === 'Settings' ? result.section : undefined);
    },
    isEnabled: true,
    onEscape: () => onClose(false),
    loop: true,
  });

  // Update selected index state from hook
  useEffect(() => {
    setSelectedIndex((prev) => prev); // Re-render when index changes
  }, []);

  const handleSelect = (path: string, settingsSection?: string) => {
    if (path === ROUTES.SETTINGS && onOpenSettings) {
      onOpenSettings(settingsSection);
      onClose(false);
    } else if (path.startsWith('http')) {
      openExternalLink(path);
    } else {
      // If navigating to archivist with a query, pass it as URL param
      if (path === '/archivist' && query.trim()) {
        navigate(`${path}?q=${encodeURIComponent(query.trim())}`);
      } else {
        navigate(path);
      }
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
      <div className="flex flex-col">
        {!query.trim() ? (
          <div className="px-4 py-8 text-center text-muted-foreground text-sm">
            Type to search features, settings, links, and documentation
          </div>
        ) : allResults.length === 0 ? (
          <div className="px-4">
            <EmptyState
              query={query}
              message="No results found"
              action={{
                label: 'Clear search',
                onClick: () => setQuery(''),
              }}
            />
          </div>
        ) : (
          <div className="space-y-3">
            {/* Always show Archivist as first result */}
            <ModalSection title="AI Assistants" icon="sparkles">
              <SearchResultItem
                key="archivist-special"
                isSelected={selectedIndex === 0}
                onClick={() => handleSelect('/archivist', undefined)}
                icon={<Icon name="bot" className="w-4 h-4" />}
                title="Archivist"
                description="Chat with BTR AI about the protocol, docs, and codebase"
                rightIcon={<Icon name="arrow-right" className="w-4 h-4" />}
              />
            </ModalSection>

            {filteredFeatures.length > 0 && (
              <ModalSection title="Features" icon="zap">
                {filteredFeatures.map((result, idx) => {
                  const iconName = getFeatureIcon(result.title);
                  const tokenSymbol = getTokenFromTitle(result.title);
                  const globalIndex = idx + 1;
                  return (
                    <SearchResultItem
                      key={result.id}
                      isSelected={selectedIndex === globalIndex}
                      onClick={() => handleSelect(result.path, undefined)}
                      icon={
                        tokenSymbol ? (
                          <TokenIcon symbol={tokenSymbol} />
                        ) : (
                          <Icon name={iconName} className="w-4 h-4" />
                        )
                      }
                      title={result.title}
                      description={result.desc}
                      rightIcon={<Icon name="arrow-right" className="w-4 h-4" />}
                    />
                  );
                })}
              </ModalSection>
            )}

            {results.Settings.length > 0 && (
              <ModalSection title="Settings" icon="settings">
                {results.Settings.map((result, idx) => {
                  const globalIndex = filteredFeatures.length + 1 + idx;
                  const iconType = getSettingsIcon(result.title);
                  return (
                    <SearchResultItem
                      key={result.id}
                      isSelected={selectedIndex === globalIndex}
                      onClick={() => handleSelect(result.path, result.section)}
                      icon={
                        <MaskIcon
                          src={getSettingsIconPath(iconType)}
                          size="sm"
                          color="var(--fg-2)"
                        />
                      }
                      title={result.title}
                      description={result.desc}
                      rightIcon={<Icon name="arrow-right" className="w-4 h-4" />}
                    />
                  );
                })}
              </ModalSection>
            )}

            {results.Links.length > 0 && (
              <ModalSection title="Links" icon="link">
                {results.Links.map((result, idx) => {
                  const globalIndex = filteredFeatures.length + results.Settings.length + 1 + idx;
                  const iconPath = getLinkIcon(result.title);
                  return (
                    <SearchResultItem
                      key={result.id}
                      isSelected={selectedIndex === globalIndex}
                      onClick={() => handleSelect(result.path, undefined)}
                      icon={
                        iconPath ? (
                          <MaskIcon src={iconPath} size="sm" color="var(--fg-2)" />
                        ) : (
                          <Icon name="arrow-square-out" className="w-4 h-4" />
                        )
                      }
                      title={result.title}
                      description={result.desc}
                      rightIcon={<Icon name="arrow-square-out" className="w-3 h-3" />}
                    />
                  );
                })}
              </ModalSection>
            )}

            {results.Docs.length > 0 && (
              <ModalSection title="Docs" icon="file-text">
                {results.Docs.map((result, idx) => {
                  const globalIndex =
                    filteredFeatures.length + results.Settings.length + results.Links.length + 1 + idx;
                  return (
                    <SearchResultItem
                      key={result.id}
                      isSelected={selectedIndex === globalIndex}
                      onClick={() => handleSelect(result.path, undefined)}
                      title={result.title}
                      content={result.content}
                      isDocs={true}
                      rightIcon={<Icon name="arrow-right" className="w-4 h-4" />}
                    />
                  );
                })}
              </ModalSection>
            )}
          </div>
        )}
      </div>
    </BaseModal>
  );
}
