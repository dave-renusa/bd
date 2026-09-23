import type { MetadataRoute } from 'next';

// Internal tool: nothing is indexable, and there is no sitemap.
export default function robots(): MetadataRoute.Robots {
  return { rules: { userAgent: '*', disallow: '/' } };
}
