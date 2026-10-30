# Fanous DMX channel map

Generated from `Sources/FanousCore/Parameters/ChannelMap.swift` by `fanousd channel-map`; do not edit by hand. 16-bit parameters use coarse/fine on adjacent channels. OSC: `/fanous/layer/{n}/{key}`, `/master/{key}`, `/output/{n}/{key}`, `/keystone/{n}/{key}` (float = normalized 0–1, int = raw).

## Layer mode (64 channels)

| Ch | Parameter | Bits | Default | Mapping | OSC key |
|---|---|---|---|---|---|
| 1–2 | Intensity | 16 | 0 | 0 → 0 % · 65535 → 100 % | `intensity` |
| 3 | Folder | 8 | 0 | 0 = none · 1–255 | `folder` |
| 4 | File | 8 | 0 | 0 = none · 1–255 | `file` |
| 5 | Play mode | 8 | 0 | 0–15 Loop fwd · 16–31 Loop rev · 32–47 Once hold · 48–63 Once hold rev · 64–79 Once black · 80–95 Once black rev · 96–111 Bounce · 112–127 Freeze · 128–143 Timecode · 144–159 Scrub · rest = Loop fwd | `playMode` |
| 6–7 | Speed | 16 | 32768 | 0 → 0 % · 32767 → 100 % · 32768 → 100 % · 65535 → 400 % | `speed` |
| 8–9 | In point | 16 | 0 | 0 → 0 % · 65535 → 100 % | `inPoint` |
| 10–11 | Out point | 16 | 65535 | 0 → 0 % · 65535 → 100 % | `outPoint` |
| 12 | Dissolve | 8 | 0 | 0 → 0 s · 255 → 25.5 s | `dissolve` |
| 13–14 | Position X | 16 | 32768 | 0 → -100 % · 32768 → 0 % · 65535 → 100 % | `positionX` |
| 15–16 | Position Y | 16 | 32768 | 0 → -100 % · 32768 → 0 % · 65535 → 100 % | `positionY` |
| 17–18 | Position Z | 16 | 32768 | 0 → -100 % · 32768 → 0 % · 65535 → 100 % | `positionZ` |
| 19–20 | Scale X | 16 | 32768 | 0 → 0 % · 32767 → 100 % · 32768 → 100 % · 65535 → 800 % | `scaleX` |
| 21–22 | Scale Y | 16 | 32768 | 0 → 0 % · 32767 → 100 % · 32768 → 100 % · 65535 → 800 % | `scaleY` |
| 23 | Fit mode | 8 | 0 | 0–63 Fit · 64–127 Fill · 128–191 Stretch · 192–255 Native · rest = Fit | `fitMode` |
| 24–25 | Rotation X | 16 | 32768 | 0 → -180° · 32768 → 0° · 65535 → 180° | `rotationX` |
| 26–27 | Rotation Y | 16 | 32768 | 0 → -180° · 32768 → 0° · 65535 → 180° | `rotationY` |
| 28–29 | Rotation Z | 16 | 32768 | 0 → -180° · 32768 → 0° · 65535 → 180° | `rotationZ` |
| 30 | Red | 8 | 255 | 0 → 0 % · 255 → 100 % | `red` |
| 31 | Green | 8 | 255 | 0 → 0 % · 255 → 100 % | `green` |
| 32 | Blue | 8 | 255 | 0 → 0 % · 255 → 100 % | `blue` |
| 33 | Brightness | 8 | 128 | 0 → -100 % · 128 → 0 % · 255 → 100 % | `brightness` |
| 34 | Contrast | 8 | 128 | 0 → 0 % · 128 → 100 % · 255 → 200 % | `contrast` |
| 35 | Saturation | 8 | 128 | 0 → 0 % · 128 → 100 % · 255 → 200 % | `saturation` |
| 36 | Hue | 8 | 0 | 0 → 0° · 255 → 360° | `hue` |
| 37 | Blend mode | 8 | 0 | 0–15 Normal · 16–31 Add · 32–47 Screen · 48–63 Multiply · 64–79 Subtract · 80–95 Difference · 96–111 Lighten · 112–127 Darken · rest = Normal | `blendMode` |
| 38 | Effect 1 | 8 | 0 | 0–15 None · 16–31 Blur · 32–47 Pixelate · 48–63 Mirror · 64–79 Kaleidoscope · 80–95 Invert · 96–111 Strobe · 112–127 Luma key · 128–143 Chroma key · 144–159 Edge · 160–175 Threshold · 176–191 Tint · rest = None | `effect1` |
| 39 | Effect 1 param A | 8 | 0 | 0 → 0 % · 255 → 100 % | `effect1A` |
| 40 | Effect 1 param B | 8 | 0 | 0 → 0 % · 255 → 100 % | `effect1B` |
| 41 | Effect 2 | 8 | 0 | 0–15 None · 16–31 Blur · 32–47 Pixelate · 48–63 Mirror · 64–79 Kaleidoscope · 80–95 Invert · 96–111 Strobe · 112–127 Luma key · 128–143 Chroma key · 144–159 Edge · 160–175 Threshold · 176–191 Tint · rest = None | `effect2` |
| 42 | Effect 2 param A | 8 | 0 | 0 → 0 % · 255 → 100 % | `effect2A` |
| 43 | Effect 2 param B | 8 | 0 | 0 → 0 % · 255 → 100 % | `effect2B` |
| 44 | Crop left | 8 | 0 | 0 → 0 % · 255 → 100 % | `cropLeft` |
| 45 | Crop right | 8 | 0 | 0 → 0 % · 255 → 100 % | `cropRight` |
| 46 | Crop top | 8 | 0 | 0 → 0 % · 255 → 100 % | `cropTop` |
| 47 | Crop bottom | 8 | 0 | 0 → 0 % · 255 → 100 % | `cropBottom` |
| 48 | Audio volume | 8 | 0 | 0 → 0 % · 255 → 100 % | `audioVolume` |
| 49 | Audio pan | 8 | 128 | 0 → -100 % · 128 → 0 % · 255 → 100 % | `audioPan` |
| 50 | Control | 8 | 0 | 0–7 Idle · 8–15 Retrigger · 16–23 Resync audio · 24–31 Clear error · rest = Idle | `control` |
| 51 | Sync | 8 | 0 | 0–9 Off · 10–19 Master 1 · 20–29 Master 2 · 30–39 Master 3 · 40–49 Master 4 · 50–59 Master 5 · 60–69 Master 6 · 70–79 Master 7 · 80–89 Master 8 · 90–99 Slave 1 · 100–109 Slave 2 · 110–119 Slave 3 · 120–129 Slave 4 · 130–139 Slave 5 · 140–149 Slave 6 · 150–159 Slave 7 · 160–169 Slave 8 · 170–255 Off · rest = Off | `sync` |
| 52–64 | Reserved | — | 0 | ignored | — |

