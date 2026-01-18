import { useEffect, useState, useRef } from 'preact/hooks';
import { render } from 'preact';
import { getDocBySlug, type DocFile } from '@/utils/docs';
import { PieChart, BarChart, LineChart, Sparkline } from '@/components/charts';

interface MarkdownRendererProps {
  content?: string;
  slug?: string;
  className?: string;
}

interface ChartConfig {
  type: 'pie' | 'bar' | 'line' | 'sparkline';
  data: number[] | number[][];
  labels?: string[];
  width?: number;
  height?: number;
  color?: string | string[];
  showLine?: boolean;
  showArea?: boolean;
  showPoint?: boolean;
  smooth?: boolean;
  stacked?: boolean;
  horizontal?: boolean;
  donut?: boolean;
  donutWidth?: number;
  className?: string;
}

/**
 * Renders pre-compiled markdown as HTML.
 *
 * All markdown is pre-compiled at build time by the backend (scripts/precompile-markdown.ts)
 * with marked, prismjs, asciimath2ml, mermaid, and chartist. This component renders the
 * pre-compiled HTML and injects Preact chart components for ```chart blocks.
 *
 * Usage:
 * - With slug: <MarkdownRenderer slug="overview" />
 * - With content: <MarkdownRenderer content="<p>Html content</p>" />
 */
export function MarkdownRenderer({ content: initialContent, slug, className }: MarkdownRendererProps) {
  const [html, setHtml] = useState<string>(initialContent || '');
  const [loading, setLoading] = useState(!initialContent);
  const [error, setError] = useState<string | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    // If content is provided directly, no need to load
    if (initialContent) {
      setHtml(initialContent);
      setLoading(false);
      return;
    }

    // Load pre-compiled HTML from docs.json by slug
    if (slug) {
      setLoading(true);
      setError(null);

      getDocBySlug(slug)
        .then((doc: DocFile | null) => {
          if (doc && doc.content) {
            setHtml(doc.content);
          } else {
            setError('Document not found');
            setHtml('');
          }
        })
        .catch((err) => {
          console.error(`Failed to load markdown doc "${slug}":`, err);
          setError('Failed to load content');
          setHtml('');
        })
        .finally(() => {
          setLoading(false);
        });
    }
  }, [initialContent, slug]);

  // Render charts after HTML is injected
  useEffect(() => {
    if (!containerRef.current || !html) return;

    const chartContainers = containerRef.current.querySelectorAll('.chart-container');

    chartContainers.forEach((container) => {
      const div = container as HTMLDivElement;
      const encodedConfig = div.getAttribute('data-chart-config');

      if (!encodedConfig) return;

      try {
        const config: ChartConfig = JSON.parse(decodeURIComponent(encodedConfig));

        // Create chart element
        let chartElement;

        switch (config.type) {
          case 'pie':
            chartElement = (
              <PieChart
                data={config.data}
                labels={config.labels}
                width={config.width}
                height={config.height}
                color={config.color}
                donut={config.donut}
                donutWidth={config.donutWidth}
                className={config.className}
              />
            );
            break;
          case 'bar':
            chartElement = (
              <BarChart
                data={config.data}
                labels={config.labels}
                width={config.width}
                height={config.height}
                color={config.color}
                horizontal={config.horizontal}
                stacked={config.stacked}
                className={config.className}
              />
            );
            break;
          case 'line':
            chartElement = (
              <LineChart
                data={config.data}
                labels={config.labels}
                width={config.width}
                height={config.height}
                color={config.color}
                showLine={config.showLine}
                showArea={config.showArea}
                showPoint={config.showPoint}
                smooth={config.smooth}
                stacked={config.stacked}
                className={config.className}
              />
            );
            break;
          case 'sparkline':
            chartElement = (
              <Sparkline
                data={config.data}
                width={config.width}
                height={config.height}
                color={config.color}
                showArea={config.showArea}
                showPoint={config.showPoint}
                smooth={config.smooth}
                className={config.className}
              />
            );
            break;
        }

        if (chartElement) {
          // Clear container and render Preact component
          div.innerHTML = '';
          render(chartElement, div);
        }
      } catch (err) {
        console.error('Failed to render chart:', err);
        div.innerHTML = '<div class="text-error">Failed to render chart</div>';
      }
    });
  }, [html]);

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="text-muted-foreground">Loading content...</div>
      </div>
    );
  }

  if (error) {
    return (
      <div className="flex items-center justify-center p-8">
        <div className="text-destructive">{error}</div>
      </div>
    );
  }

  return (
    <div ref={containerRef} className={`overflow-auto ${className || ''}`}>
      <div className="prose prose-invert max-w-none">
        <div
          dangerouslySetInnerHTML={{ __html: html }}
          className="markdown-content"
        />
      </div>
    </div>
  );
}

export default MarkdownRenderer;
