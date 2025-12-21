import PageContainer from '@/components/layout/PageContainer';

interface ViewEmptyStateProps {
    title: string;
    description: string;
}

export function ViewEmptyState({ title, description }: ViewEmptyStateProps) {
    return (
        <PageContainer title={title}>
            <div className="flex flex-col items-center justify-center min-h-[60vh] gap-6">
                <img
                    src="/build.svg"
                    alt="Under construction"
                    className="w-32 h-32 opacity-50"
                />
                <div className="text-center max-w-md">
                    <h2 className="text-2xl font-bold text-foreground mb-2">{title}</h2>
                    <p className="text-muted-foreground">{description}</p>
                </div>
            </div>
        </PageContainer>
    );
}
