# Plan de prototype : codec de données de rendu (.rdc) — v2

6 oct. 2026 · @Nicolas · révision adaptée à la config réelle

## Objectif

Prouver en **16 à 17 semaines** (14 semaines de travail et 2 à 3 semaines de marge pour un plan B, un développeur à plein temps) qu'un format compressé dans le temps :

- **divise par au moins 8** la taille des caches de géométrie animée et **par 5** celle des volumes,
- **sans erreur visible** au rendu (erreur bornée en pixels, ꟻLIP sous le bruit de rendu),
- avec un **décodage GPU** et une **lecture directe dans USD depuis Blender 5.0**.

Si le travail se fait à temps partiel, il faut multiplier les durées en conséquence. L'ordre des phases ne change pas.

## Config de référence (mesurée le 6 oct. 2026)

| Élément | Valeur | Conséquence pour le plan |
|---|---|---|
| GPU | RTX 4060, 8 Go, Ada sm_89, pilote 616.92, OptiX OK dans Cycles | CUDA uniquement, pas de Vulkan. Il faut garder la VRAM sous contrôle au rendu. |
| CPU | Ryzen 5 5500, 6 cœurs / 12 threads | Le 5500 est limité au **PCIe 3.0**, donc la 4060 tourne en **PCIe 3.0 x8**, environ 6 à 7 Go/s réels. Envoyer des données compressées au GPU devient un argument mesurable. |
| RAM | 16 Go | **C'est la vraie limite.** On écarte ALab complet, on prend le nuage Disney en résolution réduite, on compile en `-j6` et on ne rend jamais pendant une compilation. |
| Disque | NVMe 1 To, 126 Go libres sur C: | Budget du banc **≤ 60 Go** (voir plus bas). Séquences de 120 images. |
| Outils | VS 2022, CMake 4.2, CUDA 13.2, Git, Python 3.14 | Le banc tourne dans un venv Python 3.12 (uv), parce que certaines roues ne sont pas encore publiées pour 3.14. |
| Blender | **5.0.1**, USD **25.08**, OpenVDB **12.0**, Python 3.11, `usd_ms.dll` partagée dans `blender.shared/` | Le plugin cible exactement USD 25.08 en build monolithique. Les tests USD passent par le `pxr` livré avec Blender, donc sans usdview. |

## Périmètre

- **Dans v0** : maillages déformés à topologie fixe (personnage, foule, tissu) ; grilles de densité, température et vitesse (fumée, explosion) ; décodeur CPU de référence ; décodage CUDA (zstd sur CPU, reconstruction sur GPU) ; plugin USD `SdfFileFormat` pour la géométrie ; banc reproductible ; rapport.
- **Repoussé en v1** : nvCOMP, scene index Hydra, compensation des volumes par advection, rANS, volumes lus nativement dans USD, usdview, ALab, Vulkan, topologie changeante, export depuis un DCC.
- **Plan B seulement** (pris sur la marge, si une porte échoue) : base PCA par cluster pour la géométrie, ZFP par brique pour les volumes.

## Le format

### Conteneur

- Un en-tête, puis un **bloc partagé** (topologie, UV et attributs constants, **stocké une seule fois par fichier**), puis l'index des segments (image de début, offset, taille), puis les segments.
- Un segment fait **16 images par défaut**. On teste 8, 16 et 32 au banc pour arbitrer entre taux de compression et coût d'accès aléatoire.
- Chaque flux (positions, normales, densité, température, vitesse) est compressé séparément, pour ne lire que ce dont le rendu a besoin.
- Codage entropique : zstd sur des entiers en **zigzag**, avec **séparation par plans d'octets** (le shuffle de Blosc). Le coût est quasi nul et le gain est important sur des petits résidus.

### Géométrie

- **Grille de quantification globale, fixe pour tout le fichier**, avec le même pas et la même origine pour tous les sommets. Le pas vient de l'erreur cible en unités scène, et l'erreur est bornée à pas/2. On évite ainsi les fissures entre clusters et les sauts aux images clés.
- L'erreur cible est calculée par le banc à partir de la caméra de référence : 0,5 pixel en 4K à la distance minimale caméra-objet sur le plan. L'encodeur ne connaît que `--max-error <unités scène>`.
- **Prédiction en boucle fermée** : on extrapole linéairement les deux images précédentes *décodées* (en entiers) et on stocke le résidu entier, sans perte. Il n'y a donc pas de dérive. Les images clés stockent les positions quantifiées en delta spatial.
- Les sommets sont réordonnés avec meshoptimizer (`optimizeVertexFetch`) pour améliorer la localité et donc le zstd. **Pas de clusters en v0** : ils ne servent qu'au plan B PCA.
- Normales : on mesure le recalcul au décodage contre l'octaédrique 16 bits.
- Vitesse pour le flou de mouvement : **différence centrée sur les positions décodées**, en unités par seconde, avec des différences avant et arrière aux extrémités.
- Bornes (`extent`) recalculées par image au décodage, parce qu'USD en a besoin.

