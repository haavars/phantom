# Synthetic biometrics

Phantom generates **synthetic subjects**, fictional people, for ABIS testing. Each subject can have:

- **Face images:** mugshots (frontal, profiles, ¾ views), an ICAO passport portrait and mated probe images,
  generated with the local Qwen-Image-2.1 service.
- **Friction-ridge images:**
  - 10 rolled fingerprints
  - right-four, left-four and two-thumb slaps
  - full and writer's palmprints of both hands
  - an FD-249 style tenprint card

  The service in [`python_biometrics/`](../python_biometrics/README.md) synthesises the ridge patterns, renders
  them as realistic inked prints with a diffusion model (or procedurally, as a fast CPU draft), and verifies
  every finger and slap against its ground truth. Extra captures can be added for mated pairs.

All images of one subject show the same person, the same fingers and the same palms. A run can fix any
appearance trait for all of its people (ten Northern European women in their thirties, say), and every person
can be downloaded as a ZIP with a manifest, or as ANSI/NIST-ITL transactions to enrol in an ABIS. This
implements the face and friction-ridge parts of [`synthetic-biometrics-plan.md`](synthetic-biometrics-plan.md).
You can drive it from IEx or from the web UI.

**Status (2026-09-25):**

- Faces and friction ridges both work, from IEx and the web UI. Runs, subjects and images are stored in
  Postgres, the files on local disk.
