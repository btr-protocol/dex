import { Button } from '@components/ui/Button';
import { ButtonGroup } from '@components/ui/ButtonGroup';
import { cn } from '@utils/cn';
import { SwapStore } from '@/lib/swap/SwapStore';

export function DirectionToggle({ store }: { store: SwapStore }) {
  return (
    <ButtonGroup direction="horizontal" variant="outlined" className="bg-white/5">
      <Button
        onClick={() => store.setDirection('sell')}
        size="compact-xl"
        variant="ghost"
        className={cn("font-title min-w-[4rem]", store.direction.value === 'sell' ? 'btn-selected' : 'btn-unselected')}
      >
        Sell
      </Button>
      <Button
        onClick={() => store.setDirection('buy')}
        size="compact-xl"
        variant="ghost"
        className={cn("font-title min-w-[4rem]", store.direction.value === 'buy' ? 'btn-selected' : 'btn-unselected')}
      >
        Buy
      </Button>
    </ButtonGroup>
  );
}
