import { handleLegal } from '../src/handlers.ts';

export async function GET(request: Request): Promise<Response> {
  const u = new URL(request.url);
  const doc = u.searchParams.get('doc') || u.pathname.split('/').filter(Boolean).pop() || 'privacy';
  return handleLegal(request, doc);
}
