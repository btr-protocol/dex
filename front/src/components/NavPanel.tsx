import { useState, useEffect, useCallback } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';
import { useRouter } from '@lib/router';
import { NavTreeItem, type NavItem } from '@components/ui/NavTreeItem';

interface NavPanelProps {
  type: 'files' | 'toc';
  slug?: string;
}

// Helper to recursively check if any descendant is active
function hasActiveDescendant(item: NavItem, currentPath: string): boolean {
  if (!item.children) return false;

  for (const child of item.children) {
    if (`/docs/${child.id}` === currentPath) return true;
    if (hasActiveDescendant(child, currentPath)) return true;
  }
  return false;
}

// File tree renderer - recursively renders file hierarchy
function renderFileItem(
  item: NavItem,
  currentPath: string,
  level: number,
  onNavigate: (path: string) => void,
  openFolderIds: Set<string>,
  setOpenFolderIds: (ids: Set<string>) => void
): ReactNode {
  const hasChildren = item.children && item.children.length > 0;
  const itemPath = `/docs/${item.id}`;
  const isActive = currentPath === itemPath;
  const hasActiveChild = !!( hasChildren && hasActiveDescendant(item, currentPath));
  const isOpen = hasActiveChild || openFolderIds.has(item.id);

  const handleToggle = () => {
    const newOpenIds = new Set(openFolderIds);
    if (isOpen && !hasActiveChild) {
      newOpenIds.delete(item.id);
    } else if (!isOpen) {
      newOpenIds.add(item.id);
    }
    setOpenFolderIds(newOpenIds);
  };

  const handleNavigate = () => {
    if (!hasChildren) {
      onNavigate(itemPath);
    } else {
      handleToggle();
    }
  };

  return (
    <NavTreeItem
      key={item.id}
      item={item}
      type="file"
      isActive={isActive}
      hasActiveChild={hasActiveChild}
      isOpen={isOpen}
      onToggle={handleNavigate}
      level={level}
      indent={(lvl) => lvl * 0.75}
      renderChildren={
        hasChildren
          ? () => (
              <div>
                {item.children!.map((child) =>
                  renderFileItem(child, currentPath, level + 1, onNavigate, openFolderIds, setOpenFolderIds)
                )}
              </div>
            )
          : null
      }
    />
  );
}

// TOC section renderer
function renderTocItem(
  section: NavItem,
  children: NavItem[],
  activeId: string,
  openSectionId: string | null,
  setOpenSectionId: (id: string | null) => void,
  onClick: (id: string) => void
): ReactNode {
  const isActive = activeId === section.id;
  const hasActiveChild = !!children.some(child => child.id === activeId);
  const isOpen = hasActiveChild || openSectionId === section.id;

  const handleToggle = () => {
    if (children.length === 0) {
      onClick(section.id);
      return;
    }
    if (isOpen && !hasActiveChild) {
      setOpenSectionId(null);
    } else if (!isOpen) {
      setOpenSectionId(section.id);
    }
  };

  return (
    <NavTreeItem
      key={section.id}
      item={section}
      type="toc"
      isActive={isActive}
      hasActiveChild={hasActiveChild}
      isOpen={isOpen}
      onToggle={handleToggle}
      renderChildren={
        children.length > 0
          ? () => (
              <div>
                {children.map(child => (
                  <button
                    key={child.id}
                    onClick={() => onClick(child.id)}
                    className={`w-full text-left text-sm py-1 rounded ${child.id === activeId ? 'text-primary bg-primary/10' : 'text-fg-2 hover:text-fg-1'}`}
                    style={{ paddingLeft: `${(child.level - 2) * 0.5}rem` }}
                  >
                    <span className="break-words">{child.label}</span>
                  </button>
                ))}
              </div>
            )
          : null
      }
    />
  );
}

// Parse doc structure to NavItem format
function parseDocStructure(data: any[]): NavItem[] {
  return data.map((item) => ({
    id: item.path,
    label: item.name,
    level: 0,
    children: item.children ? parseDocStructure(item.children) : undefined,
  }));
}

// Generate anchor ID from heading text
function generateAnchorId(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .trim();
}

// Alias for consistency with existing code
const generateHeadingId = generateAnchorId;

// Parse headings from rendered DOM (more reliable than parsing markdown)
function parseHeadingsFromDOM(): NavItem[] {
  const container = document.querySelector('main .prose') || document.querySelector('.prose');
  if (!container) return [];

  const headings = container.querySelectorAll('h1, h2, h3, h4');
  if (headings.length === 0) return [];

  const items: NavItem[] = [];
  const idCounts: Record<string, number> = {};

  headings.forEach((heading) => {
    const level = parseInt(heading.tagName.charAt(1));
    const text = heading.textContent?.trim() || '';
    if (!text) return;

    const baseId = generateHeadingId(text);
    let id = baseId;
    if (idCounts[baseId]) {
      idCounts[baseId]++;
      id = `${baseId}-${idCounts[baseId]}`;
    } else {
      idCounts[baseId] = 1;
    }

    const el = heading as HTMLElement;
    el.id = id;
    el.style.scrollMarginTop = '100px';

    items.push({ id, label: text, level });
  });

  return items;
}

