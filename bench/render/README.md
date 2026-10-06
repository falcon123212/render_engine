# Rendus de comparaison : guide pour la personne qui rend

Merci de prêter ta machine. Ces rendus servent de **référence** à un banc qui teste un
nouveau format de compression de caches 3D. Plus tard, on rendra les mêmes scènes après
compression et décompression, puis on comparera les images pixel par pixel (outil ꟻLIP
de NVIDIA). Tout est automatisé : il n'y a aucun réglage à faire dans Blender.

**En résumé : 5 commandes (vérifier, tester, rendre, contrôler, empaqueter), environ 30 minutes
au total sur une RTX 5070.**

## Ce qu'il te faut

| Élément | Exigence |
|---|---|
| Système | Windows 10/11 **ou Linux** x86-64 (Ubuntu 22.04+ ou équivalent) |
| Carte | NVIDIA RTX (testé sur RTX 4060, prévu sur **RTX 5070**) |
| Pilote | **570 ou plus** (obligatoire pour les RTX 50xx) ; sous Linux, le pilote propriétaire NVIDIA |
| Blender | **5.0.1 exactement** : <https://download.blender.org/release/Blender5.0/>. Windows : `blender-5.0.1-windows-x64.msi` ; Linux : `blender-5.0.1-linux-x64.tar.xz` |
| Python | 3.10 ou plus, sans paquet supplémentaire. Windows : `python` (ou `py`) ; Linux : `python3` |
| Git | Pour récupérer le dépôt |
| Disque | Environ 5 Go libres |

> **Sous Linux**, remplace `python` par `python3` dans toutes les commandes ci-dessous.
> Les sections « Linux » donnent les rares commandes qui changent.

### Linux uniquement : installer Blender 5.0.1

Pas besoin des droits administrateur. Le script trouve tout seul Blender dans
`~/blender-5.0.1-linux-x64/` :

```bash
cd ~ && wget https://download.blender.org/release/Blender5.0/blender-5.0.1-linux-x64.tar.xz
```

```bash
tar -xf blender-5.0.1-linux-x64.tar.xz
```

```bash
~/blender-5.0.1-linux-x64/blender --version
```

Si Blender est ailleurs, indique son chemin une fois pour toutes dans la session :
`export BLENDER=/chemin/vers/blender`.

## Étape 1 : récupérer le dépôt et les données

```bash
git clone -b rendu https://github.com/falcon123212/render_engine.git Render_Engine
```

```bash
cd Render_Engine
```

Nicolas t'envoie **`render_inputs.zip`**. Copie-le dans `Render_Engine`, puis décompresse-le
sur place.

Windows (PowerShell) :

```powershell
Expand-Archive render_inputs.zip -DestinationPath .
```

Linux :

```bash
unzip render_inputs.zip
```

## Étape 2 : vérifier la machine (1 minute)

```bash
python bench/render/check_setup.py
```

Le script vérifie Python, le pilote, Blender 5.0.x, la détection de la carte par Cycles en
OptiX, les données et les caméras. Il doit finir par **`PRÊT`**.

- Les lignes `[--]` correspondent aux jeux pas encore fournis : c'est normal.
- Une ligne `[KO]` indique ce qu'il faut corriger : pilote, version de Blender, archive mal
  décompressée…

Si Blender est installé ailleurs, ajoute `--blender "D:\...\blender.exe"` (Windows) ou
`--blender /chemin/blender` (Linux) à **toutes** les commandes. Tu peux aussi définir la
variable d'environnement `BLENDER`.

## Étape 3 : test rapide (2 à 3 minutes)

```bash
python bench/render/run_renders.py --quick
```

Chaque ligne doit indiquer `OK`. Regarde ensuite les petites images dans
`data/renders_quick/` :

- `vlasic_*` : une personne grise, entière dans le cadre ;
- `cloth_violent` : un drapeau gris aux plis lisses ;
- `disney_cloud` : un nuage gris doux, et non une image noire.

## Étape 4 : rendus complets (environ 20 à 25 minutes sur une RTX 5070)

```bash
python bench/render/run_renders.py
```

