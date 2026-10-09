# Image finale avec DLSS Ray Reconstruction (SDK NVIDIA RTXGI, Bistro, RTX 4060)

## Méthode

- Réglage d'un vrai jeu : 1 échantillon par pixel, rendu interne en 960×540, DLSS Ray Reconstruction en mode Performance, sortie en 1920×1080.
- L'image de sortie est comparée à une référence 1080p (path tracing, 8 échantillons par pixel × 192 images).
- Sondes recalculées en 1080p. 2 répétitions.
- Ajouts au banc (`patch_bench13.py`) :
  - `dlss perf|balanced|quality|dlaa` et `denoiser dlssrr` ;
  - `dlssreset 1`, qui efface l'historique du DLSS à l'événement ;
  - relecture de l'image de sortie du DLSS.

## Résultats

Écart de luminosité dans la zone touchée, en moyenne sur les 30 images qui suivent l'événement.

| Événement | Sans cache + DLSS | SHaRC d'origine + DLSS | Tes briques + DLSS | + historique DLSS effacé |
|---|---|---|---|---|
| Tombée de la nuit · zones au soleil | 4,6 % | **172 %** | 4,6 % | **1,6 %** |
| Lampadaire éteint · sa zone | 3,4 % | **29 %** | **3,6 %** | 3,3 % |
| Auvent posé · sa zone | 0,8 % | 6,8 % | **1,0 %** | 1,7 % |
| Retour du lampadaire | 10,6 % | 13,3 % | 10,3 % | **0,7 %** |
| Retrait de l'auvent | 14,3 % | 13,7 % | 12,6 % | **7,8 %** |
| Retour du jour · zones au soleil | 3,1 % | 13,2 % | **2,4 %** | 2,5 % |

Le DLSS a un biais constant d'environ −1 à −3 % par rapport à la référence, déjà présent avant l'événement.

## Ce qu'on apprend

1. **Le DLSS ne masque pas la lumière fantôme de SHaRC** : 29 % et 172 % dans l'image finale.
2. **Avec les briques (vidage + instantanés compacts), l'image finale revient au niveau du DLSS sans cache.**
3. **Le DLSS a son propre retard quand la lumière revient** : 10 à 14 % trop sombre, même sans cache. Effacer son historique à l'événement le corrige en grande partie (0,7 % pour le lampadaire, 7,8 % pour l'auvent).
4. **Mais juste après un effacement, le DLSS rend l'image 2 à 3 points trop sombre pendant une à deux secondes.**
   - Règle : effacer l'historique du DLSS quand la lumière augmente, pas quand elle baisse.
   - Exception mesurée : à la tombée de la nuit, l'effacement aide quand même (4,6 % → 1,6 %).

## Incidents

Deux exécutions sur 26 ont bloqué le GPU (processus figé). Elles ont été tuées et relancées. Une capture d'images avec effacement de l'historique DLSS n'a pas pu être obtenue.

Illustration : `planche_dlss.jpg`.
