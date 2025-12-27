import { useEffect, useState } from 'preact/hooks';
import { getDocBySlug, type DocFile } from '@/utils/docs';

interface MarkdownRendererProps {
  content?: string;
  slug?: string;
  className?: string;
}

/**
 * Renders pre-compiled markdown as HTML.
 *
 * All markdown is pre-compiled at build time by the backend (scripts/precompile-markdown.ts)
 * with marked, prismjs, asciimath2ml, and mermaid. This component simply renders the
 * pre-compiled HTML without any runtime dependencies.
 *
 * Usage:
 * - With slug: <MarkdownRenderer slug="overview" />
 * - With content: <MarkdownRenderer content="<p>Html content</p>" />
 */
export function MarkdownRenderer({ content: initialContent, slug, className }: MarkdownRendererProps) {
  const [html, setHtml] = useState<string>(initialContent || '');
  const [loading, setLoading] = useState(!initialContent);
  const [error, setError] = useState<string | null>(null);

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
    <div className={`overflow-auto ${className || ''}`}>
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
