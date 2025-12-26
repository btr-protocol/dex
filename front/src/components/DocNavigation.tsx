import { Icon } from './ui/Icon';
import { FlexRow, FlexBetween } from './ui/Flex';
import { Caption } from './ui/Text';
import { Divider } from './ui/Divider';

interface DocPage {
  path: string;
  label: string;
}

interface DocNavigationProps {
  prev?: DocPage;
  next?: DocPage;
  onNavigate: (path: string) => void;
}

export function DocNavigation({ prev, next, onNavigate }: DocNavigationProps) {
  if (!prev && !next) return null;

  return (
    <>
      <Divider className="mt-12" />
      <FlexBetween className="gap-4 pt-8">
      {prev ? (
        <button
          onClick={() => onNavigate(prev.path)}
          className="flex-1 p-4 rounded border border-border hover:bg-bg-2 transition-colors text-left"
        >
          <FlexRow gap="2">
            <Icon name="caret-left" className="w-5 h-5 shrink-0" />
            <div>
              <Caption className="leading-none">Previous</Caption>
              <div className="font-medium">{prev.label}</div>
            </div>
          </FlexRow>
        </button>
      ) : (
        <div className="flex-1" />
      )}

      {next ? (
        <button
          onClick={() => onNavigate(next.path)}
          className="flex-1 p-4 rounded border border-border hover:bg-bg-2 transition-colors text-right"
        >
          <FlexRow gap="2" className="justify-end">
            <div>
              <Caption className="leading-none">Next</Caption>
              <div className="font-medium">{next.label}</div>
            </div>
            <Icon name="caret-right" className="w-5 h-5 shrink-0" />
          </FlexRow>
        </button>
      ) : (
        <div className="flex-1" />
      )}
    </FlexBetween>
    </>
  );
}
