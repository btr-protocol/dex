import { useEffect, useState, useRef, useCallback } from 'preact/hooks';
import { render } from 'preact';
import { getDocBySlug, type DocFile } from '@/utils/docs';
import type { ChartConfig } from '@/components/charts';
import { PieChart, BarChart, LineChart } from '@/components/charts';
import { MermaidDiagramViewer } from './MermaidDiagramViewer';
import { Button } from '@components/ui/Button';
import { logger } from '@sdk/utils';

const log = logger.withContext('MarkdownRenderer');

interface MarkdownRendererProps {
  content?: string;
  slug?: string;
  className?: string;
  /** Max height for the scrollable container (e.g. "30vh") */
  maxHeight?: string;
  /** Callback when user scrolls to bottom */
  onScrollToBottom?: (atBottom: boolean) => void;
  /** Optional footer content that appears after the markdown (scrolls with it) */
  footerSlot?: preact.ComponentChildren;
}

/**
 * Renders pre-compiled markdown as HTML.
 *
 * All markdown is pre-compiled at build time by backend (scripts/precompile-markdown.ts)
 * with marked, prismjs, asciimath2ml, mermaid, and chartist. This component renders
 * pre-compiled HTML and injects chart components.
 *
 * Usage:
 * - With slug: <MarkdownRenderer slug="overview" />
 * - With content: <MarkdownRenderer content="<p>Html content</p>" />
 * - With scroll tracking: <MarkdownRenderer slug="terms" maxHeight="30vh" onScrollToBottom={(b) => ...} />
 * - With footer: <MarkdownRenderer slug="terms" footerSlot={<Checkbox>...</Checkbox>} />
 */
