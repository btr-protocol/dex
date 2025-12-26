import { signal } from '@preact/signals';
import { NavItem } from '@components/ui/NavTreeItem';

export class NavStore {
  public fileItems = signal<NavItem[]>([]);
  public tocItems = signal<NavItem[]>([]);
  public loading = signal<boolean>(false);
  
  // UI State
  public activeId = signal<string>('');
  public openFolderIds = signal<Set<string>>(new Set());
  public openSectionId = signal<string | null>(null);

  public setFileItems = (items: NavItem[]) => {
    this.fileItems.value = items;
  };

  public setTocItems = (items: NavItem[]) => {
    this.tocItems.value = items;
  };

  public setLoading = (l: boolean) => {
    this.loading.value = l;
  };

  public setActiveId = (id: string) => {
    this.activeId.value = id;
  };

  public toggleFolder = (id: string) => {
    const next = new Set(this.openFolderIds.value);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    this.openFolderIds.value = next;
  };

  public setOpenSectionId = (id: string | null) => {
    this.openSectionId.value = id;
  };
}

export const navStore = new NavStore();
