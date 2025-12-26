import { Icon } from '@components/ui/Icon';

export interface SearchResult {
  id: string;
  title: string;
  desc?: string;
  content?: string;
  path: string;
  section?: string;
  cat?: string;
}

export interface SearchResultListProps {
  title: string;
  icon: string;
  results: SearchResult[];
  selectedIndex: number;
  onSelect: (path: string, section?: string) => void;
  renderIcon?: (result: SearchResult) => React.ReactNode;
}

export function SearchResultList({
  title,
  icon,
  results,
  selectedIndex,
  onSelect,
  renderIcon,
}: SearchResultListProps) {
  if (results.length === 0) {
    return null;
  }

  return (
    <>
      <div className="px-3 py-2 text-xs font-semibold text-muted-foreground uppercase flex items-center gap-2">
        <Icon name={icon} className="w-3.5 h-3.5" />
        {title}
      </div>
      <div className="flex flex-col gap-1 mb-4">
        {results.map((result, idx) => (
          <button
            key={result.id}
            onClick={() => onSelect(result.path, result.section)}
            className={`flex items-center gap-3 px-3 py-2.5 rounded-sm text-left transition-colors ${
              selectedIndex === idx
                ? 'bg-bg-2'
                : 'hover:bg-bg-2'
            }`}
          >
            {renderIcon ? (
              renderIcon(result)
            ) : (
              <Icon name="arrow-right" className="w-4 h-4 shrink-0" />
            )}
            <div className="flex-1">
              <div className="font-semibold text-sm">{result.title}</div>
              {result.desc && (
                <div className="text-xs text-muted-foreground mt-0.5 line-clamp-1">
                  {result.desc}
                </div>
              )}
              {result.content && (
                <div
                  className="text-xs text-muted-foreground mt-0.5 line-clamp-2 search-excerpt"
                  dangerouslySetInnerHTML={{ __html: result.content }}
                />
              )}
            </div>
            <Icon name="arrow-right" className="w-4 h-4 shrink-0" />
          </button>
        ))}
      </div>
    </>
  );
}
