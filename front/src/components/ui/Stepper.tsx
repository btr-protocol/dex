import { Check } from 'lucide-react';
import { cn } from '@utils/cn';

export interface Step {
  label: string;
  description?: string;
}

interface StepperProps {
  steps: Step[];
  currentStep: number;
  orientation?: 'horizontal' | 'vertical';
  className?: string;
}

export function Stepper({ steps, currentStep, orientation = 'horizontal', className }: StepperProps) {
  const isHorizontal = orientation === 'horizontal';

  return (
    <div className={cn(
      'flex',
      isHorizontal ? 'flex-row items-center' : 'flex-col',
      className
    )}>
      {steps.map((step, index) => {
        const isCompleted = index < currentStep;
        const isCurrent = index === currentStep;
        const isUpcoming = index > currentStep;

        return (
          <div
            key={index}
            className={cn(
              'flex items-center',
              isHorizontal ? 'flex-1' : 'flex-row w-full',
              !isHorizontal && index !== steps.length - 1 && 'pb-8'
            )}
          >
            {/* Step indicator */}
            <div className={cn('flex items-center', isHorizontal ? 'flex-col' : 'flex-row gap-4')}>
              {/* Circle with number/check */}
              <div className={cn(
                'flex items-center justify-center rounded-full border-2 transition-all',
                isHorizontal ? 'w-10 h-10' : 'w-12 h-12',
                isCompleted && 'bg-primary border-primary',
                isCurrent && 'bg-primary/10 border-primary',
                isUpcoming && 'bg-bg-2 border-border'
              )}>
                {isCompleted ? (
                  <Check className={cn('text-primary-foreground', isHorizontal ? 'w-5 h-5' : 'w-6 h-6')} />
                ) : (
                  <span className={cn(
                    'font-semibold',
                    isHorizontal ? 'text-sm' : 'text-base',
                    isCurrent && 'text-primary',
                    isUpcoming && 'text-muted-foreground'
                  )}>
                    {index + 1}
                  </span>
                )}
              </div>

              {/* Label */}
              <div className={cn(
                isHorizontal ? 'mt-2 text-center' : 'flex-1'
              )}>
                <div className={cn(
                  'font-medium transition-colors',
                  isHorizontal ? 'text-xs' : 'text-sm',
                  (isCompleted || isCurrent) && 'text-foreground',
                  isUpcoming && 'text-muted-foreground'
                )}>
                  {step.label}
                </div>
                {step.description && !isHorizontal && (
                  <div className="text-xs text-muted-foreground mt-1">
                    {step.description}
                  </div>
                )}
              </div>
            </div>

            {/* Connector line */}
            {index !== steps.length - 1 && (
              <div className={cn(
                'transition-colors',
                isHorizontal ? 'flex-1 h-0.5 mx-2' : 'w-0.5 h-8 ml-6 -mt-8',
                (isCompleted || (isCurrent && index < currentStep)) ? 'bg-primary' : 'bg-border'
              )} />
            )}
          </div>
        );
      })}
    </div>
  );
}
