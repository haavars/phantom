# Plan: exporting downloads to S3 (Cloudflare R2) for sharing

Status: phase 1 built, 2026-09-25: Cloudflare R2, private bucket, presigned links, files kept 14 days. Tested
against a local S3 server (SeaweedFS); waiting on the R2 account (section 4). Until `.env` has a bucket, the
share buttons don't show.

## 1. Goal and decisions

Today a person's ZIP or NIST export streams straight to the browser of whoever is on the tailnet. To hand data to
someone **outside** the tailnet (a vendor, an ABIS team, a colleague without Tailscale), Phantom should be able to
put the same file in an S3 bucket and give back a link that can be pasted into an email or chat.

Decisions:

- **Upload the exports, not the image store.** What goes to S3 is exactly what the download buttons produce
  (`Export.stream/1`, `NistExport.stream/1`), so the files carry the same README, `subject.json`, SHA-256s and
  "synthetic" markings. Images stay in `Storage.Local`; an S3 *storage backend* is a separate, later job
  (`docs/synthetic-biometrics.md`, "Later").
- **Cloudflare R2**, through its S3-compatible API. Downloads are free (no egress fees), which matters when
  the point is others downloading large files, and the free tier (10 GB stored) covers 14 days of sharing.
  Nothing R2-specific goes in the code: the endpoint is config, so AWS S3 or MinIO work too.
- **Private bucket; only someone with a link can download.** The bucket has no public access (no `r2.dev`
  URL, no custom domain), so nothing in it can be found or listed from outside. Each share is a presigned
  URL: it works for anyone who has it, without an account, for up to 7 days (the SigV4 limit), and a
  **New link** button re-signs it while the file exists. Each key also has a random 128-bit folder, never the
  run name or seed, so a key can't be guessed from what's in the file.
- **Files are kept 14 days.** A lifecycle rule on the bucket deletes `exports/` objects after 14 days, so the
  bucket can't grow without limit and a leaked link stops working for good.
- **Uploads run in the background** as an Oban job on a new `transfers` queue (the `generation` queue is kept at
  1 for the GPU). The page shows progress and the link when it's ready.
- **No new dependency.** Req 0.7.4 (already in `mix.lock`) signs requests with `aws_sigv4:`, streams a request
  body when `content-length` is set, and makes presigned URLs with `Req.Utils.aws_sigv4_url/1`.
- **Off unless configured.** Without a bucket in the environment, the share buttons don't show.

The app itself stays on the tailnet (`docs/remote-access.md`): share links move chosen files outside
Tailscale on purpose, to whoever the link is sent to, and nothing else.

## 2. How an upload works

```
Share link (LiveView) ──► Biometrics.share_subject/3 ──► shares row (queued) ──► Oban: UploadShare
                                                                                        │
   page updates over PubSub ◄── row: ready, url, expires_at ◄── PUT to S3 ◄── spool export to a temp file
```

1. The person's page (or the NIST page) calls `Biometrics.share_subject(subject, kind, options)`, which
   plans the export (so an empty choice fails at once), inserts a `shares` row and enqueues
   `Workers.UploadShare` with its id.
2. The worker builds the export with the same functions the `DownloadController` uses
   (`Biometrics.export_subject/3`, `Biometrics.nist_export/3`) and **spools the stream to a temp file**,
   computing the SHA-256 and size as it writes. A ZIP's length isn't known until it's built, and S3 needs a
   `content-length` for a single PUT; the file also lets a failed upload be retried without rebuilding.
3. It PUTs the file to `exports/<yyyy-mm-dd>/<random token>/<filename>` (streamed from disk, never whole in
   memory), with `content-type` and `content-disposition: attachment; filename=...` so browsers save it under
   the usual name (`PH-5167-ED5B_synthetic.zip`).
4. It presigns a GET URL, marks the row `ready` with the URL, expiry, size and SHA-256, deletes the temp file
   and broadcasts on PubSub. On error the row is `failed` with the reason; Oban retries 3 times.

A single PUT allows up to 5 GB, far above a subject (~100 MB). Multipart upload is only worth adding if
whole-run archives (phase 2) get past a few GB.

## 3. Modules

| Module | Role |
|---|---|
| `Phantom.S3` | Thin Req client: `put_file(key, path, headers)`, `presign(key, expires_in)`, `delete(key)`, `configured?/0`. Path-style URLs, `<endpoint>/<bucket>/<key>`; Req options overridable in test (`plug: {Req.Test, Phantom.S3}`). |
| `Phantom.Biometrics.Share` | Schema for `shares`: `subject_id`, `kind` (`zip`/`nist`), `options` (include, or NIST content/compression/search), `status` (`queued`/`uploading`/`ready`/`failed`), `filename`, `key`, `content_type`, `byte_size`, `sha256`, `url`, `link_expires_at`, `expires_at` (when the lifecycle rule deletes the file), `error`. |
| `Phantom.Biometrics.Shares` | Creating shares, `upload/1` (spool, PUT, sign), `renew/1`, and `{:share_updated, share}` events on a per-subject PubSub topic. |
| `Phantom.Biometrics.Workers.UploadShare` | The job in section 2, on the `transfers` queue (2 at a time). Unique per share, 3 attempts; the last failure marks the share failed. |
| `Phantom.Biometrics` | `sharing_enabled?/0`, `share_subject/3`, `list_shares/1`, `renew_share/1`, `subscribe_shares/1`. |
| `PhantomWeb.BiometricsComponents.share_links/1` | The **Shared links** list: upload progress, then the link with **Copy**, when the link and the file expire, and **New link**. Copying is a `phantom:copy` event in `app.js`. |
| `PhantomWeb.BiometricsRunLive` | On a person's page, a link button beside each ZIP in the download menu, and the list under the header. |
| `PhantomWeb.NistExportLive` | **Share as a link** under **Download**, with the chosen options, and the list below. |

