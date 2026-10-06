# Rendus de comparaison : guide pour la personne qui rend

Merci de prêter ta machine. Ces rendus servent de **référence** à un banc qui teste un
nouveau format de compression de caches 3D. Plus tard, on rendra les mêmes scènes après
compression et décompression, puis on comparera les images pixel par pixel (outil ꟻLIP
de NVIDIA). Tout est automatisé : il n'y a aucun réglage à faire dans Blender.

**En résumé : 5 commandes (vérifier, tester, rendre, contrôler, empaqueter), environ 45 minutes
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

## Étape 4 : rendus complets (environ 40 minutes sur une RTX 5070)

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

Il doit finir par **`COMPLET : 122 images`**. S'il affiche `INCOMPLET`, relance l'étape 4 :
elle ne refait que ce qui manque. Après le test rapide, la même vérification se fait avec
`--quick`, et elle doit finir par `COMPLET : 22 images`.

## Étape 6 : renvoyer les résultats

```bash
python bench/render/pack_inputs.py --renders
```

Envoie **`data/renders.zip`** à Nicolas (environ 1,5 Go).

## Ce que tu dois rendre et ce qui doit sortir

### En résumé

| Jeu | Passes | Images par passe | Résolution | Total |
|---|---|---|---|---|
| vlasic_samba | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| vlasic_bouncing | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| vlasic_march_I | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| cloth_violent | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| smoke | orig + seedB | 12 | 3840 × 2160 | 24 PNG |
| disney_cloud | orig + seedB | 1 | 3840 × 2160 | 2 PNG |
| **Total** | | | | **122 PNG** |

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
├── smoke/
│   └── orig/ et seedB/          mêmes numéros que cloth_violent (120 images)
└── disney_cloud/
    └── orig/ et seedB/          0001.png uniquement