### Volumes

- Briques de 8³ voxels **alignées sur les feuilles VDB et NanoVDB**.
- Masque des briques actives codé par image, en delta par rapport à l'image précédente.
- Quantification **à erreur bornée** par canal : le nombre de bits découle de l'erreur cible, comme pour la géométrie. On n'impose pas un nombre de bits fixe.
- Prédiction en boucle fermée depuis la brique décodée de l'image précédente. Une brique inchangée sous le seuil n'est pas stockée.

## Lecture : USD, Blender et GPU

### Plugin USD (géométrie)

- On suit le modèle de `usdAbc` : `SdfFileFormat` et un `SdfAbstractData` personnalisé, des time samples décodés à la demande, un cache LRU de segments et un accès thread-safe.
- **Compilation contre l'USD exact de Blender** : en-têtes et `usd_ms.lib` tirés des bibliothèques précompilées de Blender, dépôt `projects.blender.org/blender/lib-windows_x64`, tag `v5.0.1` (existence vérifiée le 6 oct.). C'est **obligatoire et non optionnel** : l'USD de Blender utilise l'espace de noms `pxrBlender_v25_08__pxrReserved__`, donc un OpenUSD 25.08 compilé à part ne se lierait pas.
- Le plugin est chargé via `PXR_PLUGINPATH_NAME` : Blender 5.0.1 respecte bien cette variable (vérifié le 6 oct. avec un plugin de ressource). Attention, `plugInfo.json` doit être en UTF-8 **sans BOM**, sinon USD le rejette.
- Utilisation : un `shot.usda` de quelques lignes référence les `.rdc`, puis on fait Fichier › Importer › USD dans Blender. L'import de Blender ne filtre que les extensions `.usd*`, d'où ce fichier d'entrée.
- Validation automatisée : `Usd.Stage.Open` dans le Python de Blender, avec des points identiques bit à bit à ceux du décodeur CPU.

### Volumes dans Blender

USD ne transporte pas de voxels : un `OpenVDBAsset` pointe vers un fichier, et Blender l'ouvre directement avec OpenVDB. En v0, **`rdc decode --to-vdb`** écrit donc des `.vdb` temporaires, que Blender charge comme séquence de volumes. Le critère d'intégration USD ne porte que sur la géométrie. La voie native (Cycles utilise NanoVDB en interne) est une piste v1.

### Décodage GPU (CUDA, sm_89)

- On décompresse avec zstd sur CPU en multi-thread (par flux et par paquets de briques), puis on transfère depuis de la mémoire épinglée, en asynchrone. Sur GPU, on déquantifie et on reconstruit la prédiction en **arithmétique entière**, et on ne convertit en float qu'à la fin. La validation bit à bit contre le CPU est donc possible.
- Le zstd de l'image n+1 se recouvre avec le noyau de l'image n (streams CUDA).
- Les temps sont toujours mesurés **de bout en bout** (disque ou cache vers VRAM), pas seulement le noyau.

## Banc

### Jeux de données

Tous les jeux sont générés par des scripts Blender versionnés dans `bench/`, ce qui rend le banc reproductible. Les bakes et les rendus tournent la nuit.

| Jeu | Contenu | Taille visée | Rôle |
|---|---|---|---|
| Personnage | Rig libre CC-BY (rigs gratuits du Blender Studio), subdivision appliquée, 120 images | ~100 k sommets | Cas héros |
| Foule | 200 agents issus du personnage sans subdivision, décalages d'animation | ~10 k sommets par agent, 2 M au total | Débit. Limité pour tenir dans 8 Go de VRAM au rendu. |
| Tissu lent | Drapé sur un obstacle, 120 images | 50 à 80 k sommets | Cas non rigide courant |
| Tissu violent | Drapeau dans un vent fort, ou chute avec chocs, 120 images | 50 à 80 k sommets | **Pire cas de la prédiction, mesuré en premier** |
| Fumée | Mantaflow, résolution 256, densité, température et vitesse, 120 images | ~256³ | Volumes |
| Explosion | Mantaflow feu et fumée, résolution 192 à 256, 96 images | ~256³ | Volumes rapides |
| Nuage Disney | Version **1/4** (1/2 si la RAM suit) | Statique | Compression spatiale seule, **hors cibles temporelles** |

