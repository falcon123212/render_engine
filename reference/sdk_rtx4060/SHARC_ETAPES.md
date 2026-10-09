# SHaRC, étapes 1 à 4 (SDK NVIDIA RTXGI, Bistro + objet mobile, RTX 4060)

## Ce qui a été construit

| Étape | Réalisation dans le SDK |
|---|---|
| 1. Invalidation ciblée | Masque de dépendances par entrée SHaRC (16 octets) : 96 zones de l'espace (grille 6 × 4 × 4 sur la rue) et 32 lampes, dont le ciel. Il est rempli par la passe de mise à jour : point touché, rayon d'ombre et lampe visible, segments du chemin, propagation aux sommets précédents comme la lumière. À un événement, la passe de résolution remet à zéro les seules entrées qui dépendent de ce qui a changé. Les masques vieillissent : deux banques alternent toutes les 16 images, et une entrée sans masque connu est effacée par prudence. |
| 2. Instantanés compacts | Trois passes de calcul : comptage des entrées valides, recopie de ces seules entrées (24 octets : indice, clé, lumière résolue), puis restauration à leur place exacte dans la table de hachage. |
| 3. Objets mobiles | Un objet dans la scène (`BistroBench2`) : un panneau de 1,4 × 1,8 m déplacé de 2,2 m, ou un auvent de 12 × 10 m qui couvre la rue. Les zones touchées sont celles de sa boîte englobante, avant et après. |
| 4. Caméra mobile | Aller-retour latéral de 1 m avec ±12° de rotation en 2 s. Références pour 20 positions, une mesure toutes les 6 images. |

## Qualité

Mesures en 960×540, 2 répétitions. Écart de luminosité moyen par rapport à la vérité sur les 30 images qui suivent l'événement, mesuré dans la zone touchée.

| Événement | Sans cache (bruit) | SHaRC d'origine | Vidage | Vidage + instantanés compacts | Invalidation ciblée | Cache gardé par le ciblage |
|---|---|---|---|---|---|---|
| Tombée de la nuit, zones au soleil | 0,4 % | **145 %** | 0,5 % | **0,5 %** | 5,0 % ⚠️ | 19 % |
| Tombée de la nuit, image entière | 0,5 % | 20,6 % | 0,5 % | 0,5 % | 0,9 % | |
| Lampadaire 0 éteint (zone) | 1,5 % | **25,7 %** (pic 41 %) | 1,3 % | — | 1,7 % | 24 % |
| Lampadaire 1 éteint (zone) | 0,5 % | 4,7 % | 0,4 % | — | 0,5 % | 26 % |
| Auvent sur la rue (zone) | 0,5 % | 4,0 % (pic 7 %) | 0,6 % | — | 0,5 % | 13 % |
| Petit panneau déplacé (zone) | 0,4 % | 0,4 % | 0,4 % | — | 0,3 % | 10 % |

### Caméra mobile

Mesures sur les 30 images qui suivent l'événement.

| Événement | Sans cache | SHaRC d'origine | Vidage | Invalidation ciblée |
|---|---|---|---|---|
| Auvent (zone) | 1,0 % | 5,8 % | 1,4 % | 1,2 % |
| Lampadaire 1 éteint (zone) | 0,4 % | 4,4 % | 0,4 % | 0,3 % |

## Coût

Coût GPU par rapport à SHaRC d'origine, après la tombée de la nuit.

| Méthode | 3 premières images (540p / 1080p) | Moyenne sur 90 images (540p / 1080p) | Hors événement |
|---|---|---|---|
| Vidage + instantanés complets | +45 % / +29 % | +3 % / +4 % | ≈ 0 |
| **Vidage + instantanés compacts** | +56 % / +30 % | +15 % (dérive d'horloge) / **+2 %** | ≈ 0 |
| Invalidation ciblée + instantanés compacts | +43 % / **+50 %** | +6 % / +5 % | **+1 à +2,5 ms en permanence** |

Lampadaire et auvent donnent le même ordre de grandeur : le vidage coûte +2 à 4 % sur 90 images, l'invalidation ciblée +5 à 7 %, avec un pic plus haut en 1080p.

| Mémoire | Copie complète | Instantané compact |
|---|---|---|
| Par état mémorisé | 167,8 Mo | **7,5 Mo** (540p) / **10,8 Mo** (1080p) |
| Temps de sauvegarde / restauration | ~4 ms | **0,8 ms / 1,0 ms** |
| Masques de dépendances (ciblage) | — | +134 Mo (2 banques × 16 octets × 4,2 M d'entrées) |

Vérification : avec des masques **sans vieillissement**, l'invalidation ciblée revient à 0,5 % à la tombée de la nuit et à 1,4 % pour le lampadaire 0, comme le vidage. Elle n'épargne alors plus que 11 à 21 % du cache. Le résidu venait donc bien de l'oubli des dépendances.

Illustration : `planche_lampe0.jpg` (lampadaire 0 éteint, à +2, +10 et +30 images).

## Ce qu'on apprend

1. **Les instantanés compacts sont un succès net** : 15 à 22 fois moins de mémoire, plus rapides, qualité identique. Ils lèvent la limite principale de la mémorisation des états.
2. **Le vidage, avec restauration d'un instantané pour un état connu, corrige tout** : nuit, lampes, gros objet, caméra mobile. Il revient au niveau du bruit pour +2 à 4 % de temps GPU sur 1,5 s.
3. **L'invalidation ciblée ne paie pas dans cette scène.** Elle n'épargne que 10 à 26 % du cache : dans une petite rue, presque tous les chemins de lumière passent près de n'importe quel changement, et beaucoup d'entrées n'ont pas été rafraîchies récemment. Elle coûte plus cher (marquage permanent et 134 Mo de masques), et ses masques vieillissants laissent un résidu de 5 % à la tombée de la nuit.
4. **Les petits objets qui bougent ne posent pas de problème à SHaRC** : l'éclairage direct est recalculé à chaque image. Le défaut vient des grands changements de lumière ou de géométrie (soleil, lampes, auvent).

## Méthode retenue pour SHaRC

**Vidage du cache sur un état nouveau, restauration d'un instantané compact sur un état déjà vu.**
