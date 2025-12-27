import { NavItem, NavTreeItem } from '@components/ui/NavTreeItem';
import { navStore } from '@/lib/nav/NavStore';

interface FileTreeProps {
  items: NavItem[];
  path: string;
  navigate: (path: string) => void;
  level?: number;
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

export function FileTree({ items, path, navigate, level = 0 }: FileTreeProps) {
  return (
    <>
      {items.map((item) => {
        const hasChildren = item.children && item.children.length > 0;
        const itemPath = `/docs/${item.id}`;
        const isActive = path === itemPath;
        const hasActiveChild = !!(hasChildren && hasActiveDescendant(item, path));
        const isOpen = hasActiveChild || navStore.openFolderIds.value.has(item.id);

        const handleNavigate = () => {
          if (!hasChildren) {
            navigate(itemPath);
          } else {
            navStore.toggleFolder(item.id);
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
              hasChildren && isOpen
                ? () => <FileTree items={item.children!} path={path} navigate={navigate} level={level + 1} />
                : null
            }
          />
        );
      })}
    </>
  );
}
