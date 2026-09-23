import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // Keep the internal tool out of search engines even if a link leaks.
  async headers() {
    return [{ source: '/:path*', headers: [{ key: 'X-Robots-Tag', value: 'noindex, nofollow' }] }];
  },
  serverExternalPackages: ['exceljs'],
};

export default nextConfig;
