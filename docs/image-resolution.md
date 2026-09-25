# Image resolution: faces and fingerprints

Research notes, 2026-09-25: what resolution Phantom's images should have, from the standards an ABIS expects and
from NIST's measurements of how resolution affects matching. Short version:

- **Faces:** Phantom's faces already pass the ISO inter-eye distance rules. Changing mugshots from 4:5 to 3:4
  (960 × 1280) would also meet the next ANSI/NIST mugshot level, 40, on size and aspect. Higher resolutions don't
  help matching.
- **Fingerprints:** stay at 500 ppi. Phantom's prints are exactly the standard 500 ppi sizes, and everything
  Phantom verifies with works only at 500 ppi. 1000 ppi only pays off for latents and pore-level detail, which
  Phantom doesn't model.

## 1. Faces

### What the standards ask for

| Source | Requirement |
|---|---|
| ISO/IEC 39794-5:2019 (ICAO eMRTD portraits) | Inter-eye distance (IED) of at least **90 px** |
| ISO/IEC 19794-5:2011 | IED of **120 px** or more as best practice |
| ANSI/NIST-ITL mugshot level (SAP) 30 | At least **480 × 600**, aspect **1:1.25 (4:5)**, 18% grey background, three-point lighting |
| SAP 40 | At least **768 × 1024**, aspect **3:4**, "head and shoulders" composition, plus the level-30 rules |
| SAP 50 / 51 | At least **3300 × 4400** (head and shoulders) / **2400 × 3200** (head only): forensic detail, about 10 px per mm on the face |
| SAP 32 / 42 / 52 | The mobile-device versions of 30 / 40 / 50 |
| INTERPOL INT-I v6 | 10.013 SAP must be **30 to 52** ("to ensure a minimum quality level") |

SAP levels are more than pixel counts. Level 30 and above also fix background, lighting, pose and framing
(ANSI/NIST-ITL Annex E), and levels 40 and above add compression rules (JPEG 2000 for non-frontal images, one
lossless frontal).

### What resolution does to matching

- **Matchers stop improving well below these sizes.** In NIST IR 7830 the tested algorithms still performed well
  down to an IED of **24 px** and images of 2,000 bytes.
- NIST's FRVT "wild" photos average an IED of 38 px. NIST IR 8009 gives about 120 px for ISO standard images
  and about 800 px for forensic-quality ones.
- The high levels (SAP 50/51) are there so a human examiner can compare fine facial detail, not for algorithms.

### What Phantom has

Measured with the YuNet face detector (OpenCV) on every generated face in `data/synthetic/biometrics`, 106
images:

| Shot | Size | Aspect | Median IED | Lowest IED |
|---|---|---|---|---|
| Frontal mugshot | 896 × 1120 | 4:5 | 149 px | 116 px |
| ICAO portrait | 896 × 1152 | 7:9 | 186 px | 145 px |
| Re-booking probe | 896 × 1120 | 4:5 | 153 px | 140 px |
| Aged probe | 896 × 1120 | 4:5 | 150 px | 124 px |

- Every face clears the 90 px ISO minimum, and nearly all clear 120 px.
- The mugshots fit SAP 30 on size and aspect.
- They have more pixels than SAP 40 needs, but its 3:4 aspect rules them out.
- A face takes about 48 s to render at this size. The inference server tiles the VAE for large images, and
  Qwen-Image's native area is about 1.7 MP (about 1152 × 1536 at 3:4).

### Recommendations

1. **Render mugshots at 3:4, 960 × 1280.** They then meet SAP 40's size and aspect, and keep an IED around
   160 px. That's 23% more pixels, so somewhat longer renders; 1152 × 1536 is the ceiling before exceeding the
   model's native area. Claiming SAP 40 in an export still needs the composition and lighting rules checked.
2. **Don't aim for SAP 50/51.** 8–15 MP from a diffusion model is invented detail at great cost, and matchers
   don't benefit.
3. **Consider low-resolution probes.** Real search images are often worse than enrolment. An optional downscaled
   probe (IED 30–60 px) would test an ABIS more realistically than a studio-quality one.
4. **INTERPOL:** the NIST export writes SAP 20 (mugshots) and 0 (others), which INT-I rejects. INT-I needs faces
   that genuinely meet SAP 30 or 40 (see [nist-export-plan.md](nist-export-plan.md)).

## 2. Fingerprints and palms

### What the standards ask for

ANSI/NIST-ITL fingerprint acquisition profiles (FAP, Table 14):

| FAP | Resolution | Minimum area (w × h) | Compression | Fingers |
|---|---|---|---|---|
| 10 / 20 / 30 | 500 ppi ± 2% | 0.5 × 0.65 to 0.8 × 1.0 in | WSQ, max 10:1 | 1 (livescan only) |
| 40 | 500 ppi ± 2% | 1.6 × 1.5 in | WSQ, max 10:1 | 1–2 (livescan only) |
| 45 | 500 ppi ± 1% | 1.6 × 1.5 in | WSQ, max 15:1 | 1 |
| 50 | 500 ppi ± 1% | 3.2 × 2.0 in | WSQ 3.1+, max 15:1 | 1–4 |
| 60 | 500 ppi ± 1% | 3.2 × 3.0 in | WSQ 3.1+, max 15:1 | 1–4 |
| 145 / 150 / 160 | 1000 ppi ± 1% | as 45 / 50 / 60 | **JPEG 2000**, max 10:1 | as 45 / 50 / 60 |