// Group flat TOC items into sections (h1/h2 become sections, h3/h4 become children)
function groupTocItems(items: NavItem[]): Array<{ section: NavItem; children: NavItem[] }> {
  const groups: Array<{ section: NavItem; children: NavItem[] }> = [];
  let currentGroup: { section: NavItem; children: NavItem[] } | null = null;

  items.forEach(item => {
    if (item.level <= 2) {
      // h1 or h2 starts a new section
      currentGroup = { section: item, children: [] };
      groups.push(currentGroup);
    } else if (currentGroup) {
      // h3/h4 goes under current section
      currentGroup.children.push(item);
    } else {
      // No section yet, treat as standalone
      groups.push({ section: item, children: [] });
    }
  });

  return groups;
}

export function NavPanel({ type, slug }: NavPanelProps) {
  const router = useRouter();
  const navigate = router?.navigate ?? (() => {});
  const path = router?.path ?? '';
  const [items, setItems] = useState<NavItem[]>([]);
  const [loading, setLoading] = useState(type === 'files');
  const [activeId, setActiveId] = useState<string>('');
  const [openFolderIds, setOpenFolderIds] = useState<Set<string>>(new Set());
  const [openSectionId, setOpenSectionId] = useState<string | null>(null);

  // Load file structure
  useEffect(() => {
    if (type !== 'files') return;
    fetch('/docs-structure.json')
      .then((res) => res.json())
      .then((data) => {
        setItems(parseDocStructure(data));
        setLoading(false);
      })
      .catch(() => setLoading(false));
  }, [type]);

  // Parse TOC headings from DOM after content renders
  useEffect(() => {
    if (type !== 'toc' || !slug) return;

    let retryCount = 0;
    const maxRetries = 10;
    let timer: ReturnType<typeof setTimeout>;

    const tryParse = () => {
      const parsedItems = parseHeadingsFromDOM();
      if (parsedItems.length > 0) {
        setItems(parsedItems);
        if (parsedItems[0]) {
          setActiveId(parsedItems[0].id);
        }
      } else if (retryCount < maxRetries) {
        retryCount++;
        timer = setTimeout(tryParse, 150 * retryCount);
      }
    };

    // Reset items when slug changes
    setItems([]);
    timer = setTimeout(tryParse, 300);
    return () => clearTimeout(timer);
  }, [type, slug]);

  // Track active section for TOC using IntersectionObserver
  useEffect(() => {
    if (type !== 'toc' || items.length === 0) return;

    const visibleHeadings = new Set<string>();

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          const id = entry.target.id;
          if (entry.isIntersecting) {
            visibleHeadings.add(id);
          } else {
            visibleHeadings.delete(id);
          }
        });

        if (visibleHeadings.size > 0) {
          for (const item of items) {
            if (visibleHeadings.has(item.id)) {
              setActiveId(item.id);
              break;
            }
          }
        }
      },
      {
        rootMargin: '-10% 0px -80% 0px',
        threshold: 0,
      }
    );

    items.forEach(({ id }) => {
      const element = document.getElementById(id);
      if (element) {
        observer.observe(element);
      }
    });

    return () => observer.disconnect();
  }, [type, items]);

  // Auto-open section when active heading changes (from scrolling)
  useEffect(() => {
    if (type !== 'toc' || !activeId) return;

    // Find which section contains the active heading
    const groups = groupTocItems(items);
    for (const group of groups) {
      if (group.section.id === activeId) {
        // Active is a section itself, open it if it has children
        if (group.children.length > 0) {
          setOpenSectionId(group.section.id);
        }
        return;
      }
      if (group.children.some(child => child.id === activeId)) {
        // Active is inside this section
        setOpenSectionId(group.section.id);
        return;
      }
    }
  }, [type, items, activeId]);

  const scrollToHeading = useCallback((id: string) => {
    const element = document.getElementById(id);
    if (element) {
      element.scrollIntoView({ behavior: 'smooth', block: 'start' });
      setActiveId(id);
    }
  }, []);

  if (loading) {
    return (
      <div className="animate-pulse space-y-2">
        {[...Array(6)].map((_, i) => (
          <div key={i} className="h-5 bg-primary/10 rounded" />
        ))}
      </div>
    );
  }

  if (items.length === 0) return null;

  // Group TOC items into sections
  const tocGroups = type === 'toc' ? groupTocItems(items) : [];

  return (
    <nav className="overflow-x-hidden">
      {type === 'files'
        ? items.map((item) =>
            renderFileItem(item, path, 0, navigate, openFolderIds, setOpenFolderIds)
          )
        : tocGroups.map((group) =>
            renderTocItem(group.section, group.children, activeId, openSectionId, setOpenSectionId, scrollToHeading)
          )}
    </nav>
  );
}
