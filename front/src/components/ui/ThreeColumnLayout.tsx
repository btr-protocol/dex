import { ComponentChildren } from 'preact';

export interface ThreeColumnLayoutProps {
  leftHeader: ComponentChildren;
  leftContent: ComponentChildren;
  rightHeader: ComponentChildren;
  rightContent: ComponentChildren;
  mainContent: ComponentChildren;
  mobileNavLabel?: string;
  mobileNavOpen?: boolean;
  onToggleMobileNav?: () => void;
  scrollableMain?: boolean;
}

export function ThreeColumnLayout({
  leftHeader,
  leftContent,
  rightHeader,
  rightContent,
  mainContent,
  mobileNavLabel = 'Menu',
  mobileNavOpen = false,
  onToggleMobileNav,
  scrollableMain = false,
}: ThreeColumnLayoutProps) {
  return (
    <div className="max-w-7xl mx-auto px-4">
      {/* Mobile nav toggle */}
      <div className="lg:hidden sticky top-12 z-30 bg-bg-1/95 backdrop-blur border-b border-border py-2 -mx-4 px-4">
        <button
          onClick={onToggleMobileNav}
          className="hover:text-fg-1"
        >
          <div className="flex items-center gap-2 text-sm text-fg-2">
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
            </svg>
            <span>{mobileNavLabel}</span>
          </div>
        </button>

        {mobileNavOpen && (
          <div className="lg:hidden sticky top-12 z-30 bg-bg-1/95 backdrop-blur border-b border-border max-h-[60vh] overflow-y-auto">
            {leftContent}
          </div>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-5 h-[calc(100vh-5.5rem)]">
        <aside className="hidden lg:flex flex-col h-full min-h-0 pr-4 border-r border-border pt-6">
          <div className="shrink-0">
            {leftHeader}
          </div>
          <div className="flex-1 overflow-y-auto min-h-0">
            {leftContent}
          </div>
        </aside>

        <main className={`lg:col-span-3 px-4 ${scrollableMain ? 'h-full min-h-0 overflow-y-auto pt-6 pb-10' : ''}`}>
          {mainContent}
        </main>

        <aside className="hidden lg:flex flex-col h-full min-h-0 pl-4 border-l border-border pt-6">
          <div className="shrink-0">
            {rightHeader}
          </div>
          <div className="flex-1 overflow-y-auto min-h-0">
            {rightContent}
          </div>
        </aside>
      </div>
    </div>
  );
}