Migration `20260925140000_create_shares`.

## 4. Configuration

`config/runtime.exs`, read from the environment:

| Variable | Default | |
|---|---|---|
| `PHANTOM_S3_BUCKET` | unset (feature off) | `phantom-exports` |
| `PHANTOM_S3_ENDPOINT` | | `https://<account id>.r2.cloudflarestorage.com` |
| `PHANTOM_S3_REGION` | `auto` | R2 takes `auto`; an AWS region otherwise |
| `PHANTOM_S3_ACCESS_KEY_ID`, `PHANTOM_S3_SECRET_ACCESS_KEY` | | From the bucket's R2 API token |
| `PHANTOM_S3_LINK_DAYS` | `7` | 1–7 |
| `PHANTOM_S3_KEEP_DAYS` | `14` | Must match the bucket's lifecycle rule; only shown on the page |

In dev, `config/runtime.exs` reads them from `.env` next to `mix.exs` (gitignored; variables already set in the
shell win), so after filling it in, restart `mix phx.server`:

```bash
# .env
PHANTOM_S3_BUCKET=phantom-exports
PHANTOM_S3_ENDPOINT=https://<account id>.r2.cloudflarestorage.com
PHANTOM_S3_ACCESS_KEY_ID=<access key id>
PHANTOM_S3_SECRET_ACCESS_KEY=<secret access key>
```

### Setting up R2 (once)

1. Sign up at [dash.cloudflare.com](https://dash.cloudflare.com) (free) and open **R2 Object Storage**. R2
   asks for a payment method even on the free tier.
2. **Create bucket** `phantom-exports`, location hint *Western Europe*.
3. Bucket **Settings → Public access**: leave the `r2.dev` URL **disabled** and add no custom domain. That
   keeps the bucket private; presigned links work without either.
4. Bucket **Settings → Object lifecycle rules**: add a rule for prefix `exports/` that **deletes objects 14
   days** after upload. Keep the default rule that aborts incomplete multipart uploads.
5. **R2 → Manage API tokens → Create API token**: permission **Object Read & Write**, applied to
   **`phantom-exports` only**. Copy the Access Key ID, Secret Access Key and the S3 endpoint
   (`https://<account id>.r2.cloudflarestorage.com`) into `.env`; the secret is shown once.

R2 tokens can't be narrowed to a prefix or made unable to list the bucket, so the token is what protects the
bucket's contents: it stays in `.env` on store-1 and is only used by the app. Anyone given a link gets that
one file, until the link or the file expires.

## 5. Phases

1. **Share one subject** (sections 2–4), built: ZIP and NIST exports, presigned links, the shared links on
   the person's page and the NIST page.
2. **Whole runs:** a run archive (one folder per person, one manifest), already on the roadmap in
   `docs/synthetic-biometrics.md`, uploaded the same way; it's the case where a link beats a browser download
   most. A `mix phantom.share <run> [<subject>]` task that prints the link, for scripting.
3. **Housekeeping:** a **Delete now** button that removes the object before it expires (`Phantom.S3.delete/1`
   is there), and pruning old `shares` rows. Expiry itself needs nothing: the page compares `expires_at`.

## 6. Verification

- `test/phantom/s3_test.exs`: the PUT is streamed, signed (`AWS4-HMAC-SHA256`, `UNSIGNED-PAYLOAD`) and carries
  its headers; S3's error codes come back as reasons; presigned URLs have the SigV4 query and refuse > 7 days.
- `test/phantom/biometrics/shares_test.exs`: a share goes `queued → ready` with the uploaded bytes' size and
  SHA-256 and a random key; NIST options are kept; an empty choice is refused; a 403 is retried, then marks the
  share failed; renewing never outlives the file and refuses once it's gone. `shares_config_test.exs`: no
  bucket, no sharing.
- LiveView tests: sharing from the download menu shows the upload, then the link; the NIST page shares with the
  chosen options.
- By hand, 2026-09-25, against SeaweedFS's S3 API in Docker (MinIO's images are no longer pullable) with a
  real subject: a 49 MB ZIP and a 35 MB NIST ZIP uploaded in about a second; the links downloaded without
  credentials with matching SHA-256 and `content-disposition`; the URL without its signature, with a tampered
  signature, and listing the bucket all got 403; after deleting the object the link got 404.
- Still to do once R2 is set up: share from the page, open the link in a private window off the tailnet, and
  check the lifecycle rule deletes the file after 14 days.

## 7. Decided

- Cloudflare R2 (2026-09-25).
- Private bucket, presigned links: only someone with a link can download.
- Files kept 14 days; links last 7 and can be renewed while the file exists.
- Named *shares* in the code and UI (the plan's first draft said *transfers*); the Oban queue is `transfers`.