export function MarkdownRenderer({
  content: initialContent,
  slug,
  className,
  maxHeight,
  onScrollToBottom: externalOnScrollToBottom,
  footerSlot
}: MarkdownRendererProps) {
  const [html, setHtml] = useState<string>(initialContent || '');
  const [loading, setLoading] = useState(!initialContent);
  const [error, setError] = useState<string | null>(null);
  const [isRendered, setIsRendered] = useState(false);
  const scrollContainerRef = useRef<HTMLDivElement>(null);

  // Use a ref to avoid stale closures and ensure latest callback is used
  const onScrollToBottomRef = useRef(externalOnScrollToBottom);
  useEffect(() => {
    onScrollToBottomRef.current = externalOnScrollToBottom;
  }, [externalOnScrollToBottom]);

  // Stable callback that uses the latest ref value
  const notifyScrollState = useCallback((atBottom: boolean) => {
    onScrollToBottomRef.current?.(atBottom);
  }, []);

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
          log.error(`Failed to load markdown doc "${slug}"`, err);
          setError('Failed to load content');
          setHtml('');
        })
        .finally(() => {
          setLoading(false);
        });
    }
  }, [initialContent, slug]);

  // Render charts and mermaid diagrams after HTML is injected
  useEffect(() => {
    log.debug('Chart rendering effect triggered', { hasHtml: !!html, isRendered });

    // Only proceed if html is loaded and charts not yet rendered
    if (!html || isRendered) {
      return;
    }

    // Query DOM directly for markdown-content
    const markdownContent = document.querySelector('.markdown-content');
    if (!markdownContent) {
      return;
    }

    const chartContainers = markdownContent.querySelectorAll('.chart-container');
    log.debug(`Found ${chartContainers.length} chart containers`);

    chartContainers.forEach((container) => {
      const div = container as HTMLDivElement;
      const encodedConfig = div.getAttribute('data-chart-config');

      if (!encodedConfig) {
        return;
      }

      try {
        const config: ChartConfig = JSON.parse(decodeURIComponent(encodedConfig));
        log.debug('Parsed chart config', config.type);

        // Create chart element based on type
        let chartElement;

        switch (config.type) {
          case 'pie':
            chartElement = <PieChart {...config} />;
            break;
          case 'bar':
            chartElement = <BarChart {...config} />;
            break;
          case 'line':
            chartElement = <LineChart {...config} />;
            break;
          case 'sparkline':
            chartElement = <LineChart {...config} showArea={config.showArea ?? true} showPoint={config.showPoint ?? false} />;
            break;
          default:
            log.error('Unknown chart type', config.type);
            return;
        }

        if (chartElement) {
          // Clear container and render Preact component directly
          div.innerHTML = '';
          render(chartElement, div);
          log.debug('Chart rendered successfully', config.type);
        }
      } catch (err) {
        log.error('Failed to render chart', err);
        const errorMessage = err instanceof Error ? err.message : String(err);
        div.innerHTML = `<div class="p-4 bg-red-900/20 border border-red-500 text-red-500 rounded">
          <div class="font-bold">Failed to render chart</div>
          <div class="text-sm mt-1">${errorMessage}</div>
        </div>`;
      }
    });

    // Render mermaid diagrams
    const mermaidDiagrams = markdownContent.querySelectorAll('.mermaid-diagram');

    mermaidDiagrams.forEach((container) => {
      const div = container as HTMLDivElement;
      const svgContent = div.innerHTML;

      try {
        const diagramElement = <MermaidDiagramViewer svgContent={svgContent} />;
        div.innerHTML = '';
        render(diagramElement, div);
        log.debug('Mermaid diagram rendered successfully');
      } catch (err) {
        log.error('Failed to render mermaid diagram', err);
        div.innerHTML = '<div class="text-error">Failed to render diagram</div>';
      }
    });

    // Mark as rendered
    setIsRendered(true);
  }, [html]);

  // Handle scroll detection - only after content is fully rendered
  useEffect(() => {
    // Don't set up scroll listeners until content is loaded and rendered
    if (!maxHeight || !scrollContainerRef.current || !isRendered) {
      // While loading, explicitly notify that we're not at bottom
      if (maxHeight && !isRendered) {
        notifyScrollState(false);
      }
      return;
    }

    const container = scrollContainerRef.current;
    let resizeObserver: ResizeObserver | null = null;

    const checkScrollState = () => {
      const { scrollTop, scrollHeight, clientHeight } = container;
      const isScrollable = scrollHeight > clientHeight + 1; // Small tolerance
      // If not scrollable (content fits), consider it "at bottom" automatically
      // If scrollable, only consider "at bottom" when near the end
      const isAtBottom = !isScrollable || (scrollHeight - scrollTop - clientHeight < 10);

      console.log('[MarkdownRenderer] scroll state:', { scrollHeight, clientHeight, scrollTop, isScrollable, isAtBottom });
      notifyScrollState(isAtBottom);
    };

    const handleScroll = () => checkScrollState();

    // Wait for DOM to reflow before checking initial state
    const rafId = requestAnimationFrame(() => {
      checkScrollState();
    });

    // Also check after delays to account for async rendering
    const timeoutId = setTimeout(() => checkScrollState(), 100);
    const timeoutId2 = setTimeout(() => checkScrollState(), 500);

    // Listen to scroll events
    container.addEventListener('scroll', handleScroll, { passive: true });

    // Use ResizeObserver to detect content size changes
    resizeObserver = new ResizeObserver(() => checkScrollState());
    resizeObserver.observe(container);

    return () => {
      cancelAnimationFrame(rafId);
      clearTimeout(timeoutId);
      clearTimeout(timeoutId2);
      container.removeEventListener('scroll', handleScroll);
      resizeObserver?.disconnect();
    };
  }, [maxHeight, isRendered, notifyScrollState]);

  const scrollToBottom = () => {
    const container = scrollContainerRef.current;
    if (container) {
      container.scrollTo({
        top: container.scrollHeight,
        behavior: 'smooth'
      });
    }
  };

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

  const content = (
    <div className="prose prose-invert max-w-none">
      <div
        dangerouslySetInnerHTML={{ __html: html }}
        className="markdown-content"
      />
    </div>
  );

  const scrollableContent = (
    <>
      {content}
      {footerSlot}
    </>
  );

  // If maxHeight is provided, wrap in scrollable container with scroll button
  if (maxHeight) {
    const downArrowIcon = (
      <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 5v14M19 12l-7 7-7-7"/>
      </svg>
    );

    return (
      <div className="relative rounded-md overflow-hidden">
        <div
          ref={scrollContainerRef}
          className="overflow-y-auto"
          style={{ maxHeight }}
        >
          {/* Inner wrapper with className for padding/text styles - scrolls with content */}
          <div className={className || ''}>
            {scrollableContent}
          </div>
        </div>

        {/* Scroll to bottom button - always visible when maxHeight is set */}
        <div className="absolute bottom-3 right-2 z-10">
          <Button
            variant="glass"
            size="default"
            onClick={scrollToBottom}
            leftIcon={downArrowIcon}
            aria-label="Scroll to bottom"
          />
        </div>
      </div>
    );
  }

  return (
    <div className={className || ''}>
      {scrollableContent}
    </div>
  );
}

export default MarkdownRenderer;
