# Bench : lumière fantôme des caches de radiance (SHaRC, NRC, DLSS)

> **Tu es sous Linux ? Suis directement [LINUX.md](LINUX.md)** (étapes détaillées, traces de débogage NVIDIA NVTX).
> **On Linux? Go straight to [LINUX.md](LINUX.md).** English summary at the end.

Ce dépôt mesure un défaut des caches de lumière de NVIDIA (**SHaRC** et **NRC**, SDK RTXGI 2.0) : quand l'éclairage change (nuit qui tombe, lampe éteinte, gros objet déplacé), le cache garde l'ancienne lumière pendant plusieurs secondes. Il compare ces caches avec et sans des « briques » correctrices (vidage du cache, instantanés compacts par état, contournement), jusqu'à l'image finale avec DLSS.

Il contient deux bancs :

| Banc | Système | Ce qu'il mesure | Durée sur RTX 5080 |
|---|---|---|---|
| **A. SDK NVIDIA** (`windows/`) | **Windows 10/11 uniquement** | SHaRC, NRC et DLSS Ray Reconstruction officiels, dans la scène Bistro | test : ~10 min ; rapide : ~2 h ; complet : ~6 à 8 h |
| **B. CUDA** (`cuda/`) | **Windows et Linux** | Le prototype « cache à dépendances » contre des baselines de type SHaRC et accumulation | ~20 à 40 min |

Le banc A ne tourne que sous Windows, parce que NVIDIA ne fournit NRC qu'en DLL Windows et que l'exemple du SDK exige Visual Studio. Sous Linux, seul le banc B est possible.

---

## Banc A : SDK NVIDIA (Windows)

### Prérequis

| Élément | Version |
|---|---|
| GPU | NVIDIA RTX (testé : RTX 4060 8 Go ; cible : **RTX 5080 16 Go**) |
| Pilote NVIDIA | Récent ; **≥ 572** pour les RTX 50 |
| Windows | 10 ou 11, 64 bits |
| Visual Studio 2022 | Ou « Build Tools 2022 », avec la charge **« Développement Desktop en C++ »** et un **Windows 10/11 SDK** (≥ 10.0.20348) |
| CMake | ≥ 3.24 |
| Git for Windows | Fournit **Git Bash**, dans lequel on lance toutes les commandes |
| Git LFS | `git lfs install` une fois |
| Vulkan SDK | ≥ 1.3.268 (demandé par le SDK RTXGI) |
| Python | ≥ 3.10, avec `pip install numpy` |
| Disque | ~30 Go libres (SDK, compilation, références 4K) |

### Étapes

Toutes les commandes se tapent dans **Git Bash**, depuis la racine de ce dépôt.

**1. Installer le banc** : clone du SDK au commit figé, patch, scène, compilation. Compte 20 à 40 minutes.

```bash
./windows/setup.sh C:/bench/RTXGI
```

Le dossier du SDK **ne doit pas contenir d'espace**, sinon la compilation des shaders échoue.

**2. Vérification rapide** (~10 min). Elle doit finir par « 4/4 executions ok ».

```bash
./windows/run.sh --test
```

**3. Le banc**, au choix :

```bash
./windows/run.sh
```

```bash
./windows/run.sh --rapide
```

`--rapide` fait 1 répétition au lieu de 2 et saute la 4K. On peut aussi lancer une seule suite : `./windows/run.sh sharc` (ou `nrc`, `cout`, `dlss`).

**4. Renvoyer les résultats** : le script crée `resultats_<GPU>_<date>.zip` à la racine.

```bash
./windows/pack.sh
```

### Pendant les mesures

- **Ne pas utiliser le PC** et ne pas réduire la fenêtre de rendu qui s'ouvre et se ferme à chaque essai. Les temps GPU en dépendent.
- Désactiver la mise en veille et brancher sur secteur.
- Le banc **reprend où il s'était arrêté** si on le relance : les essais complets sont sautés.
- Si le GPU se fige pendant un essai (vu 2 fois sur 26 sur RTX 4060), le script le tue après un délai, puis réessaie une fois. Tout est noté dans `results/sdk/journal.txt`.

