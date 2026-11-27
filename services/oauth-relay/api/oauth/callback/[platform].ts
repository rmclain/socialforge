import { handleCallback } from '../../../src/handlers.ts';

export async function GET(request: Request): Promise<Response> {
  const pathname = new URL(request.url).pathname;
  const platform = pathname.split('/').filter(Boolean).pop() ?? '';
  return handleCallback(request, platform);
}
