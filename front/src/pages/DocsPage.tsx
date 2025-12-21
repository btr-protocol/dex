import { useEffect, useState } from 'react';
import { getDocBySlug, type DocFile } from '@/utils/docs';
import MarkdownRenderer from '@/components/MarkdownRenderer';

interface DocsPageProps {
  slug?: string;
}

export default function DocsPage({ slug = 'overview' }: DocsPageProps) {
  const [doc, setDoc] = useState<DocFile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (slug) {
      setLoading(true);
      setError(null);
      getDocBySlug(slug)
        .then((docFile) => {
          if (docFile) {
            setDoc(docFile);
            document.title = `${docFile.title} - BTR Documentation`;
          } else {
            setError('Document not found');
          }
          setLoading(false);
        })
        .catch((error) => {
          console.error('Error loading doc:', error);
          setError('Failed to load document');
          setDoc(null);
          setLoading(false);
        });
    }
  }, [slug]);

  if (loading) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="text-muted-foreground">Loading documentation...</div>
      </div>
    );
  }

  if (error || !doc) {
    return (
      <div className="min-h-screen bg-background flex items-center justify-center">
        <div className="text-destructive">
          {error || 'Document not found'}
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-background">
      <div className="container mx-auto px-4 py-8 max-w-4xl">
        <div className="mb-8">
          <h1 className="text-4xl font-bold mb-2">{doc.title}</h1>
          {doc.category && (
            <div className="text-sm text-muted-foreground">
              Category: {doc.category}
            </div>
          )}
        </div>

        <MarkdownRenderer content={doc.content} />
      </div>
    </div>
  );
}
