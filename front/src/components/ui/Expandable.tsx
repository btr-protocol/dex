import type { ReactNode } from 'react';
import { useState, useEffect, useCallback } from 'react';
import { ChevronDown } from 'lucide-react';
import { useAccordion } from './Accordion';

export interface ExpandableProps {
  header: ReactNode;
  children: ReactNode;
  defaultExpanded?: boolean;
  id?: string;
  className?: string;
  icon?: ReactNode;
}

export function Expandable({ header, children, defaultExpanded = false, id, className = '', icon }: ExpandableProps) {
  const [isExpanded, setIsExpanded] = useState(defaultExpanded);
  const accordion = useAccordion();

  // Generate a unique ID if not provided
  const expandableId = id || `expandable-${Math.random().toString(36).substring(2, 9)}`;

  const open = useCallback(() => {
    setIsExpanded(true);
    accordion?.setActiveExpandable(expandableId);
  }, [accordion, expandableId]);

  const close = useCallback(() => {
    setIsExpanded(false);
    if (accordion?.activeExpandable === expandableId) {
      accordion.setActiveExpandable(null);
    }
  }, [accordion, expandableId]);

  const toggle = useCallback(() => {
    if (isExpanded) {
      close();
    } else {
      open();
    }
  }, [isExpanded, open, close]);

  useEffect(() => {
    // Register this expandable with the accordion
    if (accordion) {
      accordion.registerExpandable(expandableId, { open, close });
    }

    return () => {
      // Clean up registration when component is destroyed
      accordion?.unregisterExpandable(expandableId);
    };
  }, []); // Only run once on mount

  useEffect(() => {
    if (defaultExpanded && accordion) {
      open();
    }
  }, []); // Only run once on mount

  return (
    <div className={`w-full border-b border-border last:border-b-0 ${className}`}>
      <button
        onClick={toggle}
        className={`w-full px-4 py-3 flex items-center justify-between cursor-pointer transition-colors hover:bg-bg-2 ${
          isExpanded ? 'text-foreground' : 'text-muted-foreground'
        }`}
      >
        <div className="flex items-center gap-2">
          {icon && <span className="shrink-0">{icon}</span>}
          <h4 className={`text-sm ${isExpanded ? 'font-semibold' : 'font-medium'}`}>{header}</h4>
        </div>
        <ChevronDown
          className={`w-4 h-4 transition-transform ${isExpanded ? 'rotate-180' : ''}`}
        />
      </button>
      {isExpanded && (
        <div className="px-4 pt-3 pb-4">
          {children}
        </div>
      )}
    </div>
  );
}
