import { pageRoutes, socialLinks, type NavRoute } from '@/constants/navigation';

interface ExtendedNavRoute extends NavRoute {
  description?: string;
  aliases?: string[];
}
import { SETTINGS_SCHEMA } from '@/config/settings';
import { SUPPORTED_TOKENS_CONFIG } from '@/constants/tokens';

export interface SearchDoc {
  id: string;
  title: string;
  desc?: string;
  path: string;
  cat: 'Features' | 'Links' | 'Docs' | 'Settings';
  section?: string;
  content?: string;
}

let eng: any;
let init: Promise<void>;

export async function initializeSearch() {
  if (init) return init;
  return (init = (async () => {
    const MiniSearch = (await import('minisearch')).default;
    eng = new MiniSearch({
      fields: ['title', 'desc', 'content', 'aliases'],
      storeFields: ['id', 'title', 'desc', 'path', 'cat', 'section', 'content'],
      searchOptions: { boost: { title: 3, desc: 2, aliases: 1.5 }, fuzzy: 0.2, prefix: true }
    });

    // Bulk Add Static Data
    const extendedNavRoutes = pageRoutes as ExtendedNavRoute[];
    eng.addAll([
      ...extendedNavRoutes.flatMap((r, i) => r.path === '/' ? [] : [{
        id: `feat-${i}`, title: r.title, desc: r.description || '', path: r.path, cat: 'Features', aliases: r.aliases || []
      }]),
      ...socialLinks.map((l, i) => ({
        id: `link-${i}`, title: l.title, desc: `Visit ${l.title}`, path: l.path, cat: 'Links', aliases: []
      })),
      // Settings: One entry per category (groups all nested settings)
      ...SETTINGS_SCHEMA.map(category => {
        const allKeywords = category.settings.flatMap(s => s.keywords || []);
        const allLabels = category.settings.map(s => s.label).join(' ');
        return {
          id: `set-${category.id}`,
          title: category.label,
          desc: `Configure ${category.label.toLowerCase()} preferences`,
          path: '/settings',
          cat: 'Settings',
          section: category.id,
          aliases: [...allKeywords, allLabels]
        };
      }),
      // Token swap shortcuts - allows searching "ETH" to quickly swap that token
      ...SUPPORTED_TOKENS_CONFIG.map((token, i) => ({
        id: `token-${i}`,
        title: `Swap ${token}`,
        desc: `Trade ${token} on the swap page`,
        path: `/swap?token=${token}`,
        cat: 'Features',
        aliases: [token, token.toLowerCase(), `buy ${token}`, `sell ${token}`, `trade ${token}`]
      }))
    ]);

    // Async Docs Load
    fetch('/compiled-docs/search-index.json').then(r => r.ok && r.json()).then(d => {
      if (d?.documents) eng.addAll(d.documents.flatMap((doc: any) => doc.id.includes('#') ? [] : [{
        id: `doc-${doc.id}`, title: doc.title, desc: doc.excerpt, content: doc.content || doc.excerpt, path: doc.url, cat: 'Docs'
      }]));
    }).catch(() => {});
  })());
}

const getSnippet = (txt: string, q: string) => {
  if (!txt) return '';
  const txtLower = txt.toLowerCase();
  const qLower = q.toLowerCase();
  const match = qLower.split(/\s+/).find(t => txtLower.includes(t));
  const idx = match ? txtLower.indexOf(match) : 0;
  const start = Math.max(0, idx - 40), end = Math.min(txt.length, idx + 110);
  let s = txt.substring(start, end);
  const terms = q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&').split(/\s+/).join('|');
  return (start > 0 ? '...' : '') + s.replace(new RegExp(`(${terms})`, 'gi'), '<mark>$1</mark>') + (end < txt.length ? '...' : '');
};

export const search = (q: string): SearchDoc[] => {
  if (!eng || !q.trim()) return [];
  return eng.search(q).slice(0, 15).map((r: any) => ({
    ...r,
    content: r.cat === 'Docs' ? getSnippet(r.content || r.desc, q) : undefined
  }));
};

export const searchGrouped = (q: string) => {
  const r = search(q);
  const grouped: Record<string, SearchDoc[]> = {
    Features: [],
    Settings: [],
    Links: [],
    Docs: []
  };

  for (const item of r) {
    if (grouped[item.cat]) {
      grouped[item.cat].push(item);
    }
  }

  return grouped;
};

export const waitForDocs = async () => init;
