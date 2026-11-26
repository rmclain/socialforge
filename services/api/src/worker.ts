// The publishing worker: runs all the time, independent of the Mac app.
// pg-boss holds each job until its scheduled time, then hands it here.
import { loadConfig } from './config.ts'
import { runMigrations } from './db/client.ts'
import { processPublication, RetryLater, type PublishJob } from './publisher.ts'
import { createServices, PUBLISH_QUEUE, type Services } from './services.ts'

export async function startWorker (svc: Services, log: (msg: string, extra?: object) => void = (m, e) => console.log(JSON.stringify({ msg: m, ...e }))) {
  // batchSize: 1 ensures a RetryLater or failure on one publication never causes pg-boss
  // to fail or re-run sibling publications in the same batch.
  return svc.boss.work<PublishJob>(PUBLISH_QUEUE, { pollingIntervalSeconds: svc.config.pollingIntervalSeconds, batchSize: 1 }, async (jobs) => {
    for (const job of jobs) {
      try {
        const outcome = await processPublication(svc, job.data, job.retryCount, job.signal)
        log('publication processed', { publicationId: job.data.publicationId, outcome, attempt: job.retryCount + 1 })
      } catch (err) {
        if (err instanceof RetryLater) {
          log('publication will retry', { publicationId: job.data.publicationId, reason: err.message, attempt: job.retryCount + 1 })
        } else {
          log('publication job error', { publicationId: job.data.publicationId, error: (err as Error).message })
        }
        throw err
      }
    }
  })
}

if (import.meta.main) {
  const config = loadConfig()
  const svc = await createServices(config)
  await runMigrations(svc.db)
  await startWorker(svc)
  console.log(JSON.stringify({ msg: 'worker started', queue: PUBLISH_QUEUE, mockProviders: config.mockProviders }))
  const stop = async () => { await svc.close(); process.exit(0) }
  process.on('SIGTERM', stop)
  process.on('SIGINT', stop)
}
