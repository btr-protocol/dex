import { ComponentChildren } from 'preact';
import { useState } from 'preact/hooks';
import { NavPanel } from './NavPanel';
import { ThreeColumnLayout } from '@components/ui/ThreeColumnLayout';
import { FlexRow, FlexCenter } from '@components/ui/Flex';
import { Spinner } from '@components/ui/Spinner';

interface DocsLayoutProps {
  children: ComponentChildren;
  currentSlug?: string;
  loading?: boolean;
}

export function DocsLayout({ children, currentSlug, loading = false }: DocsLayoutProps) {
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  return (
    <ThreeColumnLayout
      leftHeader={<div className="text-sm font-semibold">Contents</div>}
      leftContent={<NavPanel type="files" />}
      rightHeader={<div className="text-sm font-semibold">On This Page</div>}
      rightContent={currentSlug ? <NavPanel type="toc" slug={currentSlug} /> : <div className="text-xs text-muted-foreground">No headings found</div>}
      mainContent={
        loading ? (
          <FlexCenter className="py-20">
            <Spinner size="lg" />
          </FlexCenter>
          ) : (
            <div className="prose prose-invert max-w-none">
              {children}
            </div>
          )
      }
      scrollableMain={true}
      mobileNavLabel="Documentation Menu"
      mobileNavOpen={mobileNavOpen}
      onToggleMobileNav={() => setMobileNavOpen(!mobileNavOpen)}
    />
  );
}