- A person exports as ANSI/NIST-ITL 1-2011 Update:2015 transactions (`.an2`): an enrolment and, optionally, face
  probes to search with, prints as PNG or WSQ. See [NIST export](#nist-export) and
  [`nist-export-plan.md`](nist-export-plan.md).
- Friction ridges are rendered by diffusion and verified with NIST tools (NFIQ 2, `mindtct`, `bozorth3`). See
  [`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md) for what's done and what's next.
- The face prompt changes since `faces-v3` (per-probe pose and expression, healed scars, age-scaled ageing,
  clothing by sex, the low-resolution probe; now `faces-v11`) haven't been checked on a large set of real renders yet.

> Everything this produces is synthetic test data. Use it for functional, integration and load testing of an
> ABIS, not as evidence of matching accuracy, and never send it to a production or live-exchange system. See
> [Caveats](#caveats).

## Quick start

Run `mix phx.server`, which starts both services:

- Qwen-Image-2.1 on port 8000, for faces (GPU)
- the friction-ridge service on port 8001 (patterns and verification on the CPU, diffusion rendering on the GPU)

The friction-ridge service needs its one-time setup first: `cd python_biometrics && ./setup.sh --diffusion`.
This builds the NIST tools (verification, and WSQ for the NIST export) and installs the diffusion renderer; leave
out `--diffusion` on a machine without an NVIDIA GPU and use the `procedural` renderer.

Start runs from the web UI (below), or from IEx attached to the running app (`iex -S mix phx.server`):

```elixir
Phantom.Biometrics.create_run(%{subjects: 5, seed: 42})                                    # default shots
Phantom.Biometrics.create_run(%{shots: ["faces", "rolled", "slaps", "palms", "card"], captures: 2})
Phantom.Biometrics.create_run(%{shots: ["rolled", "slaps"], renderer: "procedural"})      # no GPU needed

# Ten Northern European women in their thirties with blue eyes; everything else random per person.
Phantom.Biometrics.create_run(%{
  subjects: 10,
  traits: %{sex: "female", ancestry: "Northern European", age_min: 30, age_max: 39, eye_color: "blue"}
})

# Later: glasses probes for everyone in an existing run, and re-render deleted files.
{:ok, run} = Phantom.Biometrics.get_run("20260924-171001-seed1740159062")
Phantom.Biometrics.add_shots(run, ["probe_glasses"])
Phantom.Biometrics.resume_run(run)
```

`create_run/1` validates its parameters like the web form (`Phantom.Biometrics.RunRequest`) and queues the run,
so runs from IEx and from the UI share one queue and show up on the same pages. In a release, run the same call
with `bin/phantom rpc`.

| Parameter | Default | Meaning |
|---|---|---|
| `subjects` | 3 | Number of fictional people (max 100) |
| `seed` | random | Run seed; every person, prompt and image seed is derived from it |
| `shots` | every face shot and ridge group | Shot ids and groups: `faces`, `rolled`, `slaps`, `palms`, `card` (see [Shots](#shots)) |
| `captures` | 1 | Captures per finger and palm shot (max 3); captures after the first are mated pairs |
| `renderer` | `diffusion` | Friction-ridge renderer: `diffusion` (realistic, GPU) or `procedural` (fast CPU draft) |
| `steps` | 40 | Denoising steps for face shots (20, 30, 40 or 50) |
| `traits` | all random | Appearance every person in the run shares (see [Traits](#traits)) |
| `run` | `<timestamp>-seed<S>` | Run name |

## Web UI

With `mix phx.server` running, open [`localhost:4000`](http://localhost:4000). The header has **Overview** and
**Runs**, a **New run** button and the theme toggle (system, light, dark; in the footer on phones).

- **`/`**, the overview: what Phantom is, how a subject is made, and a gallery of the identities generated so
  far, filterable by those with a face or with fingerprints. A card opens that person's page.
- **`/biometrics`**, runs:
  - The run rendering now, with a progress bar, the shot being rendered, **Watch** and **Cancel**.
  - The **new-run form** in three numbered sections, with a sticky summary beside them:
    1. **People:** how many, then a Random / Female / Male toggle, an age range, ancestry, and a grid of
       appearance traits (skin, eyes, hair colour, texture and style, facial hair, face shape, build, clothing,
       distinguishing mark). Each is **Random** until set; a set trait is highlighted and has an × back to
       Random. Colour and texture lists narrow to the chosen ancestry, clothing to the chosen sex; facial hair
       is disabled for women. The distinguishing mark defaults to **None**.
    2. **Faces:** a card per face shot, with All / Default / None and the denoising steps.
    3. **Friction ridge:** a card per group (rolled, slaps, palms, card), with All / None, the renderer and
       captures.
  - The summary shows people, images and minutes, the traits everyone shares, an example person (subject 1 of
    the run when a seed is set, otherwise a random one with **Another**), run name and seed, the status of
    the services the selection needs, and **Start run**. It stays disabled until those services are ready;
    runs started while another renders queue behind it.
  - All runs, newest first (including runs created from IEx), with their shared traits.
- **`/biometrics/<run>`**, one run:
  - Seed, prompt version, shared traits, renderer, steps and progress.
  - A **Friction-ridge quality** panel once the run has finished: verified, accepted, retried and rejected
    counts, NFIQ 2 and minutiae recall per impression type, and `bozorth3` mated against non-mated scores.
  - One card per subject with the description, **Download** and **Open identity**, and sections for Face,
    Rolled fingers, Slaps, Palms and Tenprint card, plus one section per extra capture.
  - Each tile shows its thumbnail, *Rendering…*, *Queued* or *Failed*, and a code: the pose code for faces,
    FGP for fingers, PLP for palms. Rolled fingers also show their pattern class (W, RL, LL, A, TA). Verified
    fingers and slaps show their NFIQ 2 score, marked when the image needed a retry or was rejected. Cards fill
    in live while the run is active.
  - Click a tile for the detail view: full image, size, seed and render time. Faces show the person and the
    exact prompt; friction-ridge shots show the ground truth (pattern, singular points, minutiae count,
    triradii), the verification results and a link to the ground-truth JSON. **Download** saves the image
    under the person's code. ←/→ moves between the subject's shots, and Esc closes it.
  - **Cancel** stops a queued or running run.
  - **Resume** appears whenever a subject is missing an image: cancelled, failed or grown runs, failed shots,
    and files deleted from disk (a note above the subjects says how many). It re-renders only what's missing,
    from the stored seeds and prompts (see [Determinism](#determinism-resuming-and-adding-shots)).
  - **Add shots** adds face shots or friction-ridge groups the run doesn't have yet to every subject.
- **`/biometrics/<run>/<subject>`**, one identity: the person's code, sex, age and description, every image,
  and a **Download** menu (see [Downloads](#downloads)) whose last entry, **NIST (.an2)…**, opens the NIST
  export.
- **`/biometrics/<run>/<subject>/nist`**, the [NIST export](#nist-export): what the enrolment holds, which face
  probes to add as searches, and PNG or WSQ, with the files and records the download will have.

Runs render in [Oban](https://oban.hexdocs.pm) jobs, not in the page's process:

- Creating a run queues one `GenerateSubject` job per subject. The `generation` queue runs one job at a time,
  since the GPU renders one image at a time and the ridge service uses every CPU core. Runs queue behind each
  other.
- A run continues if you close the page, and survives a restart: a job interrupted by one is rescued after half an
  hour and picks up where it stopped. Jobs retry up to 3 times; a job that runs out of attempts marks its run
  failed. While a service a job needs isn't ready (the Qwen model takes a while to load), the job waits.
- Every image, subject and run update is broadcast over PubSub (`Phantom.Biometrics.subscribe/0`), so open pages
  fill in live.
- Anything that starts the whole app (`mix run`, `iex -S mix`) starts Oban too, and takes jobs from the queue
  alongside a running server. Use `mix run --no-start` for scripts that only need the database.

Runs are stored in Postgres (see [Storage](#storage)). Images are served by id from `/images/:id`
(`?download=1` to save one), and a friction-ridge image's ground truth from `/images/:id/ground-truth`. Image
ids are UUIDv7s, never reused, so a browser that keeps images by URL can't show an old picture after the
database is reset.

## Downloads

One person downloads as a ZIP from their page (**Download**: everything, faces only, or fingerprints and palms
only, each with its image count and size), from their card on the run page, or directly:

```
GET /biometrics/<run>/<subject>/download?include=all|faces|prints
```

The archive is named after the person (`PH-5167-ED5B_synthetic.zip`, `…_faces_synthetic.zip`) and holds one
folder:

```
PH-5167-ED5B/
  README.txt                          synthetic-data notice, what each folder holds
  subject.json                        who, how, and every file with its SHA-256
  face/mugshot_frontal_F.png          the pose code ends the name
  fingerprints/rolled/fgp02_R_index.png
  fingerprints/rolled/fgp02_R_index_c2.png     extra captures end in _c2, _c3
  fingerprints/slaps/fgp13_Right_four.png
  palms/plp22_R_writers_palm.png
  card/tenprint_card.png
  ground_truth/fgp02_R_index.json     per print: minutiae, cores, deltas, verification
```

`subject.json` has the person's code, run, subject name, seed, description and attributes; the run's seed,
traits, prompt version, renderer, steps and captures; and a `files` list with each file's path, shot, label,
modality, position (pose code, FGP or PLP), capture (from 1), size, ppi, seed, prompt and reference image
(faces), byte size, SHA-256 and ground-truth file. Shots of the run that aren't in the download are listed
under `missing` with the reason (`not_rendered`, `error`, `skipped`, `file_missing`), and `complete` is false
while any are missing or the subject is still rendering; the README then says the download is partial.

`Phantom.Biometrics.Export` plans the archive and `DownloadController` streams it with
[`zstream`](https://hex.pm/packages/zstream): PNGs are stored uncompressed (they're compressed already) and read
from storage as the ZIP is sent, so a subject of 40–100 MB starts downloading at once and never sits in
memory.

### NIST export

The NIST export page (`/biometrics/<run>/<subject>/nist`) packages a person as ANSI/NIST-ITL 1-2011
Update:2015 transactions in Traditional encoding, for loading into an ABIS:

- **Enrolment** (`PH-5167-ED5B_enrol.an2`): prints and face, prints only, or face only. Faces are the mugshot set
  (Type-10); prints are the first capture of every rolled finger and slap (Type-14) and palm (Type-15). The card
  is left out.
- **Search** (`PH-5167-ED5B_search_aged.an2`, …): each face probe you pick (aged, changed appearance,
  re-booking, glasses, ICAO portrait) as its own transaction, mated with the enrolment.
- **Compression:** PNG (the stored images byte for byte) or WSQ (NIST `cwsq`, about 15:1) for prints and palms.
  Faces are PNG either way, flattened to RGB, since Type-10 allows neither WSQ nor alpha.

Enrolment alone downloads as the `.an2`, and with searches as a ZIP with a README. Every file marks itself as
synthetic: Type-1 domain `PHANTOM`, and a Type-2 record with the person's code (2.003) and "SYNTHETIC TEST DATA -
NOT A REAL PERSON - GENERATED BY PHANTOM" (2.004). The same is available directly:

```
GET /biometrics/<run>/<subject>/nist/download?content=prints_faces|prints|faces&compression=png|wsq&search[]=probe_aged
```

The record layout, field values and what's next (INTERPOL's XML format, run-level export, Type-9 minutiae) are in
[`nist-export-plan.md`](nist-export-plan.md).

## How it works

```
Phantom.Biometrics.create_run/1        from the web form or IEx
  └─ one Oban job per subject: Workers.GenerateSubject     (queue :generation, one at a time)
       └─ Generator.generate_subject/2
            ├─ FaceAttributes.sample/2              who the person is (with the run's Traits), or the
            │                                       subject's stored attributes when rendered before
            ├─ Generator.Faces                      face shots: FacePrompts + Services.Qwen   (python_inference, GPU, :8000)
            ├─ Generator.FrictionRidges             ridge shots: Services.Ridgegen            (python_biometrics, :8001)
            ├─ Storage.put/2                        the image file
            └─ Biometrics.save_image/2, complete_subject/1   rows + PubSub; the last subject builds the
                                                             Report (bozorth3 via Services.Ridgegen.match/2)
```

`Phantom.Biometrics.Shots` lists every shot across both modalities and expands group names. For example,
`rolled` becomes `rolled_01` … `rolled_10`, and `captures: 2` adds `rolled_01_c2` … after the first capture.
The face anchor is only added when there are face shots.

## Faces

### One anchor per person

For each subject the harness:

1. Samples a fictional person's appearance from the subject seed.
2. Generates the **anchor**, a frontal mugshot, from the text description alone.
3. Generates every other shot with the anchor as its **only reference image**.

Conditioning on the anchor keeps the identity consistent across poses and probes without a separate identity
model. The only reference image is always one the harness generated itself, so the tool can't be used to make
"mugshots" of a real person from an uploaded photo.

### Shots

Friction-ridge shots are described under [Friction ridges](#friction-ridges).

| Shot | ANSI/NIST pose | Size | Source |
|---|---|---|---|
| `mugshot_frontal` | F | 960×1280 (3:4) | text only (anchor) |
| `mugshot_left_profile` | L | 960×1280 | anchor |
| `mugshot_right_profile` | R | 960×1280 | anchor |
| `mugshot_three_quarter_left` / `_right` | A | 960×1280 | anchor |
| `icao_portrait` | F | 896×1152 (7:9, 35×45 mm) | anchor |
| `probe_rebooking` | F | 960×1280 | anchor |
| `probe_uncooperative` | A (POA ±20–35) | 960×1280 | anchor |
| `probe_aged` | F | 960×1280 | anchor |
| `probe_glasses` | F | 960×1280 | anchor |
| `probe_appearance` | F | 960×1280 | anchor |
| `probe_low_res` | F | 240×320, rendered at 960×1280 | anchor |

The default shots are the frontal, both profiles, `icao_portrait`, `probe_rebooking` and `probe_aged`.

- 960×1280 meets the size and 3:4 aspect of the ANSI/NIST-ITL level-40 mugshot (at least 768×1024). The
  export doesn't claim level 40 yet, since it also fixes composition and lighting. See
  [`image-resolution.md`](image-resolution.md).
- Shots rendered before this size (896×1120, 4:5) keep their size when rendered again.
- The inter-eye distance was about 150 px in the 896×1120 mugshots and 186 px in the ICAO portrait (median),
  above the ISO minimum of 90 px and the 120 px best practice. The first 960×1280 anchor measured 152 px: the
  3:4 frame shows more of the shoulders, so the head is about as large as before.
- 7:9 matches a 35×45 mm passport photo.
- A *left* profile shows the subject's left side, so they face the *left* edge of the image.

The **probes** are mated search images for ABIS testing: the same person with realistic variation.

| Probe | Variation |
|---|---|
| `probe_rebooking` | Booked again with the same camera, light and background: other clothes, a slightly different expression |
| `probe_uncooperative` | Booked drunk and disorderly: turned 20–35° away, chin up or down, bleary bloodshot eyes, dishevelled, rumpled clothes, glaring, sneering, shouting or half-asleep |
| `probe_aged` | 15 years later, aged for the age reached (see below) |
| `probe_glasses` | Glasses, window light, different clothing |
| `probe_appearance` | Beard grown or shaved (men), different hairstyle (women) |
| `probe_low_res` | A phone snapshot indoors or out (street, park, bar, car, kitchen…), scaled down to 240×320 |

Every probe also gets its own slight **head angle and expression** (`FacePrompts.variation/2`), since it's a
different photo from the reference: turned 4–19° to either side, chin level, raised or lowered, sometimes
leaning towards a shoulder, one of nine expressions (slight or broad smile, frown, raised eyebrows, squint,
mid-sentence…) and now and then a gaze past the camera. It's fixed per person and shot, so it reproduces. The
mugshots keep their standard poses and the ICAO portrait stays frontal and neutral. `probe_rebooking` is still a
booking photo, so it varies least: turned only 1–3°, chin level, no lean, eyes on the camera, and one of the
seven slight expressions (no broad smile, no open mouth). `probe_uncooperative` is the opposite, for bookings of
people who won't cooperate: turned 20–35° away, so it's exported as an angled pose (`A`) with that angle as
POA, chin raised or dropped, often leaning, and one of six expressions of its own, with the eyes past the
camera half the time. The prompt keeps both eyes visible so it stays a usable probe. It isn't a default shot.

`probe_low_res` is for the search images an ABIS really gets, which are often far worse than the enrolment. It's
rendered at mugshot size, then scaled down 4× (Lanczos) to 240×320, for an inter-eye distance of about 40 px,
in the 30–60 px range of real search images. YuNet still finds every face at that size: 107 frontal images
scaled down 4× measured 31–55 px (median 39), and the first real `probe_low_res` 35 px. Rendering small directly would give a clean face at any size, so
the resolution comes from the scaling and only the scene from the prompt. The scene is one of 14
(`FacePrompts.snapshot_scene/1`, fixed per person), each with its own place, light and background: a city
street, a park, a street at night, the seaside, a balcony, a bus stop, a bar, a restaurant, a kitchen, a car, an
office, a supermarket, a train or a living room. With only "indoors" in the prompt, every one came out as the same
room with a ceiling lamp. It isn't a default shot. See
[`image-resolution.md`](image-resolution.md).

The mugshots are one booking session, so scars look as on the anchor. The ICAO portrait and the probes are
taken at other times: their prompts say the scar has **healed** to a faint line in the same place.

`probe_aged` ages the person for the age they reach, since "15 years older" with one heavy list made an
18-year-old aged to 33 look 55: up to 35 only subtle maturing (no wrinkles, no grey hair), up to 49 fine lines
and a few grey strands, up to 64 clear lines and greyer hair, and the full list with age spots beyond that. The
prompt ends with "must look N, no older".

### Person attributes

`Phantom.Biometrics.FaceAttributes.sample(seed, opts)` returns a struct with these fields:

- sex, age, ancestry
- skin tone, eye colour, hair colour and style, facial hair
- face shape, build, clothing
- distinguishing marks (mole, scar, freckles and similar)

How they're chosen:

- Ancestry is one of 11 broad regions, sampled evenly by default so a gallery covers a wide range of
  appearances.
- Skin, eye and hair colours come from ranges that fit the ancestry.
- Grey hair and receding hairlines become more likely with age.
- Clothing (38 everyday items) is drawn from the ones for anyone and those for the person's sex. Each item has
  a main colour, so probes can change into a different one.
- Options: `female_share`, `age_range` and `ancestry_weights`, to match a specific population, and fixed values
  for any attribute (below).

`describe/1` renders the attributes as the sentence used in the anchor prompt, for example:

> a 69-year-old man of Latin American descent with light brown skin, hazel eyes, a round face, an average
> build, medium-length wavy white hair and a short full beard.

### Traits

`Phantom.Biometrics.Traits` is what a run fixes for all of its people; the run stores it (`runs.traits`) and
every subject is sampled with it. Unset traits are random per person, except the distinguishing mark: nobody
has one unless the run asks for a specific mark (everyone gets it) or `"random"` (about one in three, as
sampling on its own does).

| Trait | Values |
|---|---|
| `sex` | `female`, `male` |
| `age_min`, `age_max` | 18–90; an open end is 18 or 75 |
| `ancestry` | the 11 regions |
| `skin_tone`, `eye_color`, `hair_color`, `hair_texture` | the option lists; a fixed hair colour isn't greyed with age |
| `hair_style` | any style, for anyone |
| `facial_hair` | men only |
| `face_shape`, `build`, `clothing` | the option lists |
| `mark` | a mark, `random`, or `none` |

A fixed attribute still takes its random draw, so the attributes left random come out the same whatever is
fixed, and a run without traits samples exactly as before traits existed.

### Prompt design

`Phantom.Biometrics.FacePrompts` has two prompt styles.

- **Anchor and profiles** describe the photograph: a police booking photo, a plain mid-grey background, even
  flash lighting, a neutral expression, and "no text, no placard, no height chart".
  - Profiles spell out the direction redundantly ("faces the left edge of the image… nose pointing to the
    left"), because diffusion models often mix up left and right.
  - They also ask to keep the face, hair, clothing and background.
- **ICAO and probes** are written as edits: *"Edit the reference photo into… Changes: A; B; C. Keep the face
  shape, bone structure, eyes, nose, mouth, ears, skin tone and any scars, moles or freckles exactly the
  same."* For a subject with a scar the healed scar is one of the changes, and only moles and freckles are
  kept exactly.

The main lesson from the test runs: **with a reference image, Qwen copies it unless every change is a concrete
target state.**

| Vague prompt (ignored) | Concrete prompt (followed) |
|---|---|
| "Different clothing" | "he now wears a burgundy sweatshirt" |
| "Head tilted slightly" | "unlike the reference, the head is turned about 12 degrees towards the left of the image" |
| "A different expression" | "the expression changes to a slight frown, with the eyebrows drawn together" |
| "Fifteen years older" | "now 33 years old… only subtle, natural maturing… no wrinkles… She must look 33, no older" |

The probes therefore pick a replacement outfit deterministically, for the person's sex and in a different
colour from the mugshot outfit: "grey sweatshirt" in place of "grey t-shirt" read as no change.

Every run records `FacePrompts.version/0` (currently `faces-v11`). Bump it whenever a template changes.

| Version | Change |
|---|---|
| v1 | First templates. Anchor and profiles were good; ICAO and probes were near-copies of the anchor. |
| v2 | "Changes / Keep" edit prompts with concrete changes. ICAO, re-booking, aged and glasses improved a lot. |
| v3 | Distinct clothing list. Concrete hairstyle changes for women. Beard removal no longer shaves the head. |
| v4 | Scars have healed in the ICAO portrait and the probes. |
| v5 | Each probe gets its own slight head angle, expression and gaze. |
| v6 | Probe outfits follow the person's sex and change colour. |
| v7 | The aged probe ages for the age reached, capped with "must look N, no older". |
| v8 | Mugshots and probes render at 960×1280 (3:4). New low-resolution probe. |
| v9–v10 | The re-booking keeps the booking setup. New uncooperative probe. |
| v11 | The low-resolution probe is taken in one of 14 scenes, indoors and out, not always the same room. |

## Friction ridges

The service in [`python_biometrics/`](../python_biometrics/README.md) generates them in two stages. Its README
covers the algorithm, the API and the limitations.

1. **Identity:** SFinGe-style master patterns and per-capture geometry (placement, skin distortion, contact
   area). This fixes the ridges and the ground truth. It runs on the CPU.
2. **Appearance:** the `diffusion` renderer (the default) draws the capture procedurally, then runs it part-way
   through IMPOSE's latent diffusion model for rolled prints, which was trained on real prints. That swaps
   the drawn look for real ink texture and keeps the ridges. The `procedural` renderer skips the model: it's
   faster, CPU only, and looks computer-generated. Palms are always procedural.

| Group | Shots | Code | Size (500 ppi) |
|---|---|---|---|
| `rolled` | `rolled_01` … `rolled_10`: R thumb … R little, L thumb … L little | FGP 1–10 | 800 × 750 |
| `slaps` | `slap_13` right four, `slap_14` left four, `slap_15` two thumbs | FGP 13–15 | 1600 × 1500 |
| `palms` | `palm_21` R full, `palm_22` R writer's, `palm_23` L full, `palm_24` L writer's | PLP 21–24 | 2750 × 4000, 875 × 2500 |
| `card` | `tenprint_card`: rolled prints and slaps on an FD-249 style card | – | 4000 × 4000 |

How the images relate:

- **One subject, one set of hands.** Every friction-ridge image of a subject comes from the subject seed.
  - Each finger and palm has one master pattern.
  - A finger's rolled print, its place in a slap, the card and later captures all show the same ridges and
    pattern class.
  - Pattern classes follow population priors per finger: loops dominate, thumbs and ring fingers are often
    whorls, and ulnar loops point towards the little finger.
- **Captures.** `capture` 2 and 3 (`_c2`, `_c3`) are new impressions of the same masters, with a different
  placement, skin distortion, contact area, pressure and noise. They are mated pairs for ABIS tests.
- **Ground truth.** Each friction-ridge image stores its ground truth (`images.ground_truth`). For fingers and
  slaps it holds the pattern class, cores and deltas, and minutiae (x, y, angle, ending or bifurcation) in that
  image's pixel coordinates. For palms it holds the triradii in view. `images.meta` keeps a summary without the
  minutiae lists, for pages and reports.
- **Marking.** Every PNG is 8-bit grey with 500 ppi DPI metadata and `Synthetic=true` text chunks. The card's
  header says "SYNTHETIC TEST DATA - NOT A REAL PERSON".

### Verification

A diffusion model can move, drop or invent minutiae, and a matcher tolerates exactly that, so it can't catch it.
The service therefore checks every finger and slap it renders (`python_biometrics/verify.py`):

- NIST `mindtct` extracts minutiae from the rendered image and from the clean ridge map it was rendered from.
  The two sets are paired within 12 px and 30°, inside the contact area.
- **Recall** (share of the clean map's minutiae found) must be at least 0.85 and the **spurious rate** at most
  0.15. **NFIQ 2** must be at least 35, per finger for slaps.
- An image that fails is re-rendered with new appearance randomness (same ridges), up to 3 attempts. If none
  passes, the best attempt is kept and marked rejected.
- The results go into the ground truth (`verification`: metrics, attempts, the missed and spurious points, the
  detected minutiae) and a summary into `meta`.

At the end of a run the harness stores its report on the run (`runs.report`, see `Phantom.Biometrics.Report`):

- how many images were verified, accepted, accepted after a retry, or rejected
- NFIQ 2, recall and spurious-rate distributions per impression type
- `bozorth3` scores of mated pairs (captures of the same finger) against non-mated pairs (the same finger of
  different subjects), with the pairs on the wrong side of the threshold of 40 listed

Baseline, 3–4 subjects with 2 captures each:

| Renderer | Rolled NFIQ 2 | Plain NFIQ 2 | Minutiae recall | Accepted | Mated min / non-mated max |
|---|---|---|---|---|---|
| Procedural | 47 (39–56) | 54 (48–63) | 0.98 | 100% | 112 / 27 |
| Diffusion | 46 (40–55) | 53 (45–63) | 0.92 | 99% first time, 100% after retries | 114 / 30 |

## Determinism, resuming and adding shots

Every value is derived from the run seed (and the run's traits):

| Value | Derived from |
|---|---|
| Subject seed | `phash2({run_seed, subject_index})` |
| Attributes | Subject seed and the run's traits |
| Prompts, probe pose and expression | Attributes, shot |
| Per-shot face image seed | `phash2({subject_seed, shot})` |
| Finger and palm masters, captures | Subject seed, finger or palm code, capture number |
| Rendering (procedural noise, diffusion seed) | Subject seed, shot code, capture number, attempt number |

What was derived is also stored, and rendering again starts from what's stored: a subject keeps the seed and
attributes it was first rendered with, and a face shot its prompt, seed and size. So a deleted image comes
back from the same inputs even after the attribute lists or prompt templates have changed. Bit-identical
output also needs the same model weights, library versions and GPU behaviour, which aren't recorded yet.

- **Resume** (`Biometrics.resume_run/1`, or **Resume** in the UI) queues every subject missing a stored image
  of one of the run's shots: not rendered, failed, skipped, or its file deleted. Images already stored are
  kept. Queued subjects count as incomplete until they're done, so the run finishes with the last of them.
- **Add shots** (`Biometrics.add_shots/2`, or **Add shots**) adds shots or groups to a run that isn't
  rendering and queues its subjects. Seeds are per shot, so a shot added later is the one the run would have
  had with it from the start. New shots use today's prompt templates; each image stores its own prompt.
- If a shot fails, the error is recorded and the run continues. If the anchor fails, that subject's other face
  shots are marked `skipped`.

## Storage

Runs live in three Postgres tables, written as a run renders so pages can follow it:

| Table | One row per | Holds |
|---|---|---|
| `runs` | run | name, seed, status (`queued`, `running`, `finished`, `cancelled`, `failed`), shots, captures, renderer, steps, prompt version, traits, subject count, quality report, error, start and finish times |
| `subjects` | synthetic person | run, position, name (`subject_001`), seed, description, sampled attributes, when every shot was attempted |
| `images` | shot of a subject (UUIDv7 id) | shot and capture, status (`ok`, `error`, `skipped`), size, seed, prompt, the anchor it was conditioned on, storage key, byte size, SHA-256, ground-truth summary (`meta`) and full ground truth, duration, error |

Image files are kept by `Phantom.Biometrics.Storage`. The default backend, `Storage.Local`, writes them to
`config :phantom, :biometrics_output_dir` (default `data/synthetic/biometrics`):

```
data/synthetic/biometrics/<run>/
  subject_001/
    mugshot_frontal.png
    rolled_01.png
    rolled_01_c2.png       (second capture)
    slap_13.png
    palm_21.png
    tenprint_card.png
    ...
```

The database only stores each file's key (`<run>/subject_001/rolled_01.png`), so another backend (S3, say) can
implement the `Storage` behaviour (`put`, `read`, `stream`, `exists?`, `local_path`) and be set with
`config :phantom, :biometrics_storage`.

## Qwen service changes

- **`render/2`:** `Phantom.ImageGeneration` was split. `render/2` returns the PNG and seed without saving
  anything, and accepts an explicit `:width`/`:height`. `generate/2`, used by the main page, still saves to
  `priv/static/uploads`.
- **VAE tiling in `python_inference/server.py`:**
  - Tiled VAE decoding used to be on for every image. It leaves faint vertical seams where its 256 px tiles blend
    (every 192 px), visible on the plain backgrounds.
  - It is now used only above `QWEN_VAE_TILING_MIN_PIXELS` (default 2,000,000 px), so the ~1 MP face images
    decode in one pass.
  - If an untiled decode runs out of GPU memory, it is retried once with tiling and the same seed.
  - The change takes effect after `mix phx.server` is restarted.


## Performance

- **Faces:** on an RTX 4090 with CPU offload, each image takes about 41–44 s at 40 steps, so the six default face
  shots take about 4.5 minutes per subject.
- **Friction ridges:** measured on 24 CPU cores.

  | Work | Time |
  |---|---|
  | Finger master | 2 s |
  | Palm master | 25 s |
  | Further impression | 0.1–3 s |
  | All 18 friction-ridge shots with 2 captures (36 images), procedural | about 1.5 minutes per subject |

  Verification adds about 1 s per finger and 2 s per slap. The diffusion renderer on the RTX 4090 adds about
  0.3 s per rolled print (1.9 GB VRAM) and 1 s per slap (6.5 GB VRAM); the card re-renders its 13 prints, about
  20 s. 10 rolled, 3 slaps and the card with 2 captures took about 1.8 minutes per subject.

That's fine for prompt work and galleries of a few thousand subjects. Large ABIS gallery fills (100k+) would need
a faster face generator; see the plan document.

## Tests

The Elixir tests stub both services with `Req.Test`, run Oban in `:manual` testing mode (jobs are rendered by
draining the queue in the test process) and store images under `tmp/test/biometrics`:

- `test/phantom/biometrics_test.exs`: the context. Listing and reading runs, queueing one job per subject,
  resume (including deleted files and finishing with the last subject), adding shots, cancel, failure,
  progress and events.
- `test/phantom/biometrics/`
  - **Generator:** face anchor conditioning; friction-ridge shots from the subject seed with ground truth;
    the renderer; resuming keeps stored images; failed shots; the quality report.
  - **GenerateSubject worker:** renders, snoozes while a service is down, stops for cancelled runs, marks runs
    failed when discarded.
  - **Rendering from stored inputs:** stored attributes and prompts win over today's code; a shot added later
    matches one rendered with the run.
  - **Attributes, traits and prompts:** fixed traits for everyone, draws left alone, marks only on request,
    clothing by sex, healed scars, probe variation, age-scaled ageing.
  - **Export:** archive paths, the manifest and hashes, include filters, missing files, the download summary.
  - **NIST export:** each transaction decoded back and checked (CNT, IDCs, field values, the synthetic marker,
    image bytes), content and search choices, the ZIP, missing shots. With real images: faces flattened to RGB,
    WSQ, and NBIS `an2ktool` reading every record (skipped without the NBIS tools).
- `test/phantom/nist/`: the ANSI/NIST-ITL codec, ported from abis_next, and every record builder's fields.
  - **Shots, request validation, storage, gallery and the quality report.**
- `test/phantom/services/`: the Qwen and ridgegen clients, and the supervised Python processes.
- `test/phantom_web/`
  - **The pages:** the new-run form (traits, shot picks, summary), services, run list and statuses, queued
    runs, sections, tiles, detail views with prompt or ground truth, resume, add shots and cancel, download
    links, the NIST export page, the landing page and gallery, and the layout (navigation, footer).
  - **The controllers:** images (and `?download=1`, and 404 for unknown ids), subject downloads (the ZIP
    itself), NIST downloads, and the branded error pages.

`python_biometrics/tests/` (run with `.venv/bin/python -m pytest`) covers:

- determinism and image sizes
- captures that share a pattern but differ
- minutiae that stay inside the print
- slap finger order, and slap fingers whose patterns match the rolled prints
- palms and the card
- the HTTP API, including 500 ppi and synthetic PNG metadata
- verification: minutiae pairing, and procedural prints that pass while a different finger fails (needs the
  NIST tools)
- the diffusion renderer: deterministic, keeps the ridges (needs `setup.sh --diffusion` and a GPU)

## Known issues and next steps

- **Faces**
  - Check the v4–v7 prompt changes on a larger set of renders: healed scars, probe pose and expression, the
    aged probe across ages, and probe outfits.
  - Record the model and service versions (Qwen checkpoint, torch/diffusers, ridgegen) with each image, so a
    re-render can be checked against its stored SHA-256.
  - The ICAO crop should be tighter: chin to crown should fill about 75% of the image height.
  - Render mugshots at 3:4 (960×1280) so they can meet ANSI/NIST mugshot level 40, which INTERPOL's format
    needs (level 30 or higher); see [`image-resolution.md`](image-resolution.md).
  - Build ("heavy-set", "slim") is mostly ignored. This matters little for a head-and-shoulders image.
  - Identity consistency has only been checked by eye. Next, add a face-embedding check against the ABIS
    matcher if its API is available, otherwise ArcFace:
    - reject new subjects that are too similar to existing ones
    - reject probes that no longer match their anchor
- **Friction ridges**
  - Next steps of [`realistic-fingerprints-plan.md`](realistic-fingerprints-plan.md): acquisition styles
    (livescan, dry, low quality) need a conditioned model; the diffusion model only knows inked rolled prints.
  - Slaps: adjacent fingers can touch with hard seams, and the middle phalanx is a straight-edged patch. The
    diffusion renderer makes this more visible. Render plain fingers separately and fix the layout (plan phase 3).
  - Ground-truth minutiae angles point the opposite way from ANSI/INCITS 378 (`mindtct` differs by about 180°).
  - Latent prints are not generated yet.
  - 500 ppi is the right resolution for now; 1000 ppi only if a target ABIS needs it
    ([`image-resolution.md`](image-resolution.md)).
- **Downloads:** a whole run as one archive (one folder per person, one manifest), in both formats.
- **NIST export:** INTERPOL's XML format (INT-I v6), captures 2 and 3 of the prints as searches, and Type-9
  ground-truth minutiae ([`nist-export-plan.md`](nist-export-plan.md)).
- **Later:** an S3 storage backend, and access control before the app is deployed anywhere shared (it has no
  login, so anyone who can reach it can start runs and download).

## Caveats

- **What it's good for.** Synthetic images suit functional, integration, format and load testing. They are weak
  evidence of ABIS matching accuracy or demographic performance.
- **Accidental resemblance.** A generated face can resemble a real person by chance, and so can a synthetic
  fingerprint: a foreign AFIS can false-match it. Keep outputs marked as synthetic, and keep them out of
  production and live-exchange systems.
- **Licences.** Check the Qwen-Image-2.1 licence, and the licence of any future model, for your use before
  relying on the output. IMPOSE's code and weights are Apache 2.0; its training data isn't documented, so a
  check that rendered prints don't reproduce real ridge detail is still open (plan section 9).

## Code map

| File | What it does |
|---|---|
| `lib/phantom/biometrics.ex` | The context: runs, subjects, images and identities; create, resume and cancel; events |
| `lib/phantom/biometrics/workers/generate_subject.ex` | Oban worker rendering one subject; marks runs failed when discarded |
| `lib/phantom/biometrics/generator.ex`, `generator/` | Renders a subject: seeds, anchor conditioning, face and friction-ridge shots |
| `lib/phantom/biometrics/{run,subject,image}.ex` | Ecto schemas for the `runs`, `subjects` and `images` tables |
| `lib/phantom/biometrics/run_request.ex` | Validates the parameters of a new run |
| `lib/phantom/biometrics/traits.ex` | The appearance a run fixes for everyone: validation, sampling options, display |
| `lib/phantom/biometrics/export.ex` | One subject as a ZIP: file names, manifest, README, the streamed archive |
| `lib/phantom/biometrics/nist_export.ex` | One subject as ANSI/NIST-ITL transactions: enrolment and searches, records, the stream |
| `lib/phantom/biometrics/nist_images.ex` | Image data for NIST records: PNG or WSQ (`cwsq`) prints, faces without alpha |
| `lib/phantom/nist/` | The ANSI/NIST-ITL codec: record framing and Type-1, 2, 10, 14 and 15 builders |
| `lib/phantom/biometrics/storage.ex`, `storage/local.ex` | Where image files live: the storage behaviour and its local-disk backend |
| `lib/phantom/biometrics/shots.ex` | Registry of all shots across modalities; group and capture expansion |
| `lib/phantom/biometrics/report.ex` | Run quality report: verification outcomes, bozorth3 mated vs non-mated |
| `lib/phantom/biometrics/gallery.ex` | Identities for the landing page gallery |
| `lib/phantom/biometrics/face_attributes.ex` | Seeded person sampling (with fixed traits), option lists, `describe/1` |
| `lib/phantom/biometrics/face_prompts.ex` | Shot specs, prompt templates, probe variation, prompt version |
| `lib/phantom/services/qwen.ex`, `ridgegen.ex` | HTTP clients for the two Python services |
| `lib/phantom/services/python_process.ex` | Supervises both Python services as OS processes (`QwenProcess`, `RidgegenProcess`) |
| `lib/phantom_web/live/landing_live.ex` | `/`: what Phantom is, and the gallery of identities |
| `lib/phantom_web/live/biometrics_live.ex` | `/biometrics`: new-run form with traits and summary, the run rendering now, run list |
| `lib/phantom_web/live/biometrics_run_live.ex` | `/biometrics/:run` and `/:run/:subject`: subjects, live progress, detail view, resume, add shots, cancel, download menu |
| `lib/phantom_web/live/nist_export_live.ex` | `/biometrics/:run/:subject/nist`: the NIST export page |
| `lib/phantom_web/components/layouts.ex`, `layouts/root.html.heex` | Page frame: header, navigation, footer, theme toggle, icons |
| `lib/phantom_web/components/biometrics_components.ex` | Shared UI pieces: shot tiles, labels, statuses, progress bar, report |
| `lib/phantom_web/controllers/image_controller.ex` | Serves image files (and single-image downloads) and ground truth by image id (UUIDv7) |
| `lib/phantom_web/controllers/download_controller.ex` | Streams a subject's ZIP, and its NIST transactions |
| `lib/phantom_web/controllers/error_html.ex`, `error_html/` | Branded 404 and 500 pages |
| `assets/css/app.css`, `priv/static/images/`, `priv/static/fonts/` | Brand: theme colours, the mark and icons, Inter (SIL OFL) |
| `python_inference/server.py` | Qwen-Image-2.1 FastAPI service (size-dependent VAE tiling) |
| `python_biometrics/server.py`, `ridgegen/` | Friction-ridge FastAPI service and generator (see its README) |
| `python_biometrics/verify.py`, `diffusion.py` | Verification with NIST tools; the diffusion renderer |
