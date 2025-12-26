import { JSX, Ref } from 'preact';
import { cn } from '@utils/cn';
import { cva } from '@utils/cva';

type CardVariant = 'default' | 'nested' | 'inset';

export interface CardProps extends JSX.HTMLAttributes<HTMLDivElement> {
  variant?: CardVariant;
  ref?: Ref<HTMLDivElement>;
}

const cardVariants = cva('', {
  variants: {
    variant: {
      default: 'bg-bg-1 border border-border rounded-2xl shadow-sm',
      nested: 'bg-bg-2 border border-border rounded-xl',
      inset: 'bg-bg-3 rounded-lg',
    },
  },
  defaultVariants: {
    variant: 'default',
  },
});

export function Card({ className, variant = 'default', ...props }: CardProps) {
  return (
    <div
      className={cardVariants({ variant, className })}
      {...props}
    />
  );
}

export function CardHeader(props: JSX.HTMLAttributes<HTMLDivElement> & { ref?: Ref<HTMLDivElement> }) {
  const { className, ...rest } = props;
  return (
    <div
      className={cn('flex flex-col space-y-1.5 p-6', className)}
      {...rest}
    />
  );
}

export function CardTitle(props: JSX.HTMLAttributes<HTMLHeadingElement> & { ref?: Ref<HTMLHeadingElement> }) {
  const { className, ...rest } = props;
  return (
    <h3
      className={cn('text-xl font-bold leading-none tracking-tight', className)}
      {...rest}
    />
  );
}

export function CardDescription(props: JSX.HTMLAttributes<HTMLParagraphElement> & { ref?: Ref<HTMLParagraphElement> }) {
  const { className, ...rest } = props;
  return (
    <p
      className={cn('text-sm text-muted-foreground', className)}
      {...rest}
    />
  );
}

export function CardContent(props: JSX.HTMLAttributes<HTMLDivElement> & { ref?: Ref<HTMLDivElement> }) {
  const { className, ...rest } = props;
  return (
    <div className={cn('p-6 pt-0', className)} {...rest} />
  );
}

export function CardFooter(props: JSX.HTMLAttributes<HTMLDivElement> & { ref?: Ref<HTMLDivElement> }) {
  const { className, ...rest } = props;
  return (
    <div
      className={cn('flex items-center p-6 pt-0', className)}
      {...rest}
    />
  );
}
