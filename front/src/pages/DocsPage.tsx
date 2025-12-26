import { useEffect, useState } from 'preact/hooks';
import { getDocBySlug, type DocFile } from '@/utils/docs';
import { DocsLayout } from '@/components/DocsLayout';
import { DocNavigation } from '@/components/DocNavigation';
import { useRouter } from '@/lib/router';

interface DocsPageProps {
  slug?: string;
}

export default function DocsPage({ slug = 'overview' }: DocsPageProps) {
  const [doc, setDoc] = useState<DocFile | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const { navigate } = useRouter();

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
