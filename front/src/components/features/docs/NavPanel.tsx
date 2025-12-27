import { useEffect, useCallback } from 'preact/hooks';
import { useRouter } from '@lib/router';
import { navStore } from '@/lib/nav/NavStore';
import { FileTree } from './FileTree';
import { NavTreeItem, NavItem } from '@components/ui/NavTreeItem';

interface NavPanelProps {
  type: 'files' | 'toc';
  slug?: string;
}

interface DocStructureItem {
  path: string;
  name: string;
  children?: DocStructureItem[];
}

// Group flat TOC items into sections (h1/h2 become sections, h3/h4 become children)
function groupTocItems(items: NavItem[]): Array<{ section: NavItem; children: NavItem[] }> {
  const groups: Array<{ section: NavItem; children: NavItem[] }> = [];
  let currentGroup: { section: NavItem; children: NavItem[] } | null = null;

  items.forEach(item => {
    if (item.level <= 2) {
      currentGroup = { section: item, children: [] };
      groups.push(currentGroup);
    } else if (currentGroup) {
      currentGroup.children.push(item);
    } else {
      groups.push({ section: item, children: [] });
    }
  });

  return groups;
}

function parseDocStructure(data: DocStructureItem[]): NavItem[] {
  return data.map((item) => ({
    id: item.path,
    label: item.name,
    level: 0,
    children: item.children ? parseDocStructure(item.children) : undefined,
  }));
}

function generateHeadingId(text: string): string {
  return text.toLowerCase().replace(/[^\w\s-]/g, '').replace(/\s+/g, '-').replace(/-+/g, '-').trim();
}

function parseHeadingsFromDOM(): NavItem[] {
  const container = document.querySelector('main .prose') || document.querySelector('.prose');
  if (!container) return [];
  const headings = container.querySelectorAll('h1, h2, h3, h4');
  return Array.from(headings).map((heading) => {
    const level = parseInt(heading.tagName.charAt(1));
    const text = heading.textContent?.trim() || '';
    const id = generateHeadingId(text);
    (heading as HTMLElement).id = id;
    (heading as HTMLElement).style.scrollMarginTop = '100px';
    return { id, label: text, level };
  });
}

export function NavPanel({ type, slug }: NavPanelProps) {
  const { navigate, path } = useRouter();

  useEffect(() => {
    if (type !== 'files') return;
    navStore.setLoading(true);
    fetch('/compiled-docs/docs-structure.json')
      .then((res) => res.json())
      .then((data) => {
        navStore.setFileItems(parseDocStructure(data));
        navStore.setLoading(false);
      })
      .catch(() => navStore.setLoading(false));
  }, [type]);

  useEffect(() => {
    if (type !== 'toc' || !slug) return;
    const tryParse = () => {
      const parsed = parseHeadingsFromDOM();
      if (parsed.length > 0) {
        navStore.setTocItems(parsed);
        if (parsed[0]) navStore.setActiveId(parsed[0].id);
      }
    };
    tryParse();
    const timer = setTimeout(tryParse, 500);
    return () => clearTimeout(timer);
  }, [type, slug]);

  const scrollToHeading = useCallback((id: string) => {
    const element = document.getElementById(id);
    if (element) {
      element.scrollIntoView({ behavior: 'smooth', block: 'start' });
      navStore.setActiveId(id);
    }
  }, []);

  if (navStore.loading.value) return <div className="animate-pulse space-y-2">{[...Array(6)].map((_, i) => <div key={i} className="h-5 bg-primary/10 rounded" />)}</div>;
  const items = type === 'files' ? navStore.fileItems.value : navStore.tocItems.value;
  if (items.length === 0) return null;

  const tocGroups = type === 'toc' ? groupTocItems(items) : [];

  return (
    <nav className="overflow-x-hidden">
      {type === 'files' ? (
        <FileTree items={items} path={path} navigate={navigate} />
      ) : (
        tocGroups.map((group) => {
          const isActive = navStore.activeId.value === group.section.id;
          const hasActiveChild = group.children.some(c => c.id === navStore.activeId.value);
          const isOpen = hasActiveChild || navStore.openSectionId.value === group.section.id;
          return (
            <NavTreeItem
              key={group.section.id}
              item={group.section}
              type="toc"
              isActive={isActive}
              hasActiveChild={hasActiveChild}
              isOpen={isOpen}
              onToggle={() => {
                if (group.children.length === 0) scrollToHeading(group.section.id);
                else navStore.setOpenSectionId(isOpen && !hasActiveChild ? null : group.section.id);
              }}
              renderChildren={isOpen && group.children.length > 0 ? () => (
                <div>
                  {group.children.map(child => (
                    <button
                      key={child.id}
                      onClick={() => scrollToHeading(child.id)}
                      className={`w-full text-left text-sm py-1 rounded ${child.id === navStore.activeId.value ? 'text-primary bg-primary/10' : 'text-fg-2 hover:text-fg-1'}`}
                      style={{ paddingLeft: `${(child.level - 2) * 0.5}rem` }}
                    >
                      <span className="break-words">{child.label}</span>
                    </button>
                  ))}
                </div>
              ) : null}
            />
          );
        })
      )}
    </nav>
  );
}