- Ne lance ni jeu ni logiciel lourd sur la carte pendant les rendus.
- Tu peux interrompre (Ctrl+C) ou éteindre le PC, puis relancer **la même commande** : ce
  qui est déjà rendu n'est pas refait.
- À la fin, chaque ligne doit indiquer `OK`. Le bilan est dans `data/renders/report.json`.

## Étape 5 : vérifier les sorties

```bash
python bench/render/verify_renders.py
```

Le script contrôle, pour chaque jeu et chaque passe (`orig`, `seedB`) :

- que toutes les images attendues sont là, avec les bons numéros ;
- qu'elles sont bien en 3840 × 2160 ;
- qu'elles ont été rendues avec Blender 5.0.x, sur la carte et non sur le processeur.

Il doit finir par **`COMPLET : 98 images`**. S'il affiche `INCOMPLET`, relance l'étape 4 :
elle ne refait que ce qui manque. Après le test rapide, la même vérification se fait avec
`--quick`, et elle doit finir par `COMPLET : 18 images`.

## Étape 6 : renvoyer les résultats

```bash
python bench/render/pack_inputs.py --renders
```

Envoie **`data/renders.zip`** à Nicolas (environ 1 Go).

## Ce que tu dois rendre et ce qui doit sortir

### En résumé

| Jeu | Passes | Images par passe | Résolution | Total |
|---|---|---|---|---|
| vlasic_samba | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| vlasic_bouncing | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| vlasic_march_I | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| cloth_violent | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| disney_cloud | orig + seedB | 1 | 3840 × 2160 | 2 PNG |
| **Total** | | | | **98 PNG** |

### Arborescence attendue

Chaque PNG porte le **numéro de l'image dans la séquence**, sur 4 chiffres.

```text
data/renders/
├── report.json                  bilan du lanceur (OK/ÉCHEC et durée par jeu)
├── vlasic_samba/
│   ├── orig/
│   │   ├── 0001.png  0017.png  0033.png  0048.png  0064.png  0080.png
│   │   ├── 0096.png  0112.png  0128.png  0143.png  0159.png  0175.png
│   │   └── timings.json         temps par image, Blender, carte, graine, échantillons
│   ├── seedB/                   mêmes 12 noms de fichiers + timings.json
│   ├── orig.log                 journal Blender (utile en cas d'erreur)
│   └── seedB.log
├── vlasic_bouncing/             mêmes numéros que vlasic_samba
├── vlasic_march_I/
│   └── orig/ et seedB/          0001 0024 0046 0069 0092 0114 0137 0159 0182 0205 0227 0250
├── cloth_violent/
│   └── orig/ et seedB/          0001 0012 0023 0033 0044 0055 0066 0077 0088 0098 0109 0120
└── disney_cloud/
    └── orig/ et seedB/          0001.png uniquement
```

### Contenu attendu des images

| Jeu | À quoi ça doit ressembler |
|---|---|
| vlasic_* | Une personne grise et lisse sur fond gris foncé, entière dans le cadre, dans une pose qui change d'une image à l'autre |
| cloth_violent | Un drapeau gris avec des plis lisses, qui ondule d'une image à l'autre |
| disney_cloud | Un nuage gris doux au centre ; jamais une image entièrement noire |

`orig` et `seedB` doivent paraître **identiques à l'œil nu**. Seul le grain du bruit change,
et c'est voulu.

### Fichier `timings.json` (un par passe)

```json
{
  "frames": [1, 17, 33, "..."],
  "seconds": {"1": 12.4, "17": 12.1},
  "seed": 1,
  "samples": 256,
  "resolution": [3840, 2160],
  "blender": "5.0.1",
  "devices": ["NVIDIA GeForce RTX 5070"]
}
```

`seed` vaut 1 pour `orig` et 1001 pour `seedB`. `devices` doit citer la carte : une liste vide
voudrait dire un rendu sur le processeur, donc invalide.

### Ce que contient `renders.zip`

Tout le dossier `data/renders/` (PNG, `timings.json`, journaux, `report.json`), plus les
caméras `bench/render/cameras/*.json`.

## Réglages des rendus

Tous les rendus complets sont en **4K entière (3840 × 2160)**, avec Cycles OptiX,
**256 échantillons fixes**, sans débruitage, en PNG 8 bits avec la vue AgX. Chaque image est
rendue **deux fois** :

