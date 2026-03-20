import { FlexCol, FlexRow } from '@components/ui/Flex';
import { Icon } from '@components/ui/Icon';
import { Popover } from '@components/ui/FloatingPanel';
import type { ArchivistSource } from '@/types/archivist';
import { getCategoryIcon, getCategoryLabel } from '@/constants/categories';
import { formatNumber } from '@sdk/utils/format';
import { logger } from '@sdk/utils';

const log = logger.withContext('sourcesPanel');

interface SourcesPanelProps {
  sources: ArchivistSource[];
}

export function SourcesPanel({ sources }: SourcesPanelProps) {
  if (sources.length === 0) {
    return (
      <FlexCol gap="0.5">
        <div className="text-xs text-fg-3 pl-4 py-3">
          Sources will be loaded upon response.
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
    log.debug('Open source', source);
  };

  // Build location string for secondary row
  const locationParts = [
    source.contract,
    source.function,
    source.section,
    source.lineRange && `L${source.lineRange[0]}-${source.lineRange[1]}`,
  ].filter(Boolean);

  const locationStr = locationParts.length > 0 ? locationParts.join(' · ') : undefined;

  // Popover content with preview and relevance
  const popoverContent = (
    <div className="w-64">
      {source.preview && (
        <div className="text-xs text-fg-2 mb-2 line-clamp-4">
          {source.preview}
        </div>
      )}
      <div className="text-xs text-fg-3 font-medium">
        {formatNumber(source.score * 100, 0)}% relevance
      </div>
    </div>
  );

  return (
    <Popover content={popoverContent} side="left" maxWidth="16rem">
      <button
        onClick={handleClick}
        className="w-full text-left py-2 hover:text-fg-1 transition-colors group text-fg-2"
      >
        <FlexRow gap="2" className="items-start">
          <Icon name={getCategoryIcon(source.category)} className="w-4 h-4 flex-shrink-0 text-fg-3 mt-0.5" />
          <FlexCol gap="0.5" className="flex-1 min-w-0">
            {/* First row: icon + title with index */}
            <FlexRow gap="2" className="items-center">
              <span className="text-xs font-medium text-primary">
                [{index}]
              </span>
              <span className="text-xs font-medium truncate">
                {source.displayName}
              </span>
            </FlexRow>

            {/* Second row: category + location */}
            <FlexRow gap="2" className="items-center text-xs text-fg-3">
              <span>{getCategoryLabel(source.category)}</span>
              {locationStr && <span>· {locationStr}</span>}
            </FlexRow>
          </FlexCol>

          <Icon
            name="external-link"
            className="w-3.5 h-3.5 opacity-0 group-hover:opacity-100 transition-opacity flex-shrink-0 mt-0.5"
          />
        </FlexRow>
      </button>
    </Popover>
  );
}
