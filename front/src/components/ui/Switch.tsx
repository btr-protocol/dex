import { FunctionalComponent } from 'preact'
import type { HTMLAttributes } from 'preact/compat'
import { useRef } from 'preact/hooks'
import { cn } from '@utils/cn'

export interface SwitchProps extends HTMLAttributes<HTMLInputElement> {
  checked?: boolean
  onCheckedChange?: (checked: boolean) => void
  disabled?: boolean
}

const Switch: FunctionalComponent<SwitchProps> = ({
  className,
  checked,
  onCheckedChange,
  disabled,
  ...props
}) => {
  const inputRef = useRef<HTMLInputElement>(null)

  const handleChange = (e: Event) => {
    const target = e.target as HTMLInputElement
    onCheckedChange?.(target.checked)
  }

  return (
    <div className="relative inline-flex items-center">
      <input
        ref={inputRef}
        type="checkbox"
        role="switch"
        aria-checked={checked}
        checked={checked}
        onChange={handleChange}
        disabled={disabled}
        className={cn(
          'peer h-5 w-9 shrink-0 cursor-pointer rounded-full',
          'border border-border transition-colors',
          'focus-visible:outline-none focus-visible:ring-2',
          'focus-visible:ring-primary focus-visible:ring-offset-2',
          'focus-visible:ring-offset-background',
          'disabled:cursor-not-allowed disabled:opacity-50',
          'appearance-none',
          'bg-bg-2 checked:bg-bg-primary',
          className
        )}
        {...props}
      />
      <div
        className={cn(
          'pointer-events-none absolute left-0.5 block h-4 w-4 rounded-full',
          'shadow-sm ring-0 transition-all',
          'translate-x-0 peer-checked:translate-x-4',
          'bg-fg-3 peer-checked:bg-primary',
          disabled && 'opacity-50'
        )}
      />
    </div>
  )
}

Switch.displayName = 'Switch'

export { Switch }