- **500 ppi is the baseline everywhere:** FBI EBTS, FAP 10–60, and WSQ, which was designed for 500 ppi only.
- **1000 ppi** needs JPEG 2000 instead of WSQ (ANSI/NIST-ITL 7.7.5.2). It's the minimum for "level 3" features
  such as pores, and preferred for latents.
- **INTERPOL INT-I** "strongly recommends" 1000 ppi for Type-14 and Type-15, but accepts 500 ppi with WSQ, and
  suggests devices of FAP 45 or better.
- **NFIQ 2** was built for 500 ppi and "shall not be used for images of different resolution". NBIS `mindtct`
  and `bozorth3` assume 500 ppi too.

### What resolution does to matching

- In NIST's ELFT Phase II, 5 of 8 matchers found somewhat more hits searching latents at 1000 ppi than at 500 ppi,
  but the gain was **not statistically significant**. The tenprint galleries were all 500 ppi.
- Tenprint-to-tenprint matching is minutiae-based, and 500 ppi resolves minutiae fully. That's why exemplar
  galleries stay at 500 ppi.

### What Phantom has

| Shot | Pixels | Inches at 500 ppi | Profile |
|---|---|---|---|
| Rolled finger | 800 × 750 | 1.6 × 1.5 | FAP 45 minimum |
| Slap (4 fingers, two thumbs) | 1600 × 1500 | 3.2 × 3.0 | FAP 60 |
| Full palm | 2750 × 4000 | 5.5 × 8.0 | Standard maximum |
| Writer's palm | 875 × 2500 | 1.75 × 5.0 | Standard maximum |

The export writes exactly 500 ppi, so there's no resolution error. WSQ uses `cwsq`'s 0.75 bit rate, which NBIS
documents as 15:1, the FAP 45–60 maximum. One real rolled print came out at about 21:1, because its white
background compresses well. Whether that ratio or the bit rate is what a receiver checks is worth confirming
before claiming a FAP level.

### Recommendations

1. **Stay at 500 ppi.**
   - Phantom's own checks (NFIQ 2, `mindtct`, `bozorth3`) and the diffusion renderer (IMPOSE, trained at
     512 × 512, about 500 ppi) all work at 500 ppi.
   - 1000 ppi means four times the pixels and render time.
   - The ridge generator doesn't model pores, so a "1000 ppi" print would be an upscaled 500 ppi one, with a
     resolution field that claims detail that isn't there.
2. **Revisit only for a concrete need:** a target ABIS that only ingests 1000 ppi, or latent testing that needs
   level-3 detail. Then generate at 1000 ppi natively (ridge period about 18–20 px instead of 9–10) and export
   as JPEG 2000, rather than upscale.

## Sources

- ANSI/NIST-ITL 1-2011 Update:2015, NIST SP 500-290 Ed. 3
  ([PDF](https://www.netxsolutions.co.uk/downloads/ANSI%20NIST%20ITL%201-2011%20Update%202015.pdf)): face SAP
  levels 7.7.5.1 and Table 12, Annex E; FAP Table 14; resolution tolerance 7.7.6.1 and Table 18.
- [INTERPOL INT-I v6.00.01](https://www.interpol.int/content/download/15373/file/NIST%20INTERPOL%20standard%20v6.00.01.pdf):
  10/SAP value range 30–52; Type-14/15 resolution and compression (6.7, 6.8); 14/FAP notes.
- [State of the Art of Quality Assessment of Facial Images](https://arxiv.org/pdf/2211.08030): IED rules of
  ISO/IEC 39794-5 and 19794-5.
- [ICAO TR: ISO/IEC 39794-5 Application Profile for eMRTDs](https://www.icao.int/sites/default/files/TRIP/Publications/ICAO-TR-39794-5-eMRTD-Application-Profile.pdf).
- [NIST IR 7830: Performance of Face Recognition Algorithms on Compressed Images](https://nvlpubs.nist.gov/nistpubs/Legacy/IR/nistir7830.pdf)
  ([summary](https://www.nist.gov/publications/performance-face-recognition-algorithms-compressed-images)).
- [NIST IR 8009: Face Recognition Vendor Test](https://nvlpubs.nist.gov/nistpubs/ir/2014/NIST.IR.8009.pdf).
- [ELFT Phase II: evaluation of automated latent fingerprint identification](https://tsapps.nist.gov/publication/get_pdf.cfm?pub_id=901870).
- [NIST SP 500-289: Compression Guidance for 1000 ppi Friction Ridge Imagery](https://nvlpubs.nist.gov/nistpubs/specialpublications/NIST.SP.500-289.pdf).
- [NIST IR 7780: JPEG 2000 compression of 1000 ppi latents](https://nvlpubs.nist.gov/nistpubs/ir/2013/NIST.IR.7780.pdf).
- [NFIQ 2 documentation](https://pages.nist.gov/NFIQ2/docs/v2.3.0/) and [NFIQ 2 at NIST](https://www.nist.gov/services-resources/software/nfiq-2).
- [YuNet face detector](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet), used for
  the IED measurements.