Les caches Mantaflow sont exportés en OpenVDB **pleine précision (float32), Blosc**. Le réglage par défaut Half fausserait la référence.

### Références comparées

- **Géométrie**
  - **Base naïve** : même code, avec la même grille, mais sans prédiction. C'est elle qui isole le gain temporel.
  - Alembic Ogawa, Alembic + zstd et `.usdc` avec time samples, ces deux derniers exportés par Blender.
  - Draco image par image, en option.
- **Volumes**
  - OpenVDB + Blosc.
  - NanoVDB Fp8, Fp16 et FpN (`nanovdb_convert`).
  - **ZFP en précision fixe**, à erreur maximale égale.

### Métriques

- **Courbes débit-distorsion** : 4 à 5 niveaux d'erreur par jeu, avec des métriques analytiques peu coûteuses (erreur maximale par sommet, erreur projetée en pixels pour la caméra 4K de référence, et PSNR plus erreur maximale pour les volumes).
- **ꟻLIP** seulement au point de fonctionnement retenu, sur **12 images par jeu en 4K entière**, pour 10 jeux : 3 séquences Vlasic (samba, bouncing, march), les 2 tissus, le héros, la foule, la fumée, l'explosion, plus 1 image du nuage statique. On tone-mappe en AgX, puis on applique ꟻLIP LDR. L'erreur en pixels, elle, est calculée sans rendu sur **toutes** les images (`bench/render/pixel_error.py`).
  - **Plancher de bruit** : on compare l'original rendu avec la graine A à l'original rendu avec la graine B.
  - **Mesure du codec** : on compare l'original au décodé, tous deux rendus avec la graine A, sans débruiteur et avec beaucoup d'échantillons.
- **Stabilité temporelle** : on mesure la variation de l'erreur maximale d'une image à l'autre, en vérifiant spécialement les frontières de segment. On revoit aussi les cartes ꟻLIP en flipbook à 24 images/s.
- **Vitesse** : décodage de bout en bout par image sur CPU et sur GPU, accès à une image quelconque, temps avant la première image, et pic de RAM du plugin.

### Budgets machine

