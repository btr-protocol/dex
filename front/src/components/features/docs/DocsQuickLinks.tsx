import { ComponentChildren } from 'preact';
import { Icon } from '@components/ui/Icon';

interface QuickLink {
  title: string;
  description: string;
  icon: ComponentChildren;
  onClick: () => void;
}

interface DocsQuickLinksProps {
  onNavigate: (path: string) => void;
}

export function DocsQuickLinks({ onNavigate }: DocsQuickLinksProps) {
  const links: QuickLink[] = [
    {
      title: 'Traders',
      description: 'Understand swap costs and price impact',
      icon: <Icon name="book-open" className="w-8 h-8" />,
      onClick: () => onNavigate('/docs/1-AIMM/1.2-Pricing/1.2.5-Fees'),
    },
    {
      title: 'LPs',
      description: 'Learn deposit, withdrawal, and reward mechanics',
      icon: <Icon name="users" className="w-8 h-8" />,
      onClick: () => onNavigate('/docs/1-AIMM/1.2-Pricing/1.2.1-Inventory'),
    },
    {
      title: 'Integrators',
      description: 'Integrate with oracles and flash lending',
      icon: <Icon name="link" className="w-8 h-8" />,
      onClick: () => onNavigate('/docs/1-AIMM/1.3-Modules/1.3.1-Internal-Oracle'),
    },
    {
      title: 'Curators',
      description: 'Configure pools and liquidity profiles',
      icon: <Icon name="gear" className="w-8 h-8" />,
      onClick: () => onNavigate('/docs/1-AIMM/1.2-Pricing/Parameters'),
    },
  ];

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-4 my-8">
      {links.map((link) => (
        <button
          key={link.title}
          onClick={link.onClick}
          className="group relative overflow-hidden rounded-lg p-6 text-left transition-all duration-200"
          style={{
            backgroundColor: 'var(--bg-2)',
            border: '1px solid var(--border)',
          }}
          onMouseEnter={(e) => {
            const elem = e.currentTarget;
            elem.style.backgroundColor = 'var(--bg-3)';
            elem.style.transform = 'translateY(-2px)';
          }}
          onMouseLeave={(e) => {
            const elem = e.currentTarget;
            elem.style.backgroundColor = 'var(--bg-2)';
            elem.style.transform = 'translateY(0)';
          }}
        >
          {/* Gradient accent on hover */}
          <div
            className="absolute inset-0 opacity-0 group-hover:opacity-10 transition-opacity"
            style={{
              background:
                'linear-gradient(135deg, var(--primary) 0%, transparent 100%)',
            }}
          />

          {/* Content */}
          <div className="relative z-10">
            <div
              className="mb-3 inline-flex p-3 rounded-lg transition-colors"
              style={{ backgroundColor: 'var(--bg-3)', color: 'var(--primary)' }}
            >
              {link.icon}
            </div>
            <h3
              className="text-lg font-semibold mb-2"
              style={{ color: 'var(--fg-0)' }}
            >
              {link.title}
            </h3>
            <p className="text-sm" style={{ color: 'var(--fg-2)' }}>
              {link.description}
            </p>
          </div>

          {/* Arrow indicator */}
          <div
            className="absolute right-6 top-1/2 transform -translate-y-1/2 opacity-0 group-hover:opacity-100 transition-opacity"
            style={{ color: 'var(--primary)' }}
          >
            <svg
              className="w-5 h-5 transform group-hover:translate-x-1 transition-transform"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M9 5l7 7-7 7"
              />
            </svg>
          </div>
        </button>
      ))}
    </div>
  );
}
