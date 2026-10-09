"""Probes (pixel masks) computed from the reference images of the 8 states (see states.txt).
Sondes (masques de pixels) calculees a partir des references des 8 etats.

Usage: python sondes.py <dossier contenant ref/ref_0.bin ... ref_7.bin>
Writes probes.bin (W, H, then one byte per pixel, one bit per probe) and sondes.txt.

bit 0  whole image / image entiere
bit 1  sunlit areas (day/night ratio > 10) / zones au soleil
bit 2  area dominated by street lamp 0 (> 50 % of its light) / zone dominee par le lampadaire 0
bit 3  area changed by the moving panel (day) / zone touchee par le panneau
bit 4  rest of the image (outside the panel area) / reste de l'image hors panneau
bit 5  area lit by street lamp 1 (> 30 %) / zone eclairee par le lampadaire 1
bit 6  rest of the image (outside lamp 1, < 5 %) / reste de l'image hors lampadaire 1
bit 7  area changed by the canopy (day) / zone touchee par l'auvent
"""
import sys

import numpy as np

D = sys.argv[1]


def load(p):
    with open(p, "rb") as f:
        w, h = np.frombuffer(f.read(8), np.int32)
        return np.frombuffer(f.read(), np.float32).reshape(h, w, 3)


def blur(a, k):
    """Moyenne glissante k x k (image integrale), rapide meme en 4K."""
    r = k // 2
    p = np.pad(a, ((r + 1, r), (r + 1, r)), mode="edge").astype(np.float64)
    s = p.cumsum(0).cumsum(1)
    return (s[k:, k:] - s[:-k, k:] - s[k:, :-k] + s[:-k, :-k]) / (k * k)


refs = [load(f"{D}/ref/ref_{s}.bin").mean(-1) for s in range(8)]
H, W = refs[0].shape
k = max(9, int(round(9 * W / 960)) | 1)   # meme noyau relatif qu'en 960x540
b0, b1, b2, b3, b4, b5, b6, b7 = [blur(r, k) for r in refs]
rel = lambda a, b: np.abs(a - b) / np.maximum(np.maximum(a, b), 1e-6)
part0 = np.clip(b1 - b2, 0, None) / np.maximum(b1, 1e-6)
part1 = np.clip(b1 - b5, 0, None) / np.maximum(b1, 1e-6)
pan = rel(b0, b3) > 0.25
m = np.ones((H, W), np.uint8)
m |= ((b0 / np.maximum(b1, 1e-6) > 10) & (b0 > np.percentile(b0, 50))).astype(np.uint8) << 1
m |= (part0 > 0.5).astype(np.uint8) << 2
m |= pan.astype(np.uint8) << 3
m |= (~pan).astype(np.uint8) << 4
m |= (part1 > 0.3).astype(np.uint8) << 5
m |= (part1 < 0.05).astype(np.uint8) << 6
m |= (rel(b6, b7) > 0.25).astype(np.uint8) << 7
with open(f"{D}/probes.bin", "wb") as f:
    f.write(np.array([W, H], np.int32).tobytes())
    f.write(m.tobytes())
NOMS = ["image entiere", "zones au soleil", "lampadaire 0", "panneau", "hors panneau", "lampadaire 1", "hors lampadaire 1", "auvent"]
txt = "\n".join(f"sonde {b} {n}: {((m >> b) & 1).mean() * 100:.1f} % des pixels" for b, n in enumerate(NOMS))
open(f"{D}/sondes.txt", "w", encoding="utf-8").write(txt + "\n")
print(txt)
