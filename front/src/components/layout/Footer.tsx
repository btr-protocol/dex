import { Activity } from 'lucide-react';

const routes = [
  { title: 'ToS', path: '/legal/Terms of Service' },
  { title: 'Disclaimer', path: '/legal/Risk Disclaimer' },
  { title: 'Privacy', path: '/legal/Privacy Policy' },
];

export default function Footer() {
  const currentYear = new Date().getFullYear();

  const handleScrollTop = () => {
    window.scrollTo({ top: 0, behavior: 'smooth' });
  };

  return (
    <footer className="fixed bottom-0 w-full h-10 flex items-center z-50 italic font-light text-sm">
      <nav className="px-4 max-w-7xl h-full mx-auto flex items-center justify-between border border-b-0 rounded-t-lg backdrop-blur-md bg-background/80 border-border w-full">
        {/* Status */}
        <div className="flex items-center gap-2 text-xs text-gray-400">
          <Activity className="w-3 h-3 text-green-500" />
          <span>API 13ms</span>
        </div>

        {/* Links */}
        <ul className="flex items-center gap-4">
          {routes.map((route) => (
            <li key={route.title}>
              <a
                href={route.path}
                className="text-gray-400 hover:text-white transition-all hover:before:content-['⇨_']"
                style={{ paddingLeft: '0.9rem' }}
                onMouseEnter={(e) => {
                  e.currentTarget.style.paddingLeft = '0';
                }}
                onMouseLeave={(e) => {
                  e.currentTarget.style.paddingLeft = '0.9rem';
                }}
              >
                {route.title}
              </a>
            </li>
          ))}
          <li
            className="text-gray-400 cursor-pointer pl-2 hover:text-white"
            onClick={handleScrollTop}
          >
            © {currentYear}
          </li>
          <li
            className="text-xl font-black cursor-pointer hover:text-primary"
            onClick={handleScrollTop}
          >
            BTR
          </li>
        </ul>
      </nav>
    </footer>
  );
}