- `orig` avec la graine 1 ;
- `seedB` avec la graine 1001, pour mesurer le bruit naturel de Cycles.

| Jeu | Contenu | Séquence | Images rendues | Rendus |
|---|---|---|---|---|
| vlasic_samba | Humain en robe, 10 k sommets | 175 images | 1, 17, 33, 48, 64, 80, 96, 112, 128, 143, 159, 175 | 24 |
| vlasic_bouncing | Humain qui saute, 10 k sommets | 175 images | 1, 17, 33, 48, 64, 80, 96, 112, 128, 143, 159, 175 | 24 |
| vlasic_march_I | Humain qui marche, 10 k sommets | 250 images | 1, 24, 46, 69, 92, 114, 137, 159, 182, 205, 227, 250 | 24 |
| cloth_violent | Drapeau dans le vent, 64 k sommets | 120 images | 1, 12, 23, 33, 44, 55, 66, 77, 88, 98, 109, 120 | 24 |
| disney_cloud | Nuage statique, 24 M voxels | 1 image | 1 | 2 |
| **Total** | | | **49 images** | **98 rendus** |

Durée : environ 21 s par rendu de géométrie sur RTX 4060 (mesuré), soit environ 35 à
40 minutes en tout. Sur RTX 5070, compter environ 20 à 25 minutes (estimation).

Le test rapide (`--quick`) rend 2 images par jeu (la première et la dernière) en 960 × 540,
avec 64 échantillons.

**Plus tard**, Nicolas pourra t'envoyer de nouveaux jeux : personnage, foule, tissu lent,
fumée, explosion, soit 120 rendus de plus (environ 1 h 30 à 2 h 30). Il suffira de
décompresser la nouvelle archive, de faire `git pull`, puis de relancer l'étape 4 : seuls les
nouveaux jeux seront rendus.

## Règles importantes (pour que la comparaison soit valable)

- **Ne modifie pas** `bench/render/cameras/` ni les scripts.
- **Ne mets à jour ni le pilote ni Blender** avant les rendus « décodés » qui viendront plus
  tard : l'original et le décodé doivent être rendus dans les mêmes conditions. Si une mise à
  jour est inévitable, préviens Nicolas avant.
- Si le script affiche « ATTENTION : pas de caméra figée », il en crée une. Elle est alors
  incluse dans `renders.zip` : renvoie bien cette archive.

## Plus tard : rendus des versions décodées

Nicolas t'enverra les jeux décodés, avec la même arborescence que `data/`. La commande sera :

```bash
python bench/render/run_renders.py --labels decoded --decoded-root chemin/vers/decoded/data
```

Ensuite, vérifie avec `python bench/render/verify_renders.py --labels decoded` et renvoie
les résultats de la même façon (étape 6).

## Linux : points d'attention

- **Lancer les rendus en arrière-plan** (par exemple en SSH), pour qu'ils continuent après
  la déconnexion :

  ```bash
  nohup python3 bench/render/run_renders.py > rendus.log 2>&1 &
  ```

  Suis l'avancement avec `tail -f rendus.log`.
- **Pilote** : `nvidia-smi` doit afficher la carte. Sans le pilote propriétaire NVIDIA
  (avec nouveau), Cycles ne voit pas la carte et `check_setup.py` le signale.
- **Serveur sans écran** : aucun problème, tout se fait en ligne de commande (`blender -b`).
- **WSL2** : non recommandé pour les rendus. Préfère Windows directement ou un vrai Linux.

## Fichiers de ce dossier

| Fichier | Rôle |
|---|---|
| `check_setup.py` | Vérifie la machine avant tout |
| `run_renders.py` | Lanceur : tous les jeux, avec reprise automatique |
| `render_bench.py` | Rendu d'un jeu dans Blender (appelé par le lanceur) |
| `verify_renders.py` | Contrôle des sorties (images, résolution, carte) avant l'envoi |
| `pack_inputs.py` | Archives : données à envoyer, rendus à renvoyer |
| `cameras/*.json` | Caméras figées, une par jeu |
| `pixel_error.py` | Erreur en pixels sans rendu (utilisé par Nicolas, pas pour les rendus) |
