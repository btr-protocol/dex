import { PageContainer } from '@/components/layout/PageContainer';
import { MaskIcon } from '@/components/ui/MaskIcon';

interface ViewEmptyStateProps {
    title: string;
    description: string;
}

export function ViewEmptyState({ title, description }: ViewEmptyStateProps) {
    return (
        <PageContainer title={title}>
            <div className="flex flex-col items-center justify-center min-h-[60vh] gap-6">
                <MaskIcon
                    src="/icons/build.svg"
                    width="8rem"
                    height="8rem"
                    color="var(--primary)"
                    aria-label="Under construction"
                />
                <div className="text-center max-w-md">
                    <p className="text-fg-1 max-w-[300px]">{description}</p>
                </div>
            </div>
        </PageContainer>
    );
}