### Ce qui est mesuré

| Suite | Résolution | Contenu |
|---|---|---|
| `sharc` | 960×540, 4 échantillons/pixel | 5 événements : nuit, lampadaire 0 ou 1 éteint, auvent de 12 × 10 m, petit panneau. Méthodes : sans cache, SHaRC d'origine, SHaRC + vidage + instantanés (complets puis compacts), SHaRC + invalidation ciblée |
| `nrc` | 960×540 | Nuit, lampadaire, auvent : NRC d'origine, apprentissage accéléré, contournement 90 images, contournement partiel (rebond 3), contournement 40 images |
| `cout` | 1080p et 4K | Temps GPU par image (minuteurs GPU) des méthodes retenues, comparé à SHaRC et NRC d'origine |
| `dlss` | Sortie 1080p et 4K, DLSS Ray Reconstruction Performance, 1 échantillon/pixel | L'image finale que voit le joueur, avec et sans les briques, avec et sans effacement de l'historique DLSS |

**Mesure de qualité** : écart de luminosité (en %) entre l'image et la vérité (path tracing 8 échantillons × 256 images), dans la zone touchée par l'événement. On le moyenne sur les 10, 30 et 90 images qui suivent l'événement, et sur les 30 images qui suivent le retour à l'état initial. « Sans cache » donne le niveau du simple bruit.

### Résultats de référence (RTX 4060)

Ils sont dans `reference/sdk_rtx4060/`. Par exemple, sur l'image finale avec DLSS, 30 images après l'événement :