## Master mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping | OSC key |
|---|---|---|---|---|---|
| 1–2 | Master intensity | 16 | 65535 | 0 → 0 % · 65535 → 100 % | `intensity` |
| 3 | Control | 8 | 0 | 0–63 Normal · 64–127 Freeze all · 128–191 Blackout · rest = Normal | `control` |
| 4 | Test pattern | 8 | 0 | 0–15 Off · 16–31 Grid · 32–47 Colour bars · 48–63 Blend check · 64–79 Output ID · 80–95 Crosshair · 96–111 Grey steps · 112–127 Checkerboard · 128–143 Grey 0 % · 144–159 Grey 25 % · 160–175 Grey 75 % · 176–191 White · rest = Off | `testPattern` |
| 5–6 | Master speed | 16 | 32768 | 0 → 0 % · 32767 → 100 % · 32768 → 100 % · 65535 → 400 % | `speed` |
| 7–8 | Reserved | — | 0 | ignored | — |

## Output mode (8 channels)

| Ch | Parameter | Bits | Default | Mapping | OSC key |
|---|---|---|---|---|---|
| 1–2 | Output intensity | 16 | 65535 | 0 → 0 % · 65535 → 100 % | `intensity` |
| 3 | Control | 8 | 0 | 0–63 Normal · 64–127 Blackout · 128–191 Freeze · rest = Normal | `control` |
| 4 | Test pattern | 8 | 0 | 0–15 Off · 16–31 Grid · 32–47 Colour bars · 48–63 Blend check · 64–79 Output ID · 80–95 Crosshair · 96–111 Grey steps · 112–127 Checkerboard · 128–143 Grey 0 % · 144–159 Grey 25 % · 160–175 Grey 75 % · 176–191 White · rest = Off | `testPattern` |
| 5 | Blend | 8 | 0 | 0–127 On · 128–255 Raw · rest = On | `blend` |
| 6 | Mapping preset | 8 | 0 | 0 = as edited · 1–255 | `preset` |
| 7 | Mapping fade | 8 | 0 | 0 → 0 s · 255 → 25.5 s | `fade` |
| 8 | Reserved | — | 0 | ignored | — |

## Keystone mode (16 channels)

| Ch | Parameter | Bits | Default | Mapping | OSC key |
|---|---|---|---|---|---|
| 1–2 | Top-left X | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `topLeftX` |
| 3–4 | Top-left Y | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `topLeftY` |
| 5–6 | Top-right X | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `topRightX` |
| 7–8 | Top-right Y | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `topRightY` |
| 9–10 | Bottom-right X | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `bottomRightX` |
| 11–12 | Bottom-right Y | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `bottomRightY` |
| 13–14 | Bottom-left X | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `bottomLeftX` |
| 15–16 | Bottom-left Y | 16 | 32768 | 0 → -50 % · 32768 → 0 % · 65535 → 50 % | `bottomLeftY` |

## Effect parameters

Effect 1 and Effect 2 (layer channels 38–43) share these meanings; both slots run in series, slot 1 first.

| Effect | Param A | Param B |
|---|---|---|
| None | — | — |
| Blur | radius 0–5 % of frame height | 0 = round · 1–100 % = motion blur at 0–360° |
| Pixelate | block size 0–10 % of frame height | — |
| Mirror | 0–24 % left→right · 25–49 % right→left · 50–74 % top→bottom · 75–100 % bottom→top | mirror line: 0 = centre … 100 % = edge |
| Kaleidoscope | segments 2–16 | rotation 0–360° |
| Invert | — | — |
| Strobe | rate 1–30 Hz | on time 10–90 % |
| Luma key | key level 0–100 % (darker is transparent) | softness 0–100 % |
| Chroma key | tolerance 0–100 % | key hue 0–360° |
| Edge | gain 1–8× | mix with original 0–100 % |
| Threshold | level 0–100 % | softness 0–100 % |
| Tint | amount 0–100 % | hue 0–360° |
