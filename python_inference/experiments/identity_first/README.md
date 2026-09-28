# Identity-first anchors (experiment)

Can a sampled synthetic identity, rendered by [Arc2Face](https://github.com/foivospar/Arc2Face) and given to Qwen
as the anchor's only reference, make a run's people as unlike each other as real strangers? Results and
reasoning: [`docs/face-source-conditioning-plan.md`](../../../docs/face-source-conditioning-plan.md) §8. Nothing
here is used by the app.

```bash
./setup.sh                                   # once: Arc2Face, its venv and models (about 6 GB)
PY=../../../data/experiments/identity_first/Arc2Face/.venv/bin/python
$PY embed_pool.py                            # FairFace White men in Arc2Face's ArcFace space (3 min, CPU)
$PY arc2face_faces.py temp_1.0 --count 24 --samples 4 --seed 7
$PY survey.py temp_1.0                       # screen, pick a sample per identity, spread, contact sheet
$PY clean_references.py temp_1.0 24          # needs mix phx.server (Qwen on :8000, biometrics on :8001)
$PY match_ages.py temp_1.0 subjects24.json   # identity per subject by apparent age
A=../../../data/experiments/identity_first/temp_1.0/cleaned/assign_age.json
$PY qwen_anchors.py temp_1.0 subjects24.json --faces cleaned --assign $A --out anchors_agematch
$PY measure.py temp_1.0 subjects24.json --anchors anchors_agematch --assign $A
```

| Script | Step |
|---|---|
| `embed_pool.py` | FairFace's frontal adult White men, embedded with Arc2Face's ArcFace, to fit the identity distribution |
| `arc2face_faces.py` | Sample separated identities from it and render each with Arc2Face |
| `pick.py`, `survey.py` | Screen every sample with the face pool's rules, pick one per identity, measure the picks |
| `clean_references.py` | Clean each picked face with a Qwen edit: frontal, neutral, no glasses or hat, plain light (`--ages`: also the subject's age) |
| `match_ages.py` | Give each subject the identity whose cleaned face looks closest to its age |
| `qwen_anchors.py` | Anchors with Qwen, the picked (or cleaned) face as the only reference (mugshot framing by default) |
| `measure.py` | Spread, identity kept, leakage, rules, age, contact sheet |
| `subjects.json`, `subjects24.json` | Attributes of 12 and 24 Northern European men (the face-gate run; run seed 20260928) |

Outputs go to `data/experiments/identity_first/<run>/`. The pilot's are in `pilot/`: the 12 identities of
`arc2face_faces.py pilot --samples 2` (sampled the same way, other sample seeds), anchors with the close-up
reference.