```

### Contenu attendu des images

| Jeu | À quoi ça doit ressembler |
|---|---|
| vlasic_* | Une personne grise et lisse sur fond gris foncé, entière dans le cadre, dans une pose qui change d'une image à l'autre |
| cloth_violent | Un drapeau gris avec des plis lisses, qui ondule d'une image à l'autre |
| smoke | Un panache de fumée gris clair qui monte et grossit d'une image à l'autre (très fin à l'image 1) |
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
| smoke | Fumée Mantaflow 256, jusqu'à 6 M voxels | 120 images | 1, 12, 23, 33, 44, 55, 66, 77, 88, 98, 109, 120 | 24 |
| disney_cloud | Nuage statique, 24 M voxels | 1 image | 1 | 2 |
| **Total** | | | **61 images** | **122 rendus** |

Durée : environ 21 s par rendu de géométrie et environ 1 min 20 s par rendu de fumée sur
RTX 4060 (estimation pour la fumée), soit environ 1 h 10 en tout. Sur RTX 5070, compter
environ 40 minutes (estimation).

Le test rapide (`--quick`) rend 2 images par jeu (la première et la dernière) en 960 × 540,
avec 64 échantillons.

**Plus tard**, Nicolas pourra t'envoyer de nouveaux jeux : personnage, foule, tissu lent,
explosion, soit 96 rendus de plus. Il suffira de
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

## Mode headless (sans interface)

**Tout est déjà headless.** Le lanceur démarre Blender en arrière-plan (`blender -b`) :
aucune fenêtre ne s'ouvre, aucun écran n'est nécessaire, et l'interface de Blender n'est
jamais utilisée. Ça marche donc aussi sur un serveur sans écran, en SSH ou en bureau à
distance.

### Lancer en arrière-plan et pouvoir se déconnecter

Linux, avec `nohup` (les rendus continuent après la déconnexion SSH) :

```bash
nohup python3 bench/render/run_renders.py > rendus.log 2>&1 &
```

```bash
tail -f rendus.log
```

Linux, avec `tmux` (on peut revenir voir la session plus tard avec `tmux attach -t rendus`) :

```bash
tmux new -s rendus "python3 bench/render/run_renders.py; bash"
```

Windows (PowerShell) : lancement dans une fenêtre réduite, avec un journal :

```powershell
Start-Process -WindowStyle Minimized python -ArgumentList "bench/render/run_renders.py" -RedirectStandardOutput rendus.log -RedirectStandardError rendus_err.log
```

```powershell
Get-Content rendus.log -Wait
```

### Suivre l'avancement

- Le journal du lanceur affiche `[jeu/passe] ... OK en X min` pour chaque passe.
- Le détail par image, rendu par Blender (`image 17 : 12.3 s`), se trouve dans
  `data/renders/<jeu>/<passe>.log`.
- La charge de la carte s'affiche, rafraîchie toutes les 2 secondes, avec :

```bash
nvidia-smi -l 2
```

- Pour savoir où en est le travail, à tout moment et même pendant les rendus :

```bash
python bench/render/verify_renders.py
```

### Arrêter proprement

Ctrl+C dans le terminal, ou tuer le processus Python **et** Blender (`pkill -f run_renders`
puis `pkill blender` sous Linux, ou le Gestionnaire des tâches sous Windows). L'image en
cours est perdue, mais les autres restent : relancer la même commande reprend là où ça
s'est arrêté.

### Commande Blender brute (pour un seul jeu, sans le lanceur)

C'est la commande exacte qu'exécute `run_renders.py`, utile pour déboguer un jeu. Exemple
pour la passe `orig` du drapeau.

Windows :

```powershell
& "C:\Program Files\Blender Foundation\Blender 5.0\blender.exe" -b --factory-startup --python-exit-code 1 --python bench/render/render_bench.py -- --abc data/bench/geom/cloth_violent.abc --camera bench/render/cameras/cloth_violent.json --label orig --out data/renders/cloth_violent --count 12
```

Linux :

```bash
~/blender-5.0.1-linux-x64/blender -b --factory-startup --python-exit-code 1 --python bench/render/render_bench.py -- --abc data/bench/geom/cloth_violent.abc --camera bench/render/cameras/cloth_violent.json --label orig --out data/renders/cloth_violent --count 12
```

| Option (après `--`) | Rôle |
|---|---|
| `--abc FICHIER` ou `--vdb DOSSIER` | Géométrie Alembic, ou séquence de volumes VDB |
| `--camera FICHIER` | Caméra figée du jeu (ne pas modifier) |
| `--label orig\|seedB\|decoded` | Passe : `seedB` change la graine (1001 au lieu de 1) |
| `--out DOSSIER` | Les images vont dans `DOSSIER/<label>/NNNN.png` |
| `--count 12` | Nombre d'images réparties sur la séquence |
| `--at 1 60 120` | Ou bien : numéros d'images précis |
| `--res 3840 2160` / `--samples 256` | Valeurs par défaut : ne pas changer pour le banc |

Options de Blender utilisées :

| Option | Rôle |
|---|---|
| `-b` | Headless : pas d'interface |
| `--factory-startup` | Ignore les préférences et add-ons personnels (rendus reproductibles) |
| `--python-exit-code 1` | Code de sortie 1 si le script échoue (détecté par le lanceur) |

### Plusieurs cartes graphiques

Par défaut, Cycles utilise toutes les cartes OptiX. Pour n'en utiliser qu'une, par exemple
la première :

```bash
CUDA_VISIBLE_DEVICES=0 python3 bench/render/run_renders.py
```

Sous Windows : `$env:CUDA_VISIBLE_DEVICES="0"` avant la commande. `timings.json` indique
quelle carte a servi. Les rendus décodés devront être faits sur la **même** carte.

## Linux : points d'attention

- **Pilote** : `nvidia-smi` doit afficher la carte. Sans le pilote propriétaire NVIDIA
  (avec nouveau), Cycles ne voit pas la carte et `check_setup.py` le signale.
- **Serveur sans écran** : aucun problème (voir « Mode headless »).
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
