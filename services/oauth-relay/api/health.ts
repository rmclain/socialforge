import { handleHealth } from '../src/handlers.ts';

export async function GET(): Promise<Response> {
  return handleHealth();
}
