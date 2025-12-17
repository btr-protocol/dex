import { createContext } from 'preact';
import { useContext, useState, useCallback } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';

interface ExpandableControls {
  open: () => void;
  close: () => void;
}

interface AccordionContextValue {
  autoClose: boolean;
  activeExpandable: string | null;
  expandables: Map<string, ExpandableControls>;
  registerExpandable: (id: string, controls: ExpandableControls) => void;
  unregisterExpandable: (id: string) => void;
  setActiveExpandable: (id: string | null) => void;
}

export const AccordionContext = createContext<AccordionContextValue | null>(null);

export interface AccordionProps {
  children: ReactNode;
  autoClose?: boolean;
  defaultOpen?: string;
  className?: string;
}

export function Accordion({ children, autoClose = true, defaultOpen = '', className = '' }: AccordionProps) {
  const [activeExpandable, setActiveExpandableState] = useState<string | null>(defaultOpen || null);
  const [expandables] = useState(() => new Map<string, ExpandableControls>());

  const registerExpandable = useCallback(
    (id: string, controls: ExpandableControls) => {
      expandables.set(id, controls);
      // Auto-open the default expandable when it's registered
      if (defaultOpen === id) {
        controls.open();
      }
    },
    [defaultOpen, expandables]
  );

  const unregisterExpandable = useCallback(
    (id: string) => {
      expandables.delete(id);
    },
    [expandables]
  );

  const setActiveExpandable = useCallback(
    (id: string | null) => {
      if (autoClose && id) {
        // Close all other expandables
        expandables.forEach((controls, expandableId) => {
          if (expandableId !== id) {
            controls.close();
          }
        });
      }
      setActiveExpandableState(id);
    },
    [autoClose, expandables]
  );

  const contextValue: AccordionContextValue = {
    autoClose,
    activeExpandable,
    expandables,
    registerExpandable,
    unregisterExpandable,
    setActiveExpandable,
  };

  return (
    <AccordionContext.Provider value={contextValue}>
      <div className={`w-full flex flex-col ${className}`}>{children}</div>
    </AccordionContext.Provider>
  );
}

export function useAccordion() {
  const context = useContext(AccordionContext);
  return context;
}
