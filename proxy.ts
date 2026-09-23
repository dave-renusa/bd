import { NextResponse, type NextRequest } from 'next/server';

// Light barrier for the proof of concept (no user accounts yet).
// When SITE_KEY is set, every page needs the bd_key cookie. Visiting any URL
// with ?key=<SITE_KEY> once sets the cookie for a year. Cron routes are
// excluded here because they check CRON_SECRET themselves.
export function proxy(req: NextRequest) {
  const siteKey = process.env.SITE_KEY;
  if (!siteKey) return NextResponse.next();

  const url = req.nextUrl;
  const fromQuery = url.searchParams.get('key');
  if (fromQuery === siteKey) {
    url.searchParams.delete('key');
    const res = NextResponse.redirect(url);
    res.cookies.set('bd_key', siteKey, { httpOnly: true, secure: true, sameSite: 'lax', maxAge: 60 * 60 * 24 * 365, path: '/' });
    return res;
  }
  if (req.cookies.get('bd_key')?.value === siteKey) return NextResponse.next();

  return new NextResponse('Not found', { status: 404, headers: { 'X-Robots-Tag': 'noindex, nofollow' } });
}

export const config = {
  matcher: ['/((?!api/cron|_next/static|_next/image|favicon.ico|robots.txt).*)'],
};
