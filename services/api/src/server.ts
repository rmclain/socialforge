// The HTTP API. The worker runs as its own process (src/worker.ts); set
// RUN_WORKER=1 to run both in one process for local development.
import { buildApp } from './app.ts'
import { loadConfig } from './config.ts'
import { runMigrations } from './db/client.ts'
import { createServices } from './services.ts'
import { startWorker } from './worker.ts'

const config = loadConfig()
const svc = await createServices(config)
await runMigrations(svc.db)
const app = await buildApp(svc)
if (process.env.RUN_WORKER === '1') {
  await startWorker(svc, (msg, extra) => app.log.info(extra ?? {}, msg))
  app.log.info('worker running in this process')
}
await app.listen({ port: config.port, host: config.host })

const stop = async () => {
  await app.close()
  await svc.close()
  process.exit(0)
}
process.on('SIGTERM', stop)
process.on('SIGINT', stop)
