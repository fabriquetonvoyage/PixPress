# PixPress

Conversion et compression d'images **par lot**, simple et rapide, pour macOS.
Glissez vos images, choisissez le format et la qualité, enregistrez — c'est tout.

Application **native Apple Silicon** (100 % arm64, sans Electron), écrite en
**Swift / SwiftUI** et compilée avec Swift Package Manager. Inspirée de
[Imagine](https://github.com/meowtec/Imagine).

![Capture d'écran de PixPress](PixPress-Screenshot.webp)

## Fonctionnalités

- Glisser-déposer d'images (ou de dossiers entiers), traitement **par lot**
- Formats de sortie : **WebP** (avec ou sans perte), **JPEG**, **PNG**, **HEIC**, **AVIF**
- Curseur de **qualité**, **redimensionnement** optionnel (côté max, sans agrandissement)
- Aperçu **avant / après** avec pourcentage d'économie par image et au total
- Enregistrement à côté des originaux (sans jamais écraser) ou dans un dossier choisi

## Moteur de compression

| Format | Moteur |
|--------|--------|
| JPEG | **mozjpeg** liée **statiquement** (encodeur progressif + trellis) |
| WebP | **libwebp** liée **statiquement** |
| PNG / HEIC / AVIF | **ImageIO** (framework Apple, natif) |

libwebp et mozjpeg sont liées **statiquement** : l'app ne dépend d'aucune
bibliothèque Homebrew au runtime (vérifiable avec `otool -L`).

## Prérequis pour compiler

- macOS Apple Silicon, outils en ligne de commande Xcode (`xcode-select --install`)
- `libwebp` et `mozjpeg` installées via Homebrew (en-têtes + archives statiques) :
  ```
  brew install webp mozjpeg
  ```

## Construire

```bash
./build.sh          # produit PixPress.app
open PixPress.app
```

Pour installer dans les Applications :

```bash
cp -R PixPress.app /Applications/
```

## Mode ligne de commande

Le binaire embarque un mode CLI pratique pour scripter :

```bash
PixPress.app/Contents/MacOS/PixPress --cli entree.jpg sortie.webp \
    --format webp --quality 80 [--lossless] [--max 2000]
```

Formats : `webp`, `jpeg`, `png`, `heic`, `avif`.

## Notes

- Le **JPEG** est encodé par **mozjpeg** (progressif, quantification trellis) :
  sensiblement plus léger que l'encodeur ImageIO à qualité équivalente.
- Le **PNG** est ré-encodé sans perte (métadonnées supprimées). Pour réduire fortement
  le poids d'un PNG, convertissez-le en **WebP** (avec ou sans perte).
