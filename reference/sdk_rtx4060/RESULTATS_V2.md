# SDK NVIDIA RTXGI, Bistro : campagne v2 (vérifiée)

## Corrections par rapport à la v1

| Problème trouvé | Conséquence | Correction |
|---|---|---|
| Réglage par défaut de l'exemple `targetLight = 0` : seule la lumière n°0 (le soleil) est échantillonnée | Les lampadaires n'éclairaient pas ; les mesures « lampadaire » de la v1 mesuraient en fait la lumière du jour pas encore oubliée | `targetLight = -1` : toutes les lumières sont échantillonnées. Les lampadaires apportent maintenant 86 % de la lumière de nuit. |
| Erreur par pixel dominée par quelques pixels aberrants (« lucioles ») | Inexploitable | Écart de luminosité moyen par sonde (%) et erreur perceptuelle robuste (RMS de log(1 + x/m)) |
| Une seule exécution | Pas d'incertitude | 3 répétitions par configuration (décalage de chauffe), moyenne ± écart-type |

## Dispositif

- SDK NVIDIA RTXGI 2.0, exemple Pathtracer (DX12), RTX 4060, Bistro avec 2 lampadaires, 960×540, 4 échantillons par pixel, cache mesuré seul (sans débruiteur).
- Références : 2048 échantillons par pixel par état.
- **Scénario A** : jour (150 images) → nuit (300) → jour (150).
- **Scénario B** : nuit déjà convergée (400 images de chauffe) → lampadaire 0 éteint (120) → rallumé (120).
- **Sondes**, calculées à partir des références :

| Sonde | Part de l'image | Part de la lumière venant du lampadaire 0 |
|---|---|---|
| Image entière | 100 % | 41 % |
| Zones au soleil (de jour) | 12,5 % | — |
| Zone dominée par le lampadaire 0 | 34,9 % | 72 % |
| Zone partiellement éclairée par lui | 47,6 % | 30 % |

- **Briques testées** :
  - SHaRC + vidage = instantanés + réaction à l'événement + vidage du cache si l'état est nouveau ;
  - SHaRC + contournement = instantanés + réaction + 10 images sans lecture du cache ;
  - NRC + entraînement intensifié = 4 itérations pendant 30 images ;
  - NRC + contournement = aucune requête NRC pendant 30 ou 90 images, l'entraînement continuant, avec entraînement intensifié.

## 1. Tombée de la nuit (image entière)

Écart de luminosité, en %, par rapport à la vérité (positif = trop clair). Moyenne ± écart-type sur 3 répétitions.

| Méthode | Moyenne sur les 30 images après | +2 img | +10 img | +30 img | +90 img | +290 img | Retour sous 10 % |
|---|---|---|---|---|---|---|---|
| Sans cache (bruit seul) | 0,9 ± 0,1 | +1 | 0 | 0 | 0 | 0 | 0 img |
| SHaRC d'origine | **25,2 ± 0,1** | +36 | +27 | +15 | +2 | 0 | 44 img |
| **SHaRC + vidage** | **0,8 ± 0,1** | +1 | 0 | 0 | −1 | 0 | **0 img** |
| SHaRC + contournement 10 img | 9,6 ± 0,2 | +1 | +19 | +9 | +1 | 0 | 0 img* |
| NRC d'origine | **34,3 ± 1,0** | +40 | +36 | +27 | +11 | +1 | 93 img |
| NRC + entraînement intensifié | 19,9 ± 1,2 | +39 | +22 | +7 | +3 | 0 | 24 img |
| NRC + contournement 30 img | 0,9 ± 0,1 | +1 | 0 | +7 | +3 | 0 | 0 img* |
| **NRC + contournement 90 img** | **0,9 ± 0,1** | +1 | 0 | 0 | 0 | 0 | **0 img** |

\* Juste sous 10 % pendant le contournement. L'écart remonte quand il s'arrête trop tôt (+19 % à +10 images pour SHaRC, +7 % à +30 images pour NRC 30).

### Zones au soleil (le pire cas)

| Méthode | Moyenne sur 30 img | +2 | +10 | +30 | +90 | +290 | Retour sous 10 % |
|---|---|---|---|---|---|---|---|
| SHaRC d'origine | **162 ± 0,1 %** | +223 | +177 | +100 | +15 | 0 | 101 img |
| **SHaRC + vidage** | **0,5 ± 0,1 %** | 0 | −1 | 0 | 0 | −1 | 0 img |
| NRC d'origine | **219 ± 7 %** | +242 | +232 | +179 | +75 | +10 | **300 img (5 s)** |
| NRC + entraînement intensifié | 129 ± 6 % | +236 | +148 | +48 | +24 | +4 | 164 img |
| NRC + contournement 30 img | 0,4 % | 0 | 0 | +49 | +24 | +4 | revient après le contournement |
| **NRC + contournement 90 img** | **0,4 %** | 0 | 0 | 0 | +4 | +1 | 0 img |

## 2. Retour du jour (image entière)

| Méthode | Moyenne sur 30 img | +2 | +10 | +30 |
|---|---|---|---|---|
| SHaRC d'origine | 7,6 % | −10 | −9 | −4 |
| SHaRC + briques (instantané) | **0,7 %** | +1 | 0 | +1 |
| NRC d'origine | 10,7 % | −11 | −12 | −9 |
| **NRC + contournement 90 img** | **0,5 %** | +1 | 0 | 0 |

## 3. Lampadaire éteint (zone dominée par le lampadaire)

| Méthode | Moyenne sur 30 img | +2 | +10 | +30 |
|---|---|---|---|---|
| Sans cache | 0,8 % | 0 | 0 | 0 |
| SHaRC d'origine | 5,7 % | +8 | +6 | +3 |
| SHaRC + vidage | **1,1 %** | 0 | −1 | −1 |
| NRC d'origine | 8,6 % | +10 | +9 | +6 |
| NRC + contournement 30 ou 90 img | **0,8 %** | 0 | 0 | 0 à +1 |

Éteindre ou rallumer un lampadaire est un **petit changement** : les caches de NVIDIA ne dépassent pas 10 % d'écart. Les briques le ramènent au niveau du bruit (1 %).

## Ce que ça établit

1. **La lumière fantôme est réelle et forte** à la tombée de la nuit :
   - SHaRC est trop clair de 25 % en moyenne sur les 30 images qui suivent, et de 162 % dans les zones au soleil ;
   - **NRC fait pire** : 34 % sur l'image entière et 219 % dans les zones au soleil, avec un retour à la normale qui demande **300 images (5 s à 60 i/s)**.
2. **Les briques la suppriment** :
   - SHaRC + vidage, et NRC + contournement de 90 images, ramènent l'écart à **moins de 1 %**, le niveau du simple bruit, sur toutes les sondes et tous les événements ;
   - l'erreur perceptuelle est identique à celle d'un rendu sans cache (0,26).
3. **La durée du contournement compte.** S'il s'arrête avant que le cache soit reconstruit, la lumière fantôme revient. Il faut donc une **fin pilotée par une vérification** plutôt qu'une durée fixe.
4. **Les résultats sont reproductibles** : écart-type ≤ 1 point sur les moyennes (≤ 7 points pour NRC dans les zones au soleil).

## Ce qui n'est pas encore mesuré

- **Le coût** :
  - le contournement de 90 images impose un path tracing complet pendant 1,5 s, donc des images plus lentes ;
  - le vidage et l'entraînement intensifié ont aussi un coût ;
  - aucun horodatage GPU n'a encore été pris.
- **L'image finale avec débruiteur** (NRD) ou DLSS.
- **D'autres scènes et une caméra en mouvement.**
