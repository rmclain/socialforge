import { handleRefresh } from '../../src/handlers.ts';

export async function POST(request: Request): Promise<Response> {
  return handleRefresh(request);
}
