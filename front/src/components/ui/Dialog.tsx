import { FunctionalComponent, ComponentChildren, createContext } from 'preact'
import { useState, useRef, useEffect, useContext } from 'preact/hooks'
import { createPortal } from 'preact/compat'
import { CloseButton } from './CloseButton'
import { cn } from '@utils/cn'

interface DialogContextType {
  isOpen: boolean
  setIsOpen: (open: boolean) => void
  contentRef: { current: HTMLDivElement | null }
}

const DialogContext = createContext<DialogContextType | undefined>(undefined)

function useDialogContext() {
  const ctx = useContext(DialogContext)
  if (!ctx) {
    throw new Error('Dialog components must be used within Dialog')
  }
  return ctx
}

// Root Dialog component - manages state
interface DialogProps {
  open?: boolean
  onOpenChange?: (open: boolean) => void
  children: ComponentChildren
}

const Dialog: FunctionalComponent<DialogProps> = ({
  open: controlledOpen,
  onOpenChange,
  children,
}) => {
  const [uncontrolledOpen, setUncontrolledOpen] = useState(false)
  const contentRef = useRef<HTMLDivElement>(null)
  const isControlled = controlledOpen !== undefined
  const isOpen = isControlled ? controlledOpen : uncontrolledOpen

  const setIsOpen = (open: boolean) => {
    if (isControlled) {
      onOpenChange?.(open)
    } else {
      setUncontrolledOpen(open)
    }
  }

  return (
    <DialogContext.Provider value={{ isOpen, setIsOpen, contentRef }}>
      {children}
    </DialogContext.Provider>
  )
}

// Trigger - opens dialog on click
const DialogTrigger: FunctionalComponent<{ children: ComponentChildren }> = ({ children }) => {
  const { setIsOpen } = useDialogContext()
  return (
    <button
      type="button"
      onClick={() => setIsOpen(true)}
    >
      {children}
    </button>
  )
}

// Portal - renders dialog outside main tree
const DialogPortal: FunctionalComponent<{ children: ComponentChildren }> = ({ children }) => {
  const { isOpen } = useDialogContext()

  if (!isOpen) return null

  return createPortal(children, document.body)
}

// Overlay - backdrop
const DialogOverlay: FunctionalComponent<{ className?: string; onPointerDownOutside?: (e: PointerEvent) => void }> = ({
  className,
  onPointerDownOutside,
}) => {
  const { isOpen, setIsOpen } = useDialogContext()
  const overlayRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!isOpen || !overlayRef.current) return

    const handlePointerDown = (e: PointerEvent) => {
      if (e.target === overlayRef.current) {
        onPointerDownOutside?.(e)
        setIsOpen(false)
      }
    }

    overlayRef.current.addEventListener('pointerdown', handlePointerDown)
    return () => {
      overlayRef.current?.removeEventListener('pointerdown', handlePointerDown)
    }
  }, [isOpen, setIsOpen, onPointerDownOutside])

  // Don't render overlay when dialog is closed
  if (!isOpen) return null

  return (
    <div
      ref={overlayRef}
      className={cn(
        'fixed inset-0 z-50 bg-bg-0/50 backdrop-blur-sm',
        'data-[state=open]:animate-in data-[state=closed]:animate-out',
        'data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0',
        className
      )}
      data-state="open"
    />
  )
}

// Content - main dialog container with focus trap
interface DialogContentProps {
  className?: string
  children: ComponentChildren
  closable?: boolean
  variant?: 'default' | 'flush'
}

