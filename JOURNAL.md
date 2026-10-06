# Journal de suivi : codec .rdc

Document vivant, mis à jour à chaque session. Le plan de référence est [PLAN.md](PLAN.md).

**Dernière mise à jour : 6 oct. 2026 (soir)**

## État global

| Phase | Durée prévue | État |
|---|---|---|
| **0. Environnement et dérisquage** | 2 sem. | 🟡 **En cours, environ 60 %** (jour 1) |
| 1. Géométrie CPU | 4 sem. | ⚪ À venir |
| 2. Plugin USD géométrie | 2 sem. | ⚪ À venir (porte « plugin dans Blender » déjà franchie) |
| 3. Volumes CPU | 3 sem. | ⚪ À venir |
| 4. Décodage CUDA | 2 sem. | ⚪ À venir |
| 5. Banc final et rapport | 1 sem. | ⚪ À venir |

Dépôt : <https://github.com/falcon123212/render_engine>. `main` contient le projet ;
`rendu` contient le projet plus le kit de rendu destiné à une autre machine.

---

## ⏳ À approuver (décisions en attente)

| # | Décision | Proposition | Pourquoi | Statut |
|---|---|---|---|---|
| D1 | Critère volumes « ≥ 2× contre NanoVDB Fp8 » | Le remplacer par **≥ 2× contre Fp8 + zstd**, à erreur égale | Un simple zstd sur Fp8 fait déjà 2,1× mieux que Fp8 (nuage Disney) : le critère actuel est trop facile | **À approuver** |
| D2 | Cible taille du tissu violent | Garder **≥ 5×** (arrêt < 3×), et ne pas viser 8× | 0,5 px en 4K = 0,15 mm, avec un résidu de prédiction de 1,7e-3 de la diagonale : environ 5× est réaliste | **À approuver** |
| D3 | Cible des séquences Vlasic | Les classer « capture réelle » avec une cible **≥ 6×**, plutôt que 8× | Bruit de capture : résidu de 1 à 9e-3 de la diagonale, plus élevé que les données de synthèse | **À approuver** |
| D4 | Machine des rendus de comparaison | **La RTX 5070 de l'ami** pour orig, seedB **et** décodé | Original et décodé doivent sortir de la même machine | **À approuver** |
| D5 | Jeux Vlasic rendus | 3 sur 10 (samba, bouncing, march_I) ; les 7 autres en mesure de taille et d'erreur en pixels seulement | Ces séquences sont redondantes entre elles ; ça réduit le temps de rendu | **À approuver** |
| D6 | Draco comme référence | Ne pas le mesurer en v0 | Pas installé, et il n'exploite pas le temps : peu informatif | **À approuver** |
| D7 | Gel des critères | Après réception des rendus et mesure du plancher de bruit ꟻLIP | Le plan prévoit un seul recalage, après les références | En attente des rendus |

Dès qu'une décision est prise : passer son statut à « Approuvé » (ou « Refusé ») et reporter
la décision dans PLAN.md.

---

## 📋 À faire

### Toi

- [ ] Télécharger un **personnage Mixamo** animé (FBX « with skin »), pour le héros et la foule.
- [ ] (Facultatif) Packs Gumroad gratuits : **FX BackPack Discovery Pack** (explosion) et
      **Figment Curtains** (tissu lent).