| Poste | Estimation |
|---|---|
| Disque : géométrie et références | ~10 Go (la foule en représente l'essentiel) |
| Disque : volumes et références | ~40 Go (fumée et explosion) |
| Disque : nuage, rendus PNG 4K, décodés temporaires | ~10 Go |
| **Total disque** | **≤ 60 Go** sur 126 Go libres |
| Rendus ꟻLIP | 109 images × 3 rendus ≈ 330 rendus en 4K entière : géométrie ~21 s par rendu (mesuré), volumes 1 à 2 min (estimé), soit **3 à 4 h** |
| Bakes | Mantaflow 256 et les deux tissus : **1 à 2 nuits** |

## Critères de réussite

Les critères sont évalués **par jeu de données, dans le pire cas**. Ils sont recalés une seule fois, à la fin de la phase 0, après la mesure des références, puis gelés.

| Critère | Jeux | Cible | Seuil d'arrêt |
|---|---|---|---|
| Taille contre Alembic Ogawa | Personnage, foule, tissu lent | ≥ 8× | < 4× |
| Taille contre Alembic Ogawa | Tissu violent | ≥ 5× | < 3× |
| Taille contre la base naïve (gain temporel) | Toute la géométrie | ≥ 2,5× | < 1,5× |
| Taille contre OpenVDB + Blosc | Fumée, explosion | ≥ 5× | < 3× |
| Taille contre NanoVDB Fp8, à erreur maximale égale | Fumée, explosion | ≥ 2× | < 1,3× |
| Taille contre ZFP, à erreur maximale égale | Fumée, explosion | ≥ 1,3× | < 1× (on passe alors au plan B ZFP) |
| Erreur géométrique projetée en 4K | Toute la géométrie | ≤ 0,5 px | > 1 px |
| ꟻLIP original contre décodé | Tous | Moyenne ≤ plancher de bruit, aucune image > 0,05 | Moyenne > 0,03 |
| Scintillement | Tous | Aucun saut aux frontières de segment, rien de visible en flipbook | Visible en revue |
| Décodage de bout en bout | Personnage (100 k sommets) | ≤ 1 ms | > 5 ms |
| Décodage de bout en bout | Foule (2 M sommets) | ≤ 10 ms | > 41 ms (moins de 24 i/s) |
| Décodage de bout en bout | Volume ~256³ | ≤ 10 ms | > 41 ms |
| Accès à une image quelconque | Tous | ≤ le décodage d'un segment | Plus d'un segment |
| Pic de RAM du plugin | Foule | ≤ 2 Go | > 4 Go |
| Intégration USD | Géométrie | `shot.usda` s'importe dans Blender 5.0.1 avec le seul plugin, joue l'animation et se rend en Cycles | Il faut modifier Blender |

## Phases

Chaque phase se ferme sur une porte mesurée. Une porte non franchie déclenche le plan B pris sur la marge, pas l'arrêt.

| # | Phase | Durée | Contenu | Porte |
|---|---|---|---|---|
| 0 | Environnement et dérisquage | 2 sem. | Projet CMake et manifeste vcpkg (zstd, meshoptimizer, alembic, openvdb+nanovdb, zfp, draco), avec `VCPKG_MAX_CONCURRENCY=6`. **Jours 1 à 3 : plugin USD « hello » chargé dans Blender 5.0.1.** Test CUDA 13.2 sm_89 et mesure du débit hôte vers GPU. Scripts de génération et bakes de nuit. Mesure des références. Rendus des originaux et des planchers de bruit. | Plugin chargé dans Blender. Références mesurées. Critères gelés. |
| 1 | Géométrie CPU | 4 sem. | Conteneur v0, grille globale, prédiction en boucle fermée, zigzag, shuffle, zstd, base naïve, normales, vitesses. Banc Python avec courbes débit-distorsion. Ordre : **tissu violent**, puis personnage, tissu lent et foule. | Critères de taille et de précision pour la géométrie. Échec : plan B PCA par cluster (+2 à 3 sem.). |
| 2 | Plugin USD géométrie | 2 sem. | `SdfFileFormat` et `SdfAbstractData`, cache LRU, thread-safety, `extent`, `velocities`. `shot.usda`. Rendus Cycles des décodés, puis ꟻLIP. Validation bit à bit via le `pxr` de Blender. | Intégration USD, ꟻLIP, scintillement et RAM pour la géométrie. |
| 3 | Volumes CPU | 3 sem. | Lecture OpenVDB, briques 8³, masque actif, quantification à erreur bornée, prédiction temporelle, `--to-vdb`. Références NanoVDB et ZFP. Rendus et ꟻLIP. | Critères pour les volumes. Échec : plan B ZFP par brique avec résidu temporel. |
| 4 | Décodage CUDA | 2 sem. | Mémoire épinglée, streams, noyaux entiers, recouvrement zstd et GPU, validation bit à bit, mesures de bout en bout. | Critères de vitesse. |
| 5 | Banc final et rapport | 1 sem. | Banc relancé en une commande, rapport chiffré (tableaux, courbes, cartes ꟻLIP, config). | — |
| | **Total** | **14 sem. et 2 à 3 sem. de marge** | | |

**Repli si le plugin ne se charge pas dans Blender** (porte de la phase 0) : on écrit un add-on Python qui appelle le décodeur natif via `ctypes` et met à jour le maillage dans `frame_change_pre`. Le critère d'intégration devient alors « se rend en Cycles avec le seul add-on ».

## Pile technique

- C++20, CMake, vcpkg, VS 2022 ; CUDA 13.2 (sm_89).
- zstd, meshoptimizer, Alembic, OpenVDB 12 et NanoVDB, ZFP, Draco (en option).
- USD 25.08 monolithique, aligné sur Blender 5.0.1, pour le plugin seulement. L'encodeur et le décodeur ne dépendent pas d'USD.
- Banc en Python 3.12 (venv uv) : numpy, matplotlib, OpenEXR, ꟻLIP. Les scènes sont générées par le Python de Blender (3.11).
- Rendus Cycles OptiX en ligne de commande (`blender -b`), lancés la nuit.

## Organisation du dépôt

```
Render_Engine/
  PLAN.md  CMakeLists.txt  vcpkg.json
  src/core/        conteneur, quantification, prédiction, entropie
  src/geom/        encodeur et décodeur de géométrie
  src/vol/         encodeur et décodeur de volumes
  src/cuda/        noyaux de décodage
  src/usd_plugin/  SdfFileFormat .rdc
  tools/rdc/       CLI : encode, decode, --to-vdb, stats
  bench/           scripts Blender de génération, run_bench.py, rapport
  data/            (ignoré par git) jeux, références, rendus
```

## Risques

| Risque | Effet | Parade |
|---|---|---|
| Plugin incompatible avec l'USD de Blender | Intégration ratée | Test dès les jours 1 à 3 ; bibliothèques précompilées de Blender ; repli par add-on avec `ctypes` |
| Prédiction faible sur le tissu violent | Gain sous 5× | Mesuré en premier ; plan B PCA par cluster |
| ZFP meilleur que notre codage spatial sur les volumes | Gain sous la cible | ZFP par brique, combiné au résidu temporel |
| RAM de 16 Go saturée (compilation, bakes, rendu) | Plantages, swap | `-j6`, jamais deux tâches lourdes en même temps, nuage en 1/4, foule à 2 M sommets |
| Bruit de rendu qui masque ou fausse ꟻLIP | Critère inexploitable | Plancher de bruit, graine fixe, sans débruiteur |
| Disque saturé | Banc bloqué | Budget ≤ 60 Go, décodés temporaires supprimés après mesure |
| Mouvement de Blender (montée en 5.x avec un autre USD) | Plugin à recompiler | On fige Blender 5.0.1 pour toute la durée du prototype |

## Avancement

- **6 oct. 2026 — porte « plugin dans Blender » franchie.** Le plugin minimal `rdcUsd` (`src/usd_plugin/`) est compilé contre les bibliothèques de Blender 5.0.1. Les 10 tests de `tests/usd/run_blender_tests.ps1` passent :
  - découverte du plugin ;
  - `Usd.Stage.Open` avec 48 time samples exacts ;
  - import de `shot.usda` dans Blender, avec un `MeshSequenceCache` animé ;
  - rendu Cycles OptiX.

  Le repli par add-on Python devient inutile.
- **6 oct. 2026 — dépendances et GPU validés.**
  - vcpkg (version figée, triplet release, 6 jobs) installe 83 paquets en 15 min. `depcheck` passe pour zstd 1.5.7, meshoptimizer, ZFP 1.0.1, OpenVDB 12.0.1, NanoVDB 32.7 et Alembic 1.8.12.
  - `gpucheck` :
    - débit hôte vers GPU de **6,6 Go/s** avec de la mémoire épinglée, ce qui confirme le PCIe 3.0 x8 ;
    - **39 µs** par lancement de noyau avec synchronisation (pilote WDDM), donc il faut grouper les noyaux par image ;
    - 1,2 Mo non compressé envoyé et déquantifié en **0,23 ms**. Le critère « ≤ 1 ms » pour le personnage a donc de la marge, avant même la compression.

- **6 oct. 2026 — premières références mesurées** (`bench/refs/measure_refs.py`, résultats dans `data/results/refs/`).
  - Géométrie : Alembic Ogawa ≈ 97 bits par sommet et par image ; zstd n'apporte que 1,1 à 1,2× (82 à 88 bits) ; `.usdc` ≈ 96 bits. Viser 8× contre Ogawa revient donc à environ 12 bits par sommet et par image.
  - Nuage Disney 1/4, à erreur maximale égale à celle de Fp8 : NanoVDB Fp8 fait 1,9× mieux qu'OpenVDB Blosc, ZFP par feuille 2,3×, et **Fp8 + zstd 4,0×**. Le critère « ≥ 2× contre Fp8 » est donc trop facile : un simple zstd sur Fp8 le franchit déjà. Il faudra le recaler contre Fp8 + zstd au gel des critères.
  - Rendu : image 4K entière de géométrie en 21 s, zone 960 × 540 en 2 s (4060, 256 échantillons). On retient la 4K entière avec 12 images par jeu. L'ombrage lissé supprime les facettes du tissu violent, qu'on garde donc tel quel.
  - Erreur en pixels, sur le tissu violent avec la caméra du banc : 0,5 px en 4K correspond à environ 0,15 mm, soit 4e-5 de la diagonale. Le budget est serré par rapport au résidu de prédiction (1,7e-3) : le tissu violent restera plutôt vers 5× que 8×, ce qui reste cohérent avec sa cible du plan.

## Choix par défaut

- NVIDIA et CUDA uniquement. Vulkan ne sera envisagé qu'en v1, si le multi-constructeur compte.
- Lecture seule : l'encodeur est un outil en ligne de commande qui convertit Alembic et VDB.
- La licence sera décidée après le banc.
