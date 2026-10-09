# Coût GPU des briques (SDK NVIDIA RTXGI, Bistro, RTX 4060)

## Méthode

- Minuteurs GPU autour de toute la liste de commandes de chaque image, plus un minuteur séparé pour les copies d'instantanés.
- Scénario jour (150 images) → nuit (300) → jour (150). Chaque brique est comparée **à son cache d'origine, image par image**, sur le même scénario.
- Deux résolutions : 960×540 et 1920×1080. Réglages de l'exemple : 4 échantillons par pixel et 8 rebonds maximum. C'est une configuration lourde : les temps absolus sont élevés, ce sont les **écarts relatifs** qui comptent.
- Temps de référence en nuit stable :

| | 960×540 | 1920×1080 |
|---|---|---|
| SHaRC | 23,7 ms | 83,3 ms |
| NRC | 23,7 ms | 89,9 ms |
| Sans cache (path tracing complet) | 41,1 ms | 158,8 ms |

## Surcoût par rapport au cache d'origine, après la tombée de la nuit

| Brique | Images 0-2 | Images 0-9 | Images 0-29 | Moyenne sur 90 images | Total par événement | Hors événement |
|---|---|---|---|---|---|---|
| **SHaRC + vidage** (540p) | +9,8 ms (+38 %) | +6,2 ms (+24 %) | +3,4 ms (+14 %) | +1,1 ms (+4 %) | **+98 ms** | ≈ 0 |
| **SHaRC + vidage** (1080p) | +22 ms (+27 %) | +9,5 ms (+11 %) | +4,0 ms (+5 %) | +1,7 ms (+2 %) | **+157 ms** | ≈ 0 |
| SHaRC + contournement 10 img (1080p) | +55 ms (+67 %) | +56 ms (+66 %) | +19 ms (+23 %) | +6,8 ms (+8 %) | +613 ms | ≈ 0 |
| **NRC + entraînement intensifié** (540p) | +1,6 ms (+7 %) | +1,5 ms (+6 %) | +1,5 ms (+6 %) | +0,6 ms (+2 %) | +50 ms | ≈ 0 |
| **NRC + entraînement intensifié** (1080p) | ≈ 0 | ≈ 0 | ≈ 0 | ≈ 0 | ≈ 0 | ≈ 0 |
| NRC + contournement 90 img (540p) | +15 ms (+64 %) | +18 ms (+74 %) | +17 ms (+69 %) | +16 ms (+65 %) | **+1 458 ms** | ≈ 0 |
| NRC + contournement 90 img (1080p) | +58 ms (+64 %) | +60 ms (+67 %) | +60 ms (+67 %) | +61 ms (+69 %) | **+5 492 ms** | ≈ 0 |

**Copie d'un instantané SHaRC** : environ 4 ms, une seule fois par événement, avec 168 Mo de VRAM par état mémorisé.

## Bilan coût / qualité

| Brique | Qualité (écart après la tombée de la nuit, moyenne sur 30 images) | Coût | Verdict |
|---|---|---|---|
| **SHaRC + vidage** | 25,2 % → **0,8 %** | Surcoût sur quelques images seulement (+11 à +24 % sur 10 images), environ +2 à 4 % sur 90 images | ✅ **Excellent rapport** |
| SHaRC + contournement | 25,2 % → 9,6 % | Plus cher et moins bon que le vidage | ❌ À abandonner |
| **NRC + entraînement intensifié** | 34,3 % → 19,9 % | **Quasi gratuit** | ✅ Gratuit, mais correction partielle |
| NRC + contournement 90 img | 34,3 % → **0,9 %** | **+65 à 69 % pendant 1,5 s** (le coût du path tracing complet) | ⚠️ Correction parfaite, mais **chère** |

## Conclusions

1. **Hors événement, les briques ne coûtent rien** (≤ 0,6 ms, dans le bruit de mesure).
2. **SHaRC + vidage** supprime la lumière fantôme pour un surcoût **concentré sur quelques images**. C'est la solution à retenir pour SHaRC.
3. **Pour NRC**, la correction complète (contournement) coûte cher : environ **70 % de temps en plus pendant 1,5 s**, soit une chute visible de la fréquence d'images. L'entraînement intensifié est gratuit mais ne corrige qu'à moitié.
4. **La priorité pour NRC** est de rendre le contournement moins cher :
   - l'arrêter dès que NRC a rattrapé, avec quelques rayons de contrôle ;
   - ne contourner que là où c'est nécessaire, ou seulement au premier rebond ;
   - combiner un contournement court et un entraînement intensifié.
