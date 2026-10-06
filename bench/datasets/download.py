"""Télécharge et extrait les jeux de données publics du banc.

  python bench/datasets/download.py [--only vlasic|disney] [--data data]

- Vlasic et al. 2008 (MIT), « Articulated Mesh Animation from Multi-view
  Silhouettes » : 10 séquences, maillages OBJ à topologie fixe (~10 k sommets).
  Seuls meshes.tgz et template.tgz sont récupérés (438 Mo). Pas de licence
  publiée : usage recherche uniquement, citer l'article.
- Walt Disney Animation Studios, Clouds (CC-BY-SA 3.0) : wdas_cloud.zip
  (2,97 Go). On n'extrait que les résolutions 1/2, 1/4 et 1/8 puis l'archive
  est supprimée (--keep-archives pour la garder).

Idempotent : un fichier déjà présent à la bonne taille n'est pas retéléchargé.
"""
import argparse
import shutil
import sys
import tarfile
import time
import urllib.request
import zipfile
from pathlib import Path

VLASIC_BASE = "http://groups.csail.mit.edu/graphics/mesh_animation"
VLASIC_SEQUENCES = ["I_crane", "D_bouncing", "T_swing", "I_jumping", "D_handstand",
                    "T_samba", "I_march", "D_march", "I_squat", "D_squat"]
DISNEY_URL = "https://assets.disneyanimation.com/wdas_cloud.zip"
DISNEY_KEEP = ("_half.vdb", "_quarter.vdb", "_eighth.vdb")


def remote_size(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return int(r.headers.get("Content-Length", -1))


def download(url, dest: Path):
    size = remote_size(url)
    if dest.exists() and dest.stat().st_size == size:
        print(f"  déjà présent : {dest.name}")
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    t0, done, last = time.time(), 0, 0.0
    with urllib.request.urlopen(url, timeout=120) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
            done += len(chunk)
            if time.time() - last > 15:
                last = time.time()
                print(f"  {dest.name} : {done / 1e6:,.0f} / {size / 1e6:,.0f} Mo "
                      f"({done / 1e6 / (last - t0 + 1e-9):.1f} Mo/s)", flush=True)
    if size > 0 and tmp.stat().st_size != size:
        raise RuntimeError(f"taille inattendue pour {url}")
    tmp.replace(dest)
    print(f"  téléchargé : {dest.name} ({size / 1e6:,.0f} Mo en {time.time() - t0:.0f} s)")


def fetch_vlasic(root: Path, keep_archives: bool):
    for seq in VLASIC_SEQUENCES:
        seq_dir = root / "vlasic" / seq
        for part in ("meshes", "template"):
            if (seq_dir / part).is_dir() and any((seq_dir / part).iterdir()):
                print(f"  déjà extrait : {seq}/{part}")
                continue
            archive = seq_dir / f"{part}.tgz"
            download(f"{VLASIC_BASE}/{seq}/{part}.tgz", archive)
            with tarfile.open(archive) as tar:
                tar.extractall(seq_dir / part, filter="data")
            if not keep_archives:
                archive.unlink()
        n = sum(1 for _ in (seq_dir / "meshes").rglob("*.obj"))
        print(f"vlasic {seq} : {n} OBJ")


def fetch_disney(root: Path, keep_archives: bool):
    out = root / "disney"
    if all(any(out.glob(f"*{s}")) for s in DISNEY_KEEP):
        print("  nuage Disney déjà extrait")
        return
    archive = out / "wdas_cloud.zip"
    download(DISNEY_URL, archive)
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            name = Path(info.filename).name
            if name.endswith(DISNEY_KEEP) or name.lower().endswith((".pdf", ".txt")):
                with z.open(info) as src, open(out / name, "wb") as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
                print(f"  extrait : {name} ({info.file_size / 1e6:,.0f} Mo)")
    if not keep_archives:
        archive.unlink()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(Path(__file__).resolve().parents[2] / "data"))
    ap.add_argument("--only", choices=["vlasic", "disney"])
    ap.add_argument("--keep-archives", action="store_true")
    args = ap.parse_args()
    raw = Path(args.data) / "raw"
    if args.only in (None, "vlasic"):
        fetch_vlasic(raw, args.keep_archives)
    if args.only in (None, "disney"):
        fetch_disney(raw, args.keep_archives)
    print("TERMINÉ")


if __name__ == "__main__":
    sys.exit(main())
