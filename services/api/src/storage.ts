import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3'
import type { Config } from './config.ts'

/** Staged media for publishing. S3-compatible in production (R2, SeaweedFS), a folder in development. */
export interface MediaStore {
  put (key: string, body: Buffer, contentType: string): Promise<void>
  get (key: string): Promise<Buffer>
}

export function createStore (cfg: Config['storage']): MediaStore {
  if (cfg.kind === 'fs') {
    return {
      async put (key, body) {
        const path = join(cfg.dir, key)
        await mkdir(dirname(path), { recursive: true })
        const tmp = `${path}.${process.pid}.part`
        await writeFile(tmp, body)
        await rename(tmp, path)
      },
      async get (key) { return readFile(join(cfg.dir, key)) },
    }
  }
  const s3 = new S3Client({
    endpoint: cfg.endpoint,
    region: cfg.region,
    forcePathStyle: true,
    credentials: { accessKeyId: cfg.accessKeyId, secretAccessKey: cfg.secretAccessKey },
  })
  return {
    async put (key, body, contentType) {
      await s3.send(new PutObjectCommand({ Bucket: cfg.bucket, Key: key, Body: body, ContentType: contentType }))
    },
    async get (key) {
      const out = await s3.send(new GetObjectCommand({ Bucket: cfg.bucket, Key: key }))
      return Buffer.from(await out.Body!.transformToByteArray())
    },
  }
}
