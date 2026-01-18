import { FlexCol, FlexRow } from '@components/ui/Flex';
import { Icon } from '@components/ui/Icon';
import type { ArchivistSource } from '@/types/archivist';
import { getCategoryIcon, getCategoryLabel } from '@/constants/categories';
import { formatNumber } from '@utils/format';

interface SourcesPanelProps {
  sources: ArchivistSource[];
}

export function SourcesPanel({ sources }: SourcesPanelProps) {
  if (sources.length === 0) {
    return (
      <FlexCol gap="0.5">
        <div className="text-xs text-fg-3">
          Ask a question to see relevant sources
        </div>
      </FlexCol>
    );
  }

  return (
    <div className="divide-y divide-border">
      {sources.map((source, idx) => (
        <SourceItem key={idx} source={source} index={idx + 1} />
      ))}
    </div>
  );
}

interface SourceItemProps {
  source: ArchivistSource;
  index: number;
}

function SourceItem({ source, index }: SourceItemProps) {
  const handleClick = () => {
    console.log('Open source:', source);
  };

  return (
    <button
      onClick={handleClick}
      className="w-full text-left py-1 hover:text-fg-1 transition-colors group text-fg-2"
    >
      <FlexRow gap="2" className="items-start">
        <Icon name={getCategoryIcon(source.category)} className="w-5 h-5 flex-shrink-0 text-fg-2" />
        <FlexCol gap="0.5" className="flex-1 min-w-0">
          <FlexRow gap="2" className="items-center">
            <span className="text-xs font-semibold text-primary">
              [{index}]
            </span>
            <span className="text-xs text-fg-3">
              {getCategoryLabel(source.category)}
            </span>
            {source.language && (
              <span className="text-xs text-fg-3">
                {source.language}
              </span>
            )}
          </FlexRow>

          <div className="text-xs font-medium truncate">
            {source.displayName}
          </div>

          {source.contract && (
            <div className="text-xs text-fg-3">
              {source.contract}
            </div>
          )}

          {source.function && (
            <div className="text-xs text-fg-3">
              {source.function}
            </div>
          )}

          {source.section && (
            <div className="text-xs text-fg-3">
              {source.section}
            </div>
          )}

          {source.lineRange && (
            <div className="text-xs text-fg-3">
              {source.lineRange[0]}-{source.lineRange[1]}
            </div>
          )}

          <div className="text-xs text-fg-3 mt-1 line-clamp-2">
            {source.preview}
          </div>

          <div className="text-xs text-fg-3">
            {formatNumber(source.score * 100, 0)}% relevance
          </div>
        </FlexCol>

        <Icon
          name="external-link"
          className="w-4 h-4 opacity-0 group-hover:opacity-100 transition-opacity flex-shrink-0"
        />
      </FlexRow>
    </button>
  );
}
