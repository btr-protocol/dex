import { createContext, JSX } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import { ComponentChildren } from 'preact';
import { navRoutes } from '@/constants/navigation';

// Get route by path from navRoutes
const getRouteByPath = (path: string) => {
  return navRoutes.find(r => r.path === path);
};

const RouterCtx = createContext<any>(null);

const updateMeta = (path: string) => {
    const r = getRouteByPath(path);
    document.title = r?.title ? `BTR | ${r.title}` : 'BTR';
    document.querySelector('meta[name="description"]')?.setAttribute('content', r?.description || 'BTR - Next-generation decentralized exchange.');
};

export function RouterProvider({ children }: { children: ComponentChildren }) {
    const [route, setRoute] = useState({
        path: window.location.pathname,
        query: new URLSearchParams(window.location.search)
    });

    const sync = () => {
        setRoute({ path: window.location.pathname, query: new URLSearchParams(window.location.search) });
        updateMeta(window.location.pathname);
    };

    useEffect(() => {
        updateMeta(route.path);
        window.addEventListener('popstate', sync);
        return () => window.removeEventListener('popstate', sync);
    }, []);

    const navigate = (to: string) => {
        if (to === route.path) return;
        window.history.pushState({}, '', to);
        sync();
    };

    return (
        <RouterCtx.Provider value={{ path: route.path, queryParams: route.query, navigate }}>
            {children}
        </RouterCtx.Provider>
    ) as JSX.Element;
}

export const useRouter = () => useContext(RouterCtx);
