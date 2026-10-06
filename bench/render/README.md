# Rendus de comparaison : guide pour la personne qui rend

Merci de prêter ta machine. Ce dossier sert à produire les **images de référence** d'un
banc qui teste un nouveau format de compression de caches 3D. Plus tard, on rendra les
mêmes scènes après compression et décompression, et on comparera les images pixel par
pixel (outil ꟻLIP de NVIDIA). Il n'y a rien à régler à la main : un script fait tout.

## Ce qu'il te faut

- **Windows** avec une **carte NVIDIA RTX** (OptiX). Pilote récent.
- **Blender 5.0.x** exactement (pas 4.x, pas 5.1) : <https://www.blender.org/download/releases/5-0/>.
  Installation par défaut : `C:\Program Files\Blender Foundation\Blender 5.0\`.
- **Python 3.10 ou plus** (seulement la bibliothèque standard, rien à installer avec pip).
- **Git**, et environ **5 Go** libres.
- Une soirée : compter **3 à 4 h** pour tout le banc sur une RTX 4060 (plus rapide sur une
  carte plus récente). Le PC reste utilisable, mais évite les jeux pendant les rendus.

## 1. Récupérer le dépôt et les données

```bash
git clone <URL du dépôt> Render_Engine
```

```bash
cd Render_Engine
```

```bash
git checkout rendu
```

Les scènes ne sont pas dans git (trop lourdes). Nicolas t'envoie **`render_inputs.zip`**.
Décompresse-le **à la racine du dépôt** : il crée le dossier `data/` à côté de ce README
principal (`data/bench/geom/...`, `data/bench/vol/...`).

## 2. Test rapide (2 minutes)

Vérifie que Blender, la carte et les données sont bien reconnus :

```bash
python bench/render/run_renders.py --quick
```

Si Blender n'est pas à l'emplacement par défaut :

```bash
python bench/render/run_renders.py --quick --blender "D:\Blender 5.0\blender.exe"
```

Chaque jeu doit afficher `OK`. Les petites images sont dans `data/renders_quick/` : un
personnage gris, un drapeau, un nuage. En cas d'`ÉCHEC`, le journal indiqué contient
l'erreur : envoie-le à Nicolas.

## 3. Rendus complets (la soirée)

```bash
python bench/render/run_renders.py
```

- Pour chaque jeu disponible : 12 images en **4K entière**, rendues deux fois (« orig » et
  « seedB », avec deux graines aléatoires différentes pour mesurer le bruit naturel de
  Cycles). Le nuage, statique, n'a qu'une image.
- **Tu peux interrompre** (Ctrl+C, ou éteindre le PC) et relancer la même commande : ce
  qui est déjà rendu n'est pas refait.
- Résultats dans `data/renders/<jeu>/<orig|seedB>/NNNN.png`, avec les temps et la carte
  utilisée dans `timings.json`, et un bilan dans `data/renders/report.json`.

## 4. Renvoyer les résultats

```bash
python bench/render/pack_inputs.py --renders
```

Envoie **`data/renders.zip`** à Nicolas (quelques centaines de Mo). L'archive contient
aussi les caméras (`bench/render/cameras/`) : si le script a dû en créer une nouvelle (il
l'affiche avec « ATTENTION »), elle est indispensable pour la suite.

## Règles importantes (pour que la comparaison soit valable)

- **Ne modifie pas** les fichiers de `bench/render/cameras/` ni les réglages des scripts.
- **Garde la même machine, la même version de Blender et le même pilote** jusqu'aux
  rendus « décodés » qui viendront plus tard : l'original et le décodé doivent être
  rendus dans les mêmes conditions. Si tu dois mettre à jour quelque chose, préviens avant.
- Pas de débruitage, pas d'échantillonnage adaptatif : c'est voulu (les scripts s'en
  chargent).

## Plus tard : rendus des versions décodées

Nicolas t'enverra un dossier de jeux décodés avec la même arborescence que `data/`.
La commande sera alors :

```bash
python bench/render/run_renders.py --labels decoded --decoded-root chemin/vers/decoded/data
```

## Détails techniques (pour info)

| Réglage | Valeur |
|---|---|
| Moteur | Cycles, OptiX, 256 échantillons fixes, sans débruitage |
| Résolution | 3840 × 2160 (4K entière) |
| Images | 12 par jeu, réparties sur la séquence (1 pour le nuage) |
| Sortie | PNG 8 bits, vue AgX |
| Caméra | figée par jeu (`bench/render/cameras/<jeu>.json`) |
| Géométrie | gris neutre, ombrage lissé ; volumes : Principled Volume |

Scripts : `run_renders.py` (lanceur), `render_bench.py` (rendu d'un jeu dans Blender),
`pack_inputs.py` (archives à envoyer et à renvoyer).
