import { handleHome } from '../src/handlers.ts';

export async function GET(request: Request): Promise<Response> {
  return handleHome(request);
}