const DialogContent: FunctionalComponent<DialogContentProps> = ({
  className,
  children,
  closable = true,
  variant = 'default',
}) => {
  const { isOpen, setIsOpen, contentRef } = useDialogContext()

  useEffect(() => {
    if (!isOpen || !contentRef.current) return

    // Get all focusable elements
    const getFocusableElements = (): HTMLElement[] => {
      const selector = [
        'a[href]',
        'button:not([disabled])',
        'input:not([disabled])',
        'select:not([disabled])',
        'textarea:not([disabled])',
        '[tabindex]:not([tabindex="-1"])',
      ].join(',')
      return Array.from(contentRef.current!.querySelectorAll(selector))
    }

    // Focus first element
    const focusables = getFocusableElements()
    if (focusables.length > 0) {
      setTimeout(() => focusables[0].focus(), 0)
    }

    // Handle keyboard
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        if (closable) {
          setIsOpen(false)
        }
        return
      }

      if (e.key === 'Tab') {
        const focusables = getFocusableElements()
        if (focusables.length === 0) {
          e.preventDefault()
          return
        }

        const currentIndex = focusables.indexOf(document.activeElement as HTMLElement)
        let nextIndex = currentIndex + (e.shiftKey ? -1 : 1)

        if (nextIndex < 0) {
          nextIndex = focusables.length - 1
        } else if (nextIndex >= focusables.length) {
          nextIndex = 0
        }

        e.preventDefault()
        focusables[nextIndex].focus()
      }
    }

    contentRef.current.addEventListener('keydown', handleKeyDown)

    // Lock body scroll
    const originalOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    return () => {
      contentRef.current?.removeEventListener('keydown', handleKeyDown)
      document.body.style.overflow = originalOverflow
    }
  }, [isOpen, setIsOpen, closable])

  // Don't render anything when dialog is closed
  if (!isOpen) return null

  return (
    <div
      ref={contentRef}
      className={cn(
        'fixed left-[50%] top-[50%] z-50 grid w-full max-w-lg translate-x-[-50%] translate-y-[-50%]',
        'border bg-card shadow-lg duration-200',
        'data-[state=open]:animate-in data-[state=closed]:animate-out',
        'data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0',
        'data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95',
        'data-[state=closed]:slide-out-to-left-1/2 data-[state=closed]:slide-out-to-top-[48%]',
        'data-[state=open]:slide-in-from-left-1/2 data-[state=open]:slide-in-from-top-[48%]',
        'sm:rounded-lg font-title',
        variant === 'flush' ? '' : 'gap-4 p-6',
        className
      )}
      role="dialog"
      aria-modal="true"
      data-state="open"
    >
      {children}
      {closable && (
        <CloseButton
          onClick={() => setIsOpen(false)}
          size={20}
          className="absolute right-3 top-3"
        />
      )}
    </div>
  )
}

// Header
const DialogHeader: FunctionalComponent<{ className?: string; children: ComponentChildren }> = ({
  className,
  children,
}) => (
  <div
    className={cn(
      'flex flex-col space-y-1.5 text-center sm:text-left',
      className
    )}
  >
    {children}
  </div>
)

// Footer
const DialogFooter: FunctionalComponent<{ className?: string; children: ComponentChildren }> = ({
  className,
  children,
}) => (
  <div
    className={cn(
      'flex flex-col-reverse sm:flex-row sm:justify-end sm:space-x-2',
      className
    )}
  >
    {children}
  </div>
)

// Title
const DialogTitle: FunctionalComponent<{ className?: string; children: ComponentChildren }> = ({
  className,
  children,
}) => (
  <h2
    className={cn(
      'text-lg font-semibold leading-none tracking-tight',
      className
    )}
  >
    {children}
  </h2>
)

// Description
const DialogDescription: FunctionalComponent<{ className?: string; children: ComponentChildren }> = ({
  className,
  children,
}) => (
  <p className={cn('text-sm text-muted-foreground', className)}>
    {children}
  </p>
)

// Close button
const DialogClose: FunctionalComponent<{ children?: ComponentChildren }> = ({ children }) => {
  const { setIsOpen } = useDialogContext()
  return (
    <button
      type="button"
      onClick={() => setIsOpen(false)}
      aria-label="Close"
    >
      {children}
    </button>
  )
}

export {
  Dialog,
  DialogPortal,
  DialogOverlay,
  DialogClose,
  DialogTrigger,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
}