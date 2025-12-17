import { Check, Copy } from 'lucide-react';
import React, { useEffect, useState } from 'react';
import { Button } from '@components/ui/Button';

// Utility function to escape HTML
const escapeHtml = (text: string): string => {
  const div = document.createElement('div');
  div.textContent = text;
  return div.innerHTML;
};

// Lazy load dependencies
let marked: any = null;
let Prism: any = null;
let mermaid: any = null;

const loadMarked = async () => {
  if (!marked) {
    const { marked: markedLib } = await import('marked');
    marked = markedLib;
  }
  return marked;
};

const loadPrism = async () => {
  if (!Prism) {
    const PrismModule = await import('prismjs');
    Prism = PrismModule.default;

    // Lazy load language components in proper dependency order
    // @ts-ignore - prismjs components don't have type declarations
    await import('prismjs/components/prism-javascript');
    // @ts-ignore - prismjs components don't have type declarations
    await import('prismjs/components/prism-typescript');
    // @ts-ignore - prismjs components don't have type declarations
    await import('prismjs/components/prism-jsx');

    // Load TSX after JSX and TypeScript are loaded
    try {
      // @ts-ignore - prismjs components don't have type declarations
      await import('prismjs/components/prism-tsx');
    } catch (err) {
      console.warn('TSX syntax highlighting not available:', err);
    }

    // Load Solidity
    // @ts-ignore - prismjs components don't have type declarations
    await import('prismjs/components/prism-solidity');

    // Load remaining languages in parallel
    await Promise.all([
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-json'),
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-bash'),
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-sql'),
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-markdown'),
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-yaml'),
      // @ts-ignore - prismjs components don't have type declarations
      import('prismjs/components/prism-docker'),
    ]);
  }
  return Prism;
};

const loadMermaid = async () => {
  if (!mermaid) {
    const mermaidModule = await import('mermaid');
    mermaid = mermaidModule.default;

    // Initialize Mermaid with BTR theme
    if (typeof window !== 'undefined') {
      mermaid.initialize({
        startOnLoad: false,
        theme: 'dark',
        themeVariables: {
          primaryColor: '#14b8a6',
          primaryTextColor: '#ffffff',
          primaryBorderColor: '#14b8a6',
          lineColor: '#94a3b8',
          sectionBkgColor: '#1e1e1e',
          altSectionBkgColor: '#0c0c0c',
          gridColor: '#2d2d2d',
          secondaryColor: '#00cc7a',
          tertiaryColor: '#0a201d',
        },
      });
    }
  }
  return mermaid;
};

// Code block component with copy functionality
function CodeBlock({
  children,
  className,
  ...props
}: React.HTMLAttributes<HTMLElement>) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    if (typeof children === 'string') {
      try {
        await navigator.clipboard.writeText(children);
        setCopied(true);
        setTimeout(() => setCopied(false), 2000);
      } catch (err) {
        console.error('Failed to copy:', err);
      }
    }
  };

  return (
    <div className="relative group">
      <Button
        variant="ghost"
        size="sm"
        className="absolute right-2 top-2 opacity-0 group-hover:opacity-100 transition-opacity z-10"
        onClick={handleCopy}
      >
        {copied ? (
          <Check className="w-4 h-4 text-green-500" />
        ) : (
          <Copy className="w-4 h-4" />
        )}
      </Button>
      <pre className={className} {...props}>
        <code>{children}</code>
      </pre>
    </div>
  );
}

// Mermaid diagram component
function MermaidDiagram({ chart }: { chart: string }) {
  const [svg, setSvg] = useState<string>('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>('');

  useEffect(() => {
    const renderChart = async () => {
      try {
        const mermaidLib = await loadMermaid();
        const id = Math.random().toString(36).substring(7);
        const { svg } = await mermaidLib.render(id, chart);
        setSvg(svg);
      } catch (err) {
        console.error('Mermaid rendering error:', err);
        setError('Failed to render diagram');
      } finally {
        setLoading(false);
      }
    };

    renderChart();
  }, [chart]);

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8 bg-muted rounded-lg">
        <div className="text-muted-foreground">Loading diagram...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center p-8 bg-destructive/10 border border-destructive/20 rounded-lg">
        <div className="text-destructive">{error}</div>
      </div>
    );
  }

  return (
    <div
      className="mermaid-diagram flex justify-center p-4 bg-background rounded-lg border"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}

interface MarkdownRendererProps {
  content: string;
  className?: string;
}

function MarkdownRenderer({ content, className }: MarkdownRendererProps) {
  const [renderedContent, setRenderedContent] = useState<string>('');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const renderMarkdown = async () => {
      try {
        const [markedLib, PrismLib] = await Promise.all([
          loadMarked(),
          loadPrism(),
        ]);

        // Create custom renderer for marked
        const renderer = new markedLib.Renderer();

        // Override code rendering for syntax highlighting and Mermaid
        renderer.code = ({ text, lang }: any) => {
          // Handle Mermaid diagrams
          if (
            lang === 'mermaid' ||
            text.match(/^graph|^sequenceDiagram|^flowchart/)
          ) {
            const id = Math.random().toString(36).substring(7);
            return `<div class="mermaid-placeholder" data-mermaid="${encodeURIComponent(text)}" data-id="${id}"></div>`;
          }

          // Handle syntax highlighting with Prism
          if (lang && PrismLib.languages[lang]) {
            try {
              const highlighted = PrismLib.highlight(
                text,
                PrismLib.languages[lang],
                lang,
              );
              return `<pre class="language-${lang}"><code class="language-${lang}">${highlighted}</code></pre>`;
            } catch (err) {
              console.error('Prism highlighting error for', lang, ':', err);
              // Fallback to basic code block without highlighting
              return `<pre class="language-${lang}"><code class="language-${lang}">${escapeHtml(text)}</code></pre>`;
            }
          }

          // Fallback for unsupported languages - try JavaScript syntax
          if (
            lang &&
            (lang === 'tsx' || lang === 'jsx') &&
            PrismLib.languages.javascript
          ) {
            try {
              const highlighted = PrismLib.highlight(
                text,
                PrismLib.languages.javascript,
                'javascript',
              );
              return `<pre class="language-${lang}"><code class="language-${lang}">${highlighted}</code></pre>`;
            } catch (err) {
              console.error('Fallback highlighting error:', err);
            }
          }

          // Fallback for unknown languages
          return `<pre><code class="language-${lang || 'text'}">${escapeHtml(text)}</code></pre>`;
        };

        // Configure marked with custom renderer
        markedLib.setOptions({
          renderer: renderer,
          breaks: true,
          gfm: true,
        });

        const html = markedLib.parse(content);
        setRenderedContent(html as string);
      } catch (error) {
        console.error('Markdown rendering error:', error);
        setRenderedContent('<p>Error rendering markdown content</p>');
      } finally {
        setLoading(false);
      }
    };

    renderMarkdown();
  }, [content]);

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="text-muted-foreground">Loading content...</div>
      </div>
    );
  }

  return (
    <div className={`h-full overflow-auto ${className || ''}`}>
      <div className="prose prose-invert max-w-none p-6">
        <div
          dangerouslySetInnerHTML={{ __html: renderedContent }}
          className="markdown-content"
        />
      </div>
    </div>
  );
}

export { MarkdownRenderer, CodeBlock, MermaidDiagram };
export default MarkdownRenderer;