- [ ] Envoyer à l'ami **`data/render_inputs.zip`** (221 Mo) et le lien du guide
      [`bench/render/README.md`](https://github.com/falcon123212/render_engine/blob/rendu/bench/render/README.md)
      (branche `rendu`). Si le dépôt est privé, l'ajouter comme collaborateur.
- [ ] Trancher les décisions D1 à D6.

### L'ami (RTX 5070)

- [ ] `check_setup.py` → `run_renders.py --quick` → `run_renders.py` → `verify_renders.py` →
      `pack_inputs.py --renders`, puis renvoyer `renders.zip`. Durée : environ 30 min.

### Le PC (le soir)

- [ ] `python bench/datasets/generate.py --character <perso.fbx> --only character crowd smoke`,
      environ 2 à 3 h.

### Développement

- [ ] Dès que le personnage est là : générer le héros et la foule, puis la fumée ; leurs
      caméras figées ; une nouvelle archive pour l'ami.
- [ ] Explosion et tissu lent (packs, ou génération si non fournis).
- [ ] Mesurer les références des nouveaux jeux (`measure_refs.py`).
- [ ] Au retour des rendus : outil ꟻLIP (plancher de bruit orig contre seedB), puis synthèse
      pour le gel des critères (D7).
- [ ] Clôturer la phase 0, puis démarrer la **phase 1** (codec de géométrie, tissu violent en premier).

---

## ✅ Fait

### 6 oct. 2026

**Plan**
- Analyse critique du plan initial, puis **plan v2** adapté à la machine (`PLAN.md`).

**Environnement**
- Machine relevée : RTX 4060 8 Go (PCIe 3.0 x8), Ryzen 5 5500, 16 Go, Blender 5.0.1 (USD 25.08,
  OpenVDB 12), CUDA 13.2, VS 2022.
- Bibliothèques de Blender 5.0.1 récupérées : USD, TBB, Python, environ 620 Mo.
- vcpkg avec une version figée : 83 paquets en 15 min.
- `depcheck` : zstd, meshoptimizer, ZFP, OpenVDB, NanoVDB, Alembic, tous OK.
- `gpucheck` : 6,6 Go/s vers la carte, 39 µs par lancement de noyau, image de personnage
  transférée et convertie en 0,23 ms.

**Plugin USD**
- Plugin `.rdc` minimal compilé contre l'USD de Blender : **10 tests sur 10**. Découverte du
  plugin, `Usd.Stage.Open`, import animé dans Blender et rendu Cycles fonctionnent.
  **Porte de la phase 0 franchie : le repli par add-on Python devient inutile.**

**Jeux de données**
- Vlasic et al. 2008 : 10 séquences (10 k sommets, 150 à 250 images), converties en Alembic.
- Nuage Disney : 1/2, 1/4 et 1/8, normalisés en float32 Blosc.
- **Tissu violent** : 64 k sommets, 120 images. Réglage validé visuellement en pleine
  résolution (vent 24 000, raideur ×0,25). Simulation en environ 9 min.
- Scripts de génération testés en petit : foule et héros (avec un agent de remplacement en
  attendant Mixamo), fumée Mantaflow, aperçus, mesures de mouvement.
- `generate.py` : orchestration du soir, `--quick` pour un essai rapide.

**Banc**
- `measure_refs.py` et `vdbref` : Alembic, Alembic + zstd, usdc ; OpenVDB Blosc, NanoVDB
  float, Fp16, Fp8 et FpN, Fp8 + zstd, ZFP.
- `render_bench.py` : rendus 4K entière avec caméra figée, ombrage lissé et graine fixe.
- `pixel_error.py` : erreur en pixels sans rendu, sur toutes les images, validée par autotest.
- Kit de rendu (branche `rendu`) : `check_setup`, `run_renders`, `verify_renders`,
  `pack_inputs`, caméras figées, guide Windows et Linux, mode headless.

**Corrections notables**
- Tissu en pleine résolution trop raide au premier essai : raideur et vent recalés.
- Convertisseur OBJ vers Alembic : séquences décalées d'une image (première image à 0).
  Corrigé, et Vlasic régénéré.
- Nuage noir au rendu : plans de coupe et densité adaptés à l'échelle de la scène.

---

## 📊 Constats chiffrés

| Mesure | Valeur | Conséquence |
|---|---|---|
| Alembic Ogawa | ~97 bits par sommet et par image | Base de comparaison |
| Alembic + zstd | 82 à 88 bits (gain de 1,1 à 1,2×) | zstd seul ne sert presque à rien sur des flottants |
| Objectif 8× contre Ogawa | ~12 bits par sommet et par image | Exigeant |
| Nuage Disney : Fp8, ZFP, Fp8 + zstd contre Blosc | 1,9×, 2,3×, 4,0× | Critère D1 à revoir |
| Résidu de prédiction linéaire, Vlasic | 1,1 à 9,5e-3 de la diagonale | Capture réelle bruitée (D3) |
| Résidu de prédiction linéaire, tissu violent | 1,7e-3 de la diagonale | Vrai pire cas (D2) |
| Budget 0,5 px en 4K, tissu violent | ~0,15 mm (4e-5 de la diagonale) | Tolérance serrée |
| Rendu 4K entière de géométrie, RTX 4060 | ~21 s | Rendus du banc en 3 à 4 h au total |

## ⚠️ Risques ouverts

| Risque | Statut |
|---|---|
| Plugin incompatible avec l'USD de Blender | ✅ Levé |
| Prédiction faible sur le tissu et les captures | 🟡 Confirmé par les mesures, à traiter en phase 1 (plan B PCA prêt) |
| Pilote ou Blender mis à jour chez l'ami entre orig et décodé | 🟡 Consigne écrite dans le guide (D4) |
| 16 Go de RAM pour la foule et la fumée | ⚪ À surveiller pendant la génération du soir |

## Historique des commits

| Commit | Contenu |
|---|---|
| `0b464ea` | Plan v2 et plugin USD minimal |
| `f6c75ed` | Dépendances vcpkg, depcheck et gpucheck |
| `9ca2605` | Jeux de données : téléchargement, conversion, génération |
| `2d716e7` | Tissu violent : réglage validé à 64 k sommets |
| `7eef34e` | Mesure des références, rendu 4K, erreur en pixels |
| `2f8965f` | Correctif objseq2abc (décalage d'une image) |
| `rendu` | Kit de rendu : guide, Linux, mode headless, vérification |
