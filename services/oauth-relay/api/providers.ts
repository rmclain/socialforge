import { handleProviders } from '../src/handlers.ts';

export async function GET(request: Request): Promise<Response> {
  return handleProviders(request);
}
