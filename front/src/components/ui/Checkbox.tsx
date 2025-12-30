import { FunctionalComponent } from 'preact'
import type { HTMLAttributes } from 'preact/compat'
import { useRef } from 'preact/hooks'
import { Icon } from './Icon'
import { cn } from '@utils/cn'

export interface CheckboxProps extends HTMLAttributes<HTMLInputElement> {
  checked?: boolean
  onCheckedChange?: (checked: boolean) => void
  disabled?: boolean
}

const Checkbox: FunctionalComponent<CheckboxProps> = ({
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
        checked={checked}
        onChange={handleChange}
        disabled={disabled}
        className={cn(
          'peer h-5 w-5 shrink-0 rounded-xs border border-primary',
          'ring-offset-background focus-visible:outline-none',
          'focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2',
          'disabled:cursor-not-allowed disabled:opacity-50',
          'appearance-none cursor-pointer',
          'checked:bg-bg-primary checked:border-primary',
          className
        )}
        {...props}
      />
      {checked && (
        <div
          className={cn(
            'pointer-events-none absolute inset-0 flex items-center justify-center',
            disabled && 'opacity-50'
          )}
        >
          <Icon name="check" className="h-5 w-5 text-primary" />
        </div>
      )}
    </div>
  )
}

Checkbox.displayName = 'Checkbox'

export { Checkbox }
