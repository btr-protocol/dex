import { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import { SessionsPanel } from './SessionsPanel';
import { SourcesPanel } from './SourcesPanel';
import { ThreeColumnLayout } from '@components/ui/ThreeColumnLayout';
import { FlexRow } from '@components/ui/Flex';
import { Icon } from '@components/ui/Icon';
import { Button } from '@components/ui/Button';
import type { ArchivistSource } from '@/types/archivist';

interface ArchivistLayoutProps {
  children: ComponentChildren;
  currentSessionId: string;
  onNewSession: () => void;
  onSelectSession: (sessionId: string) => void;
  sources: ArchivistSource[];
}

export function ArchivistLayout({
  children,
  currentSessionId,
  onNewSession,
  onSelectSession,
  sources
}: ArchivistLayoutProps) {
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  return (
    <ThreeColumnLayout
      leftHeader={
        <FlexRow gap="2" className="items-center justify-between">
          <div className="text-sm font-semibold pl-4">Chat History</div>
          <Button
            variant="ghost"
            size="xs"
            onClick={onNewSession}
            leftIcon={<Icon name="plus" className="w-4 h-4" />}
          />
        </FlexRow>
      }
      leftContent={
        <SessionsPanel
          currentSessionId={currentSessionId}
          onNewSession={onNewSession}
          onSelectSession={onSelectSession}
        />
      }
      rightHeader={<div className="text-sm font-semibold">Sources ({sources.length})</div>}
      rightContent={<SourcesPanel sources={sources} />}
      mainContent={children}
      mobileNavLabel="Chat History"
      mobileNavOpen={mobileNavOpen}
      onToggleMobileNav={() => setMobileNavOpen(!mobileNavOpen)}
    />
  );
}
