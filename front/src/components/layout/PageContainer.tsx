import type { ComponentChildren } from 'preact';

interface PageContainerProps {
  title: string;
  children: ComponentChildren;
  actions?: ComponentChildren;
}

export default function PageContainer({ title, children, actions }: PageContainerProps) {
  return (
    <div className="max-w-7xl mx-auto px-3 py-6">
      {/* Page Header */}
      <div className="flex items-center justify-between mb-4">
        <h1 className="text-2xl font-bold text-foreground font-numeric">{title}</h1>
        {actions && <div className="flex items-center gap-2">{actions}</div>}
      </div>

      {/* Page Content */}
      {children}
    </div>
  );
}
