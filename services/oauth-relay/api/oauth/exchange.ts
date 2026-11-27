import { handleExchange } from '../../src/handlers.ts';

export async function POST(request: Request): Promise<Response> {
  return handleExchange(request);
}
