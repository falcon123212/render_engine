# Lancer le bench sous Linux / Running the bench on Linux

> **Français d'abord, English below each step.** Durée totale : environ 1 h, dont 20 à 40 min de mesures.

Sous Linux, on lance le **bench CUDA** (dossier `cuda/`). Il compare le « cache à dépendances » à des caches de type SHaRC et à de l'accumulation classique, sur trois scènes et 7 à 8 scénarios d'événements (lampes éteintes ou rallumées, porte, mur qui s'effondre, objets déplacés).

*On Linux you run the **CUDA bench** (`cuda/` folder). It compares the dependency cache with SHaRC-like caches and plain accumulation on three scenes and 7–8 event scenarios.*

Le bench SHaRC / NRC officiel de NVIDIA (dossier `windows/`) ne tourne **pas** sous Linux : NVIDIA ne fournit NRC qu'en DLL Windows. Tu peux ignorer ce dossier.
*The official NVIDIA SHaRC / NRC bench (`windows/`) does **not** run on Linux: NRC ships as Windows DLLs only. Ignore that folder.*

> **Tu as déjà fait le bench une première fois ?** Va directement à la section [« Mise à jour du 9 octobre 2026 »](#mise-à-jour-du-9-octobre-2026--update-2026-10-09) en bas : il y a deux choses nouvelles à lancer (~10 min en tout).
> *Already ran the bench once? Jump to the "Update 2026-10-09" section at the bottom: two new things to run (~10 min total).*

---

## Étape 0 · Ce qu'il faut / Requirements

| Élément / Item | Version | Vérifier avec / Check with |
|---|---|---|
| GPU NVIDIA | RTX (RTX 5080 16 Go : OK) | `nvidia-smi` |
| Pilote NVIDIA / driver | **≥ 570**. Sur RTX 50, avec les **modules noyau « open »** (obligatoire pour Blackwell) | `nvidia-smi` (ligne « Driver Version ») |
| CUDA Toolkit | **≥ 12.8** (nécessaire pour les RTX 50) | `nvcc --version` |
| Compilateur C++ | gcc supporté par ta version de CUDA (gcc 11 à 13 en général) | `gcc --version` |
| Git, Python 3 | quelconques | `git --version`, `python3 --version` |
| Optionnel : Nsight Systems | pour le profil avec traces NVTX | `nsys --version` |
| Optionnel : compute-sanitizer | livré avec CUDA | `compute-sanitizer --version` |

Aucune bibliothèque Python n'est nécessaire, la bibliothèque standard suffit. Environ 200 Mo de disque.
*No Python packages needed. ~200 MB disk.*

---

## Étape 1 · Installer les prérequis (Ubuntu 22.04 / 24.04) / Install prerequisites

Si `nvidia-smi` et `nvcc --version` répondent déjà avec les bonnes versions, passe à l'étape 2.
*If `nvidia-smi` and `nvcc --version` already show the right versions, skip to step 2.*

```bash
sudo apt update
```

```bash
sudo apt install -y build-essential git python3
```

**CUDA Toolkit** (dépôt officiel NVIDIA, exemple pour Ubuntu 24.04) :

```bash
wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
```

```bash
sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt update
```

```bash
sudo apt install -y cuda-toolkit
```

Pour Ubuntu 22.04, remplace `ubuntu2404` par `ubuntu2204`. Autres distributions : https://developer.nvidia.com/cuda-downloads

**Mettre CUDA dans le PATH** (à ajouter aussi dans `~/.bashrc`) :

```bash
export PATH=/usr/local/cuda/bin:$PATH
```

**Pilote** : si `nvidia-smi` échoue ou affiche une version inférieure à 570, installe le pilote « open ». Exemple : `sudo apt install nvidia-driver-570-open`, puis redémarre.
*Driver: if `nvidia-smi` fails or shows < 570, install the open driver (e.g. `nvidia-driver-570-open`) and reboot.*

---

## Étape 2 · Vérifier / Check

```bash
nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv
```

**Attendu / expected** : le nom de ta carte (par exemple « NVIDIA GeForce RTX 5080 »), un pilote ≥ 570 et `compute_cap` 12.0.

```bash
nvcc --version
```

**Attendu / expected** : la dernière ligne indique `release 12.8` ou plus (13.x convient aussi).

---

## Étape 3 · Récupérer le bench / Get the bench

```bash
git clone https://github.com/falcon123212/render_engine.git
```

```bash
cd render_engine
```

---

## Étape 4 · Compiler / Build (~1 min)

```bash
./cuda/build.sh
```

**Attendu / expected** : `OK : poc_gpu_l3 et poc_gpu_l8`.

En cas d'erreur `Unsupported gpu architecture`, mets CUDA à jour, ou force l'architecture de la RTX 50 :
*If you get `Unsupported gpu architecture`, update CUDA or force the RTX 50 architecture:*

```bash
CUDA_ARCH=sm_120 ./cuda/build.sh
```

---

## Étape 5 · Test rapide / Quick test (~1 min)

```bash
./cuda/run_cuda.sh --test
```

**Attendu / expected** : une ligne par mesure, puis `fini / done : ../results/cuda_test/RESULTATS_CUDA.md`. Ces chiffres ne sont **pas** significatifs, le test n'utilise qu'une graine.
*Not meaningful numbers (1 seed): this only checks that everything runs.*

---

## Étape 6 · Traces de débogage / Debug traces (~5 min)

```bash
./cuda/run_cuda.sh --debug
```

Ce mode active trois niveaux de traces :

1. **`BENCH_DEBUG=1`** : chaque lancement de noyau CUDA est vérifié tout de suite (`cudaGetLastError` + `cudaDeviceSynchronize`). Une erreur GPU est donc attribuée au bon noyau. Le programme trace aussi le GPU détecté (architecture, nombre de SM, mémoire, versions du pilote et du runtime CUDA), chaque méthode, chaque événement, et un bilan final. Les fichiers vont dans `results/cuda_debug/trace_*.log`.
   **Attendu** : chaque fichier finit par `bilan : N lancements de noyaux verifies, aucune erreur`.
2. **NVTX**, la bibliothèque de traces de NVIDIA livrée avec CUDA : des plages nommées (mode, méthode, événement) apparaissent dans **Nsight Systems**. Si `nsys` est installé, le script produit `results/cuda_debug/profil.nsys-rep`, qu'on ouvre avec l'interface de Nsight Systems, plus des résumés CSV.
3. **compute-sanitizer**, s'il est installé : vérification des accès mémoire des noyaux sur une petite scène, dans `results/cuda_debug/sanitizer.log`. **Attendu** : `ERROR SUMMARY: 0 errors`.

*Debug mode: (1) `BENCH_DEBUG=1` checks every kernel launch synchronously, so a GPU error is attributed to the right kernel, and logs GPU info, methods, events and a final summary ("aucune erreur" = no error). (2) NVTX ranges show up in Nsight Systems (`profil.nsys-rep` if `nsys` is installed). (3) compute-sanitizer memcheck, if installed: expect `ERROR SUMMARY: 0 errors`.*

Pour tracer à la main n'importe quelle commande (`BENCH_DEBUG=2` trace chaque appel de noyau, c'est très verbeux) :
*Manual use (`BENCH_DEBUG=2` logs every kernel call, very verbose):*

```bash
BENCH_DEBUG=1 ./cuda/poc_gpu_l3 timing cuda/scenes/scene_scale_43k.bin > /dev/null
```

Le mode débogage synchronise le GPU après chaque noyau : **ses temps ne sont pas valables**. Les mesures se font à l'étape 7, sans ce mode.
*Debug mode synchronizes after every kernel: timings are not valid. Measure in step 7 without it.*

---

## Étape 7 · Le bench complet / Full bench (~20-40 min)

```bash
./cuda/run_cuda.sh
```

- **Ne pas utiliser la machine** pendant les mesures, et ne rien faire tourner d'autre sur le GPU.
- **Si c'est interrompu**, relance la même commande : ce qui est déjà fait est sauté.
- **Attendu** : `fini / done : ../results/cuda/RESULTATS_CUDA.md`. Ce fichier contient les tableaux (qualité par scénario, gain G, temps GPU, ressources).
- Le bench complet inclut maintenant les grandes scènes de **530 k et 1 M points** (taille réelle d'un cache dans un moteur). Elles sont stockées compressées (`.bin.gz`) et décompressées automatiquement (~210 Mo sur le disque).

*Don't use the machine or the GPU meanwhile. If interrupted, rerun the same command (finished parts are skipped). Expected: `results/cuda/RESULTATS_CUDA.md`.*

---

## Étape 8 · Renvoyer les résultats / Send the results back

```bash
./cuda/run_cuda.sh --pack
```

**Attendu / expected** : `archive : .../resultats_cuda_<machine>_<date>.tar.gz`. **Envoie ce fichier**, il pèse quelques dizaines de Ko. Il contient les mesures, les traces et la description de la machine.
*Send this file (tens of KB): measurements, traces and system info.*

---

## Problèmes fréquents / Troubleshooting

| Symptôme / Symptom | Solution |
|---|---|
| `nvcc: command not found` | `export PATH=/usr/local/cuda/bin:$PATH` |
| `Unsupported gpu architecture 'compute_120'` | CUDA trop ancien : installer CUDA ≥ 12.8 |
| `unsupported GNU version` à la compilation | gcc trop récent pour ce CUDA : `sudo apt install gcc-12 g++-12`, puis `export NVCC_CCBIN=g++-12` et relancer `./cuda/build.sh` |
| `CUDA driver version is insufficient` | Pilote trop ancien : installer un pilote ≥ 570 (open), puis redémarrer |
| `no CUDA-capable device` | Pilote absent ou carte non vue : vérifier `nvidia-smi` |
| `Permission denied` sur un `.sh` | `chmod +x cuda/*.sh` |
| Une erreur GPU pendant le bench | Lancer `./cuda/run_cuda.sh --debug` : les traces indiquent le noyau fautif. Envoyer l'archive de l'étape 8. |

## Ce que mesure le bench / What is measured

- **Qualité** : erreur moyenne sur les 30 images qui suivent le dernier événement de chaque scénario (plus bas = mieux), sur 10 graines.
- **Gain G** : erreur de la baseline divisée par celle de la méthode, à temps GPU égal, en moyenne géométrique sur les scénarios. Deux définitions sont données :
  - **config fixe** : la meilleure baseline unique, avec un seul réglage pour tous les scénarios (comme un moteur, qui choisit un réglage et le garde) ;
  - **par scénario** : la meilleure baseline choisie séparément pour chaque scénario. C'est plus sévère, comme un adversaire qui saurait d'avance quel événement arrive.
  - Verdict : G ≥ 2 rupture ; 1,15 à 2 gain net ; 0,87 à 1,15 équivalent ; moins de 0,87 régression.
- **Comparaison** : les résultats de référence d'une RTX 4060 sont dans `reference/cuda_rtx4060/RESULTATS_CUDA.md`.
  - G ≈ 2,2 à 2,5 (config fixe) ou 1,8 à 2,1 (par scénario) contre les baselines telles que publiées ;
  - G ≈ 1,2 à 1,3 (config fixe) ou 1,1 (par scénario) contre des baselines qui reprennent la mémoire et les instantanés.
  - Temps à 1 M points sur RTX 4060 : 1,10 ms par image pour le classique, 1,45 ms pour la v4 (+0,34 ms).

---

## Mise à jour du 9 octobre 2026 / Update 2026-10-09

Deux nouveautés. Commence par récupérer la dernière version du dépôt :
*Two new things. First, get the latest version of the repo:*

```bash
cd render_engine
```

```bash
git pull
```

### A. Temps et ressources à 530 k et 1 M points (~1 à 5 min)

Le premier passage n'a mesuré le temps qu'à 43 k et 170 k points. À ces tailles, la carte n'est pas pleinement occupée, et les temps ne disent pas grand-chose du coût réel. Cette commande ne lance **que** les nouvelles mesures, sans refaire le reste :
*The first run only timed 43 k and 170 k points, too small to load the GPU. This runs **only** the new measurements:*

```bash
./cuda/run_cuda.sh --echelle
```

**Attendu / expected** : `decompression` de deux scènes, puis `timing_530k.jsonl`, `timing_1M.jsonl`, `res_1M.jsonl` et `fini / done`. Sur une RTX 4060, ça prend moins d'une minute.

Puis renvoie les résultats comme d'habitude (étape 8) :
*Then send the results back as usual (step 8):*

```bash
./cuda/run_cuda.sh --pack
```

### B. Télécharger les scènes publiques de NVIDIA (~100 Mo, 1 à 2 min ; Bistro : +2,3 Go)

La prochaine version du bench testera la méthode sur des scènes **publiques** que tout le monde connaît, et plus seulement sur nos scènes en boîtes. Ce sont les scènes du dépôt officiel de NVIDIA [RTXGI-Assets](https://github.com/NVIDIAGameWorks/RTXGI-Assets), celles que NVIDIA utilise pour ses démos SHaRC et RTXGI. Elles sont au format glTF, sans Git LFS ni compte à créer.
*The next bench version will test on well-known **public** scenes from NVIDIA's official RTXGI-Assets repo (glTF, no Git LFS, no account).*

| Scène | Taille | Intérêt |
|---|---|---|
| CornellBox | 12 Ko | Valider le convertisseur |
| Bathroom | 6 Mo | Petit intérieur |
| LivingRoom | 43 Mo | Intérieur meublé |
| Sponza | 52 Mo | La référence classique |
| Bistro | 2,3 Go | La scène de NVIDIA pour SHaRC, la même que le banc Windows |

**Les petites scènes** (sans Bistro) :

```bash
./scenes_publiques/telecharger.sh
```

**Avec Bistro**, quand la connexion le permet (le script reprend ce qui est déjà téléchargé) :

```bash
./scenes_publiques/telecharger.sh --bistro
```

**Attendu / expected** : une ligne `OK` par scène, avec sa taille et le chemin de son fichier `.gltf`, puis `fini / done`. Les scènes vont dans `scenes_publiques/RTXGI-Assets/`, qui n'est pas versionné. En cas de coupure, relance la même commande.
*One `OK` line per scene, then `fini / done`. If interrupted, rerun the same command.*

**Important :** le bench ne sait **pas encore** lire ces scènes. Le convertisseur glTF et le traceur adapté aux grandes scènes arrivent dans une prochaine mise à jour. Ce téléchargement sert seulement à les avoir prêtes. Il n'y a rien à mesurer ni à renvoyer pour cette partie.
*The bench **cannot read these scenes yet**: the glTF converter and large-scene tracer come in a later update. This only gets them ready; nothing to measure or send back for this part.*

Licences : chaque scène vient directement de NVIDIA et garde sa licence (Bistro : CC-BY 4.0, Amazon Lumberyard ; Sponza : voir `Sponza/README.md`). Ce dépôt ne les redistribue pas.
*Licences: scenes come straight from NVIDIA with their own licences; this repo does not redistribute them.*
