# Les 3 pistes pour rendre la correction de NRC moins chère (SDK NVIDIA RTXGI, Bistro, RTX 4060)

## Le problème de départ

Contourner NRC pendant 90 images (path tracing complet tant que le cache se reconstruit) supprime la lumière fantôme (34 % → 0,9 %), mais coûte **+62 à +69 % de temps GPU pendant 1,5 s**. Les trois pistes cherchent à faire baisser ce coût.

| Piste | Idée |
|---|---|
| 1. Arrêt piloté | Contournement complet, mais une image sur 6 interroge le cache ; on arrête quand elle rejoint le path tracing complet (image < 3 %, 90 % des tuiles < 6 %). |
| 2. Court + apprentissage accéléré | Contournement de 20 ou 40 images seulement, avec un NRC qui apprend plus vite. |
| 3. Partiel par rebond | NRC reste actif, mais n'est interrogé qu'à partir du 2ᵉ ou du 3ᵉ rebond : les premiers rebonds, ceux qui comptent le plus, sont tracés pour de vrai. |

## Qualité (960×540, 2 répétitions, sondes)

Tombée de la nuit : écart de luminosité par rapport à la vérité.

| Méthode | Image entière, 30 img | Image entière, 90 img | Zones au soleil, 30 img | Zones au soleil, 90 img | Verdict |
|---|---|---|---|---|---|
| NRC d'origine | 34,0 % | 23,0 % | 216 % | 150 % | lumière fantôme |
| Contournement complet 90 img (référence) | 0,9 % | 0,8 % | 0,4 % | 0,5 % | parfait |
| Piste 1 : arrêt piloté | 3,8 % | 2,0 % | 20 % | 9,0 % | ❌ flashs fantômes aux images de contrôle, pas plus court |
| Piste 2 : contournement 20 img | 4,0 % | 3,0 % | 23 % | 19 % | ❌ trop court |
| Piste 2 : contournement 40 img | 0,9 % | 1,5 % | 0,4 % | 7,8 % | ⚠️ la lumière fantôme revient après la fin du contournement |
| Piste 3 : NRC dès le 2ᵉ rebond | 4,8 % | 2,3 % | 28 % | 12 % | ⚠️ résidu visible au soleil |
| **Piste 3 : NRC dès le 3ᵉ rebond** | **1,2 %** | **0,9 %** | **5,6 %** | **2,5 %** | ✅ quasi parfait, décroissance douce |
| Pistes 1 + 3 | 7,0 % | 3,2 % | 42 % | 19 % | ❌ |

Retour du jour : toutes les pistes sauf « contournement 20 img » restent sous 2 % (image entière, 30 img).

## Coût (minuteurs GPU, conditions de la campagne de coût, 1 passe par résolution)

Surcoût par rapport à NRC d'origine pendant les 90 images après la tombée de la nuit, recalé sur l'écart mesuré hors événement (dérive d'horloge GPU entre deux lancements).

| Méthode | 960×540 (base 27,3 ms) | Total par événement | 1920×1080 (base 88,1 ms) | Total par événement |
|---|---|---|---|---|
| Contournement complet 90 img | +16,9 ms (+62 %) | +1,48 s | +60,6 ms (+69 %) | +5,4 s |
| **Piste 3 : NRC dès le 3ᵉ rebond** | +13,6 ms (+50 %) | +1,16 s | +56,5 ms (+64 %) | +5,0 s |
| Piste 3 : NRC dès le 2ᵉ rebond | +9,1 ms (+33 %) | +0,75 s | +35,8 ms (+41 %) | +3,1 s |
| Piste 2 : contournement 40 img | +7,5 ms (+27 %) * | +0,61 s | +27,3 ms (+31 %) * | +2,3 s |
| *Pour mémoire : SHaRC + vidage* | +1,0 ms (+4 %) | +0,10 s | +2,0 ms (+2 %) | +0,23 s |

\* Moyenne sur 90 images : en réalité +55 à +80 % pendant 40 images, puis rien.

## Ce qu'on apprend

1. **La piste 3 au 3ᵉ rebond est la seule qui garde une qualité quasi parfaite.** Mais elle n'économise que 7 à 20 % du coût du contournement complet. Les deux premiers rebonds représentent l'essentiel du travail de path tracing.
2. **La piste 2 (40 img) divise le coût par deux** mais laisse revenir 8 % de lumière fantôme au soleil après coup.
3. **La piste 1 échoue** : chaque image de contrôle réaffiche la lumière fantôme (flash), et l'arrêt ne vient pas plus tôt.
4. **Conclusion** : on sait corriger NRC, mais pas à bas prix depuis l'extérieur de la DLL. Le coût vient de ce qu'on remplace le cache par du vrai path tracing. Pour une correction bon marché, il faut agir *dans* le réseau : sauvegarder ou réinitialiser ses poids par état, ou entraîner en priorité les zones touchées. Cela demande un NRC ouvert (tiny-cuda-nn).

## Verdict sur l'échelle « merdique → révolutionnaire »

| Élément | Position |
|---|---|
| SHaRC + briques (vidage + instantanés) | **Bien** : 25 % → 0,8 % pour +2 à 4 % sur 90 images |
| NRC + briques (piste 3 ou contournement) | **Correct** : ça marche parfaitement, mais +50 à +70 % pendant 1,5 s |
| Cache à dépendances (banc CUDA) | **Bien** : environ 2 fois moins d'erreur que SHaRC publié, équivalent à SHaRC + mémoire dormante |
| **Ensemble** | **Bien : amélioration solide, mesurée et reproductible. Pas révolutionnaire.** |
