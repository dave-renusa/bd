import type { Metadata } from 'next';
import Nav from './nav';
import './globals.css';

export const metadata: Metadata = {
  title: 'BD Radar | RenUSA',
  description: 'RenUSA business development radar',
  robots: { index: false, follow: false, nocache: true, googleBot: { index: false, follow: false } },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="" />
        <link
          rel="stylesheet"
          href="https://fonts.googleapis.com/css2?family=Bebas+Neue&family=Source+Sans+3:wght@400;600;700&display=swap"
        />
      </head>
      <body>
        <div className="stripe" />
        <header className="masthead">
          <div className="masthead-inner">
            <div className="brand">
              <p className="brand-title">RenUSA BD Radar</p>
              <div className="brand-sub">Queue entries, opposition and restarts, scored and owned</div>
            </div>
            <Nav />
          </div>
        </header>
        <main>{children}</main>
      </body>
    </html>
  );
}
