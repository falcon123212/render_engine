# Rendus de comparaison : guide pour la personne qui rend

Merci de prêter ta machine. Ces rendus servent de **référence** à un banc qui teste un
nouveau format de compression de caches 3D. Plus tard, on rendra les mêmes scènes après
compression et décompression, puis on comparera les images pixel par pixel (outil ꟻLIP
de NVIDIA). Tout est automatisé : il n'y a aucun réglage à faire dans Blender.

**En résumé : 4 commandes, environ 30 minutes au total sur une RTX 5070.**

## Ce qu'il te faut

| Élément | Exigence |
|---|---|
| Système | Windows 10 ou 11 |
| Carte | NVIDIA RTX (testé sur RTX 4060, prévu sur **RTX 5070**) |
| Pilote | **570 ou plus** (obligatoire pour les RTX 50xx) |
| Blender | **5.0.1 exactement** : <https://download.blender.org/release/Blender5.0/> (installeur `blender-5.0.1-windows-x64.msi`) |
| Python | 3.10 ou plus, sans paquet supplémentaire. Si `python` n'est pas reconnu, remplace-le par `py` dans les commandes. |
| Git | Pour récupérer le dépôt |
| Disque | Environ 5 Go libres |

## Étape 1 : récupérer le dépôt et les données

```bash
git clone -b rendu https://github.com/falcon123212/render_engine.git Render_Engine
```

```bash
cd Render_Engine
```

Nicolas t'envoie **`render_inputs.zip`**. Copie-le dans `Render_Engine`, puis :

```powershell
Expand-Archive render_inputs.zip -DestinationPath .
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

Si Blender est installé ailleurs, ajoute `--blender "D:\...\blender.exe"` à **toutes** les
commandes.

## Étape 3 : test rapide (2 à 3 minutes)

```bash
python bench/render/run_renders.py --quick
```

Chaque ligne doit indiquer `OK`. Regarde ensuite les petites images dans
`data\renders_quick\` :

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
- À la fin, chaque ligne doit indiquer `OK`. Le bilan est dans `data\renders\report.json`.

## Étape 5 : renvoyer les résultats

```bash
python bench/render/pack_inputs.py --renders
```

Envoie **`data\renders.zip`** à Nicolas (environ 1 Go).

## Ce qui est rendu

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
python bench/render/run_renders.py --labels decoded --decoded-root chemin\vers\decoded\data
```

Ensuite, renvoie les résultats de la même façon (étape 5).

## Fichiers de ce dossier

| Fichier | Rôle |
|---|---|
| `check_setup.py` | Vérifie la machine avant tout |
| `run_renders.py` | Lanceur : tous les jeux, avec reprise automatique |
| `render_bench.py` | Rendu d'un jeu dans Blender (appelé par le lanceur) |
| `pack_inputs.py` | Archives : données à envoyer, rendus à renvoyer |
| `cameras/*.json` | Caméras figées, une par jeu |
| `pixel_error.py` | Erreur en pixels sans rendu (utilisé par Nicolas, pas pour les rendus) |
