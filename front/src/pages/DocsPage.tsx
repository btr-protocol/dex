import { useEffect, useState } from 'preact/hooks';
import { getDocBySlug, type DocFile } from '@/utils/docs';
import { DocsLayout } from '@components/features/docs';
import { DocNavigation } from '@components/features/docs';
import { useRouter } from '@/lib/router';

interface DocsPageProps {
  slug?: string;
}

export function DocsPage({ slug: slugProp }: DocsPageProps) {
  const [doc, setDoc] = useState<DocFile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const { navigate, path } = useRouter();

  // Extract slug from URL path (e.g., /docs/2.5-emission-control -> 2.5-emission-control)
  const slug = slugProp || path.replace(/^\/docs\/?/, '') || 'overview';

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

  if (error || (!loading && !doc)) {
    return (
      <DocsLayout loading={false}>
        <div className="flex items-center justify-center py-20">
          <div className="text-destructive">
            {error || 'Document not found'}
          </div>
        </div>
      </DocsLayout>
    );
  }

  return (
    <DocsLayout currentSlug={slug} loading={loading}>
      {doc && (
        <>
          <article
            className="markdown-content"
            dangerouslySetInnerHTML={{ __html: doc.content }}
          />
          <DocNavigation
            prev={doc.prev || undefined}
            next={doc.next || undefined}
            onNavigate={navigate}
          />
        </>
      )}
    </DocsLayout>
  );
}
