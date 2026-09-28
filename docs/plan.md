# Plan

Status: 2026-09-28. The one overview of what Phantom is working towards: what's done, what's in progress, and
what's next, each pointing at the document that holds the detail. Detailed plans stay in their own documents;
when a phase moves, update its status there and the line here.

Phantom generates synthetic test subjects for an ABIS: a face with mugshots and probes, rolled and plain
fingerprints and palms, exported as ZIP or ANSI/NIST-ITL. What exists today is described in
[`synthetic-biometrics.md`](synthetic-biometrics.md).

## Documents

| Document | What | Status |
|---|---|---|
| [`synthetic-biometrics-plan.md`](synthetic-biometrics-plan.md) | The original plan: `/biometrics`, storage, faces, prints, palms, packaging | Built, except the S3 storage backend (local only) and the NFIQ 2 / OFIQ quality scores |
| [`synthetic-biometrics.md`](synthetic-biometrics.md) | How it works today, prompt design, face diversity and the face gate, known issues | Reference, kept current |
| [`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md) | Realistic prints: verification, IMPOSE, diffusion rendering | Phases 0, 1 and a no-training 2a done; 2b onwards open |
| [`nist-export-plan.md`](nist-export-plan.md) | ANSI/NIST-ITL `.an2` export | Phase 1 built; next steps in §6 |
| [`s3-export-plan.md`](s3-export-plan.md) | Sharing exports through Cloudflare R2 | Phase 1 built, waiting on the R2 account |
| [`image-resolution.md`](image-resolution.md) | What resolution faces and prints should have | Research done, its recommendations built |
| [`face-source-conditioning-plan.md`](face-source-conditioning-plan.md) | Making faces as unlike each other as real strangers: pool references (failed), identity-first anchors (§8) | Experimenting |
| [`face-pool.md`](face-pool.md) | Open face datasets processed into a labelled pool | FairFace done; other datasets not started |
| [`remote-access.md`](remote-access.md) | Sharing the app with colleagues over Tailscale | Set up |

## In progress

- **Identity-first anchors** ([`face-source-conditioning-plan.md`](face-source-conditioning-plan.md) §8,
  scripts in [`python_inference/experiments/identity_first/`](../python_inference/experiments/identity_first/README.md)).
  Arc2Face identities, cleaned by a Qwen edit, as the anchor's only reference give 24 men about as far apart as
  real strangers (median 0.07, max 0.29). Running now: whether the age gap between reference and subject is
  what loses the identity for the two weak anchors, tested by (a) matching identities to subjects by apparent
  age and (b) setting the subject's age in the cleaning edit.

## Next

In rough order within each area; nothing is scheduled across areas yet.

**Faces**

1. Finish the identity-first experiment: the age test, then women and other ancestries, then profiles and
   probes conditioned on these anchors. If it holds, plan how it goes into the app (Arc2Face as a service,
   identity sampling per run, the leakage check against the pool) as a run option next to text-only.
2. **Look into the facial feature list** ([Face diversity](synthetic-biometrics.md#face-diversity)): every
   person draws seven strongly worded, unusual features, which isn't realistic, and that mild wording doesn't
   work was never measured. Test mild wording, "ordinary" options and only two features on the same 8 people.
   May be moot if identity-first anchors replace text-only ones.
3. Reject probes that no longer match their anchor (same ArcFace templates as the face gate), and check against
   the ABIS matcher if its API is available.
4. From the known issues in [`synthetic-biometrics.md`](synthetic-biometrics.md#known-issues-and-next-steps):
   check the v4–v7 prompt changes on more renders, record model and service versions with each image, and a
   tighter ICAO crop.

**Friction ridges** ([`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md))

1. Phase 3: render plain fingers separately and fix the slap layout (seams, straight-edged middle phalanx).
   Doesn't depend on the open decisions.
2. Phase 2b: a conditioned renderer (own ControlNet) for acquisition styles and livescan. Waits on open
   decisions 1–3.
3. Convert ground-truth minutiae angles to ANSI/INCITS 378 (about 180° off today).

**Export and sharing**

1. Load an exported `.an2` into abis_next ([`nist-export-plan.md`](nist-export-plan.md) §5).
2. Whole runs as one archive, ZIP and NIST, and a `mix` task for it (NIST §6.1, S3 phase 2).
3. Prints as search transactions, Type-9 ground-truth minutiae, faces as JPEG (NIST §6.2, 6.4–6.6).
4. INTERPOL INT-I v6 (XML), which also needs mugshots that genuinely meet SAP 30 or 40 (NIST §6.3).
5. Once R2 is set up: share from the page, open a link off the tailnet, check the 14-day expiry
   ([`s3-export-plan.md`](s3-export-plan.md) §6); then a **Delete now** button.

**Later**

- NFIQ 2 and OFIQ scores stored per image and used to filter (plan phase 6).
- An S3 storage backend, and access control before the app runs anywhere beyond the tailnet.
- More datasets in the face pool, if the pool is used again ([`face-pool.md`](face-pool.md) §8).
- Latent prints.

## Open decisions

- **Fingerprint training data:** is NIST SD302 (with SD 1.5) acceptable, which acquisition styles matter, and
  should we request MSU GenPrint ([`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md) §10).
- **Latent prints** in scope or not (same place).
- **Licences:** Qwen-Image-2.1 for this use; Arc2Face was trained on WebFace42M, a research-only dataset, which
  matters if identity-first anchors go into the app.

Answered: INTERPOL is the target format (2026-09-25), 500 ppi is enough (2026-09-25), Cloudflare R2 for sharing
(2026-09-25), Oban for jobs (in use).

## Done

**Faces**

- 2026-09-23: face generation harness with Qwen-Image-2.1; anchors, mugshots, profiles and probes.
- 2026-09-24: probes that vary like later photos, the aged probe aged for the age it reaches, traits fixed for
  a whole run.
- 2026-09-25: 3:4 mugshots at 960 × 1280, a low-resolution probe in varied scenes, an uncooperative probe.
- 2026-09-25: sampled facial features, face first with two called out (`faces-v13`).
- 2026-09-25: face pool from FairFace; conditioning anchors on pool faces tested on 16 subjects and failed
  (Qwen copies one face instead of blending).
- 2026-09-27: the face gate: an anchor too like another person of the run is rendered again.
- 2026-09-27: big noses described by shape, not size (`faces-v14`).
- 2026-09-27: identity-first pilot (12 men), then 24 men with mugshot framing.
- 2026-09-28: cleaning the references with a Qwen edit first: anchors from flawed references keep more of
  their identity.

**Friction ridges**

- 2026-09-23: synthetic fingerprints, slaps and palms, one `/biometrics` service.
- 2026-09-24: verification with NBIS and NFIQ 2, the diffusion renderer (SDEdit on IMPOSE's model), quality
  report per run.

**App, storage and export**

- 2026-09-24: runs, subjects and images in Postgres; jobs on Oban; landing gallery and identity pages;
  re-rendering missing images and adding shots to finished runs; ZIP download per person.
- 2026-09-25: ANSI/NIST-ITL export (Traditional encoding, PNG or WSQ), UUIDv7 image ids, WebP previews.
- 2026-09-25: exports shared through a private S3 bucket with presigned links; sharing over Tailscale.