| Événement | SHaRC d'origine | SHaRC + briques |
|---|---|---|
| Lampadaire éteint | 29 % | 3,6 % |
| Nuit qui tombe (zones au soleil) | 172 % | 1,6 % (avec effacement de l'historique DLSS) |

---

## Banc B : CUDA (Linux et Windows)

**Sous Linux, le mode d'emploi détaillé étape par étape est dans [LINUX.md](LINUX.md).**

### Prérequis

- **CUDA Toolkit ≥ 12.8** (obligatoire pour les RTX 50 / Blackwell).
- Sous Linux : un compilateur C++ supporté par cette version de CUDA (gcc).
- Sous Windows : Visual Studio 2022 C++ et Git Bash.
- Python ≥ 3.8 (bibliothèque standard seulement).

### Étapes

**1. Compilation**, au choix :

```bash
./cuda/build.sh
```

Sous Windows, dans une invite de commandes classique : `cuda\build_windows.bat`.

**2. Vérification rapide** (une graine), traces de débogage (`--debug` : vérification de chaque noyau CUDA, plages NVTX pour Nsight Systems, compute-sanitizer), puis le banc complet :

```bash
./cuda/run_cuda.sh --test
```

```bash
./cuda/run_cuda.sh --debug
```

```bash
./cuda/run_cuda.sh
```

**3. Renvoyer les résultats** : `./cuda/run_cuda.sh --pack` crée une archive `.tar.gz` à envoyer.

**Déjà lancé une fois ?** `git pull`, puis `./cuda/run_cuda.sh --echelle` : seulement les nouvelles mesures de temps et de ressources à 530 k et 1 M points. Détails dans [LINUX.md](LINUX.md#mise-à-jour-du-9-octobre-2026--update-2026-10-09).

**Scènes publiques** (Sponza, Bistro… du dépôt officiel NVIDIA RTXGI-Assets) : `./scenes_publiques/telecharger.sh` (ajouter `--bistro` pour Bistro, +2,3 Go). Le bench ne les lit pas encore : c'est la préparation d'une prochaine version.

### Ce qui est mesuré

Trois scènes : la principale, une scène de validation jamais vue pendant la mise au point, et une scène « stress » à 8 lampes avec un mur mobile. Chacune passe par 7 à 8 scénarios d'événements, avec 10 graines.

- **Qualité** : erreur 30 images après le dernier événement.
- **Gain G** : rapport de l'erreur de la meilleure baseline sur celle de la méthode, à temps GPU égal.
- **Temps GPU** de chaque étape, et ressources (VRAM, CPU).

Référence RTX 4060 : `reference/cuda_rtx4060/RESULTATS_CUDA.md`. Elle donne **G ≈ 2,2 à 2,5 contre les baselines telles que publiées** (1,8 à 2,1 si on prend la meilleure baseline scénario par scénario), mais **≈ 1,2 à 1,3 contre des baselines qui reprennent la mémoire et les instantanés** (≈ 1,1 scénario par scénario). Le rapport donne les deux définitions de G.

---

## Dépannage

| Problème | Solution |
|---|---|
| `setup.sh` : « fxc.exe introuvable » | Installer un Windows 10/11 SDK via Visual Studio Installer |
| Erreurs ShaderMake ou chemins | Mettre le SDK dans un dossier sans espace, par exemple `C:/bench/RTXGI` |
| Visual Studio 2026 au lieu de 2022 | `CMAKE_GENERATOR="Visual Studio 18 2026" ./windows/setup.sh` (non testé) |
| Les essais NRC échouent sur RTX 50 | La bibliothèque NRC fournie (v0.14.1) ne gère peut-être pas encore Blackwell. Les suites SHaRC et DLSS restent valables, c'est noté dans le journal. |
| Un essai reste bloqué | Le script le tue après 30 min (90 min en 4K) et réessaie. On peut aussi relancer `run.sh`, qui reprend où il en était. |
| `nvcc fatal: Unsupported gpu architecture` | Mettre CUDA à jour (≥ 12.8), ou forcer l'architecture : `CUDA_ARCH=sm_120 ./cuda/build.sh` |

---

## English summary

This repo benchmarks "ghost lighting" in NVIDIA's radiance caches (SHaRC and NRC, RTXGI 2.0 SDK): after a lighting change, the cache keeps stale light for seconds. It compares the original caches with corrective "bricks": event-driven cache clear, compact per-state snapshots, and cache bypass. The comparison goes all the way to the final DLSS Ray Reconstruction image.

- **Bench A (Windows only, NVIDIA SDK)**: NRC ships as Windows DLLs only.
  - Run from **Git Bash**: `./windows/setup.sh C:/bench/RTXGI`, then `./windows/run.sh --test` (~10 min).
  - Then `./windows/run.sh` (full, ~6–8 h on an RTX 5080) or `./windows/run.sh --rapide` (~2 h).
  - Finally `./windows/pack.sh`, and send back the resulting zip.
  - Prerequisites: VS 2022 with C++ and the Windows SDK, CMake ≥ 3.24, Git for Windows + Git LFS, Vulkan SDK, Python + numpy, a recent NVIDIA driver (≥ 572 for RTX 50), ~30 GB free disk. Do not use the PC or minimise the render window during the runs.
- **Bench B (Linux and Windows, CUDA)**: see **[LINUX.md](LINUX.md)**. `./cuda/build.sh` (CUDA ≥ 12.8), `./cuda/run_cuda.sh --test`, `--debug` (NVTX / kernel-checked traces), then `./cuda/run_cuda.sh` and `./cuda/run_cuda.sh --pack`.
  - Already ran it? `git pull`, then `./cuda/run_cuda.sh --echelle` (new 530 k / 1 M point timing only) and `--pack`.
  - Public scenes (Sponza, Bistro… from NVIDIA's RTXGI-Assets): `./scenes_publiques/telecharger.sh [--bistro]`. Not read by the bench yet.
- Reference results for an RTX 4060 are in `reference/`.

## Licences

Voir [NOTICE.md](NOTICE.md). Le SDK NVIDIA et la scène Bistro **ne sont pas redistribués** : `setup.sh` les télécharge depuis les dépôts officiels de NVIDIA. Ce dépôt ne contient que nos modifications (un patch) et nos scripts.
