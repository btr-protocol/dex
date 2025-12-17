import { useState } from 'preact/hooks';
import { NavPanel } from './NavPanel';
import { FlexRow, FlexCenter } from './ui/Flex';
import { SectionHeader, Label } from './ui/Text';

interface DocsLayoutProps {
  children: React.ReactNode;
  currentSlug?: string;
  loading?: boolean;
}

export function DocsLayout({ children, currentSlug, loading = false }: DocsLayoutProps) {
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  return (
    <div className="max-w-7xl mx-auto px-4">
      {/* Mobile nav toggle */}
      <div className="lg:hidden sticky top-12 z-30 bg-bg-1/95 backdrop-blur border-b border-border py-2 -mx-4 px-4">
        <button
          onClick={() => setMobileNavOpen(!mobileNavOpen)}
          className="hover:text-fg-1"
        >
          <FlexRow gap="2" className="text-sm text-fg-2">
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
            </svg>
            <span>Documentation Menu</span>
          </FlexRow>
        </button>

        {mobileNavOpen && (
          <div className="absolute top-full left-0 right-0 bg-bg-1 border-b border-border max-h-[60vh] overflow-y-auto p-4">
            <NavPanel type="files" />
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-5 gap-6">
        {/* Left Sidebar */}
        <aside className="hidden lg:block sticky top-12 h-[calc(100vh-3rem)] overflow-y-auto border-r border-border pr-4 pt-6">
          <SectionHeader className="mb-3">Contents</SectionHeader>
          <NavPanel type="files" />
        </aside>

        {/* Main Content */}
        <main className="lg:col-span-3 py-6">
          {loading ? (
            <FlexCenter className="py-20">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary" />
            </FlexCenter>
          ) : (
            <div className="prose prose-invert max-w-none">
              {children}
            </div>
          )}
        </main>

        {/* Right Sidebar */}
        <aside className="hidden lg:block sticky top-12 h-[calc(100vh-3rem)] overflow-y-auto border-l border-border pl-4 pt-6">
          <SectionHeader className="mb-3">On This Page</SectionHeader>
          {currentSlug ? (
            <NavPanel type="toc" slug={currentSlug} />
          ) : (
            <Label>No headings found</Label>
          )}
        </aside>
      </div>
    </div>
  );
}
