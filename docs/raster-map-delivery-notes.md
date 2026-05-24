# 古地図ラスター配信方式の調査メモ

作成日: 2026-05-23

## 背景

このリポジトリでは、迅速測図などの古地図ラスターを MBTiles から PMTiles に変換し、Cloudflare R2 に置いて MapLibre GL JS から表示する流れを検証している。

ローカルにあった `data/tokyo5000.pmtiles` をプレビューしたところ、地図画像の外側や一部領域が白く表示された。原因と代替方式を調べた。

## 初期検証時のローカルファイル

初期検証時は、Git 管理外の作業ファイルとして以下があった。

```text
data/tokyo5000.mbtiles   113M
data/tokyo5000.pmtiles   111M
pmtiles                   38M
preview_tokyo.html        一時プレビュー用HTML
```

`pmtiles show data/tokyo5000.pmtiles` の主な結果:

```text
pmtiles spec version: 3
tile type: jpg
bounds: (139.714136, 35.649602) (139.798991, 35.718700)
min zoom: 0
max zoom: 18
tile contents count: 5011
format jpg
name Tokyo5000-900913.tif
```

## 白いエリアの原因

白い部分は MapLibre が勝手に白く塗っているのではなく、タイル画像側に白ピクセルとして入っている可能性が高い。

MBTiles/PMTiles はタイル画像を入れる箱であり、全タイルを埋める必要はない。存在しないタイルは 404 や空扱いにできる。一方で、元ラスターの NoData や余白がタイル生成時に白背景として焼き込まれると、背景地図の上に白いタイルとして表示される。

今回の `tokyo5000.pmtiles` は `jpg` タイルなので、透明チャンネルを持てない。白い部分は透明ではなく白ピクセルとして保存されている。

参考:

- [MBTiles specification](https://github.com/mapbox/mbtiles-spec)
- [PMTiles data format docs](https://docs.foursquare.com/analytics-products/docs/data-formats-pmtiles)
- [GDAL gdal2tiles documentation](https://gdal.org/en/stable/programs/gdal2tiles.html)

## JPEG / PNG / WebP の違い

### JPEG

- 透明を持てない
- 写真・スキャン画像に強く、サイズが小さくなりやすい
- 非可逆圧縮
- NoData や余白は白・黒などの実ピクセルとして焼き込まれる

### PNG

- アルファチャンネルを持てる
- 透明な余白を表現できる
- 可逆圧縮
- スキャン古地図では JPEG よりかなり重くなる可能性がある

### WebP

- 透明を持てる
- PNG より軽くできる可能性がある
- ただしツールチェーン、ブラウザ、配信側の対応確認が必要

GDAL の `gdal2tiles` は PNG / WebP / JPEG をサポートしている。GDAL ドキュメントにも、JPEG は透明をサポートしないため、ソース範囲外のエリアが背景色として出る旨が書かれている。

参考:

- [GDAL gdal2tiles `--tiledriver`](https://gdal.org/en/stable/programs/gdal2tiles.html)
- [GIS StackExchange: Black background after using gdal2tiles](https://gis.stackexchange.com/questions/491855/black-background-after-using-gdal2tiles/491879)

## PMTiles のまま改善する案

PMTiles を最終配信形式にする場合、白地問題への対処は主に以下。

1. JPEG のまま `raster-opacity` を下げる
2. 元 MBTiles からタイルを取り出して白地を透明化し、PNG/WebP タイルで PMTiles を作り直す
3. 元ラスターに NoData / alpha を正しく設定してから再タイル化する
4. 有効範囲だけをマスク・クリップする

もっとも簡単なのは `raster-opacity` を下げること。ただし白だけでなく地図全体も薄くなる。

白だけ透明化するには、MapLibre の通常の raster layer 設定だけでは難しい。タイル画像そのものを PNG/WebP など透明対応形式で作り直す必要がある。

## DVC と R2 配信用 object の扱い

Kanto の WebP PMTiles は DVC pipeline で生成過程を管理しつつ、R2 上では別アプリケーションから直接読める固定名 object として配信する。

採用した方針:

```text
COG download / white mask / WebP PMTiles build
  -> data/output/kanto/kanto-rapid-webp-q90.pmtiles
  -> R2: pmtiles/kanto-rapid-webp-q90.pmtiles
```

`dvc push` は DVC cache を remote に送るためのコマンドなので、R2 上の object key は content hash になる。これは DVC の再現性・重複排除には都合がよいが、別アプリケーションが `https://.../pmtiles/kanto-rapid-webp-q90.pmtiles` のような安定 URL として読む用途には向かない。

そのため、配信用 PMTiles は `publish_kanto_pmtiles` stage の中で AWS CLI により固定 key へアップロードし、その R2 object を DVC の外部 output として記録する。

```yaml
outs:
  - remote://r2-final/pmtiles/kanto-rapid-webp-q90.pmtiles:
      cache: false
```

この設定の意味:

- R2 上の object 名は `pmtiles/kanto-rapid-webp-q90.pmtiles` に固定する
- DVC は `dvc.lock` に ETag、size、依存ファイル、params を記録する
- Git では「どの入力とパラメータで、どの配信用 object を作ったか」を追跡できる
- `.dvc/cache` に 1GB 超の PMTiles を二重保存しない
- raw COG や白抜き済み COG は一時ファイルとして扱い、DVC output にしない

つまり、この構成でも DVC によるバージョン管理は成立する。ただし DVC の content-addressed cache に成果物を保存する管理ではなく、DVC pipeline と lock file で外部配信用 object の状態を管理する方式になる。

トレードオフ:

- `dvc push` / `dvc pull` だけで成果物を復元する運用ではない
- 固定 key に上書きアップロードするため、R2 側で過去版を残したい場合は bucket versioning や key に日付・バージョンを含める運用が必要
- `.dvc/cache` は小さく保てるが、ローカル確認用の最終 PMTiles は `data/output/kanto/` に残る
- 別アプリケーションは DVC の hash object ではなく、固定 key の PMTiles を読む

このリポジトリでは、配信 URL の安定性とローカル/R2 容量の削減を優先して、この外部 output + `cache: false` の構成にしている。現在の実行手順は [DVC 関東 pipeline メモ](./dvc-kanto-pipeline.md) にまとめている。

## COG という選択肢

COG は Cloud Optimized GeoTIFF の略で、HTTP Range request によって必要な部分だけ読めるように内部構造を最適化した GeoTIFF。

COG は PMTiles の単純な置き換えというより、元ラスターの保持形式として有力。NoData、alpha、座標系、解像度を保ちやすい。

参考:

- [Cloud Optimized GeoTIFF](https://cogeo.org/)
- [OGC Cloud Optimized GeoTIFF Standard](https://www.ogc.org/publications/standard/ogc-cloud-optimized-geotiff/)
- [Cloud-Optimized Geospatial Formats Guide: COG](https://guide.cloudnativegeo.org/cloud-optimized-geotiffs/intro.html)

### COG の利点

- 元画像に近い形で NoData / alpha を保持できる
- R2/S3 などのオブジェクトストレージに置ける
- Range request で必要部分だけ読める
- GIS 処理や再変換の元データとして扱いやすい

### COG の注意点

- MapLibre の通常の raster source は `{z}/{x}/{y}.png` などのタイル URL を読む想定
- COG をそのまま読むには専用 protocol/plugin が必要
- ブラウザ側で COG を読む場合、端末性能や同時アクセス規模によっては PMTiles より重くなる可能性がある
- CORS と HTTP Range request が必要

## MapLibre GL JS の COG 対応

MapLibre GL JS 公式 examples に COG raster source の例がある。

ただし、MapLibre GL JS 本体に COG デコーダが完全内蔵されたというより、`addProtocol` と `@geomatico/maplibre-cog-protocol` を使う形。

公式 example の要点:

```js
maplibregl.addProtocol('cog', MaplibreCOGProtocol.cogProtocol)

map.addSource('cogSource', {
  type: 'raster',
  url: 'cog://https://maplibre.org/maplibre-gl-js/docs/assets/cog.tif',
  tileSize: 256
})
```

参考:

- [MapLibre GL JS: Add a COG raster source](https://maplibre.org/maplibre-gl-js/docs/examples/add-a-cog-raster-source/)
- [geomatico/maplibre-cog-protocol](https://github.com/geomatico/maplibre-cog-protocol)

`maplibre-cog-protocol` の重要な制約:

- COG は EPSG:3857 / Google Mercator を想定
- ライブラリ側では再投影しない
- `tileSize: 256` 推奨
- RGB/RGBA COG は raster source と raster layer で表示可能
- custom color function によって NoData を透明化できる

## Allmaps の配信方式

Allmaps viewer のサンプル URL を解析した。

対象:

```text
https://viewer.allmaps.org/?url=https%3A%2F%2Fannotations.allmaps.org%2Fimages%2Fd09f3c771835418f&map=https%3A%2F%2Fannotations.allmaps.org%2Fmaps%2Fd1c5962babd8a2a9
```

### Georeference Annotation

```text
https://annotations.allmaps.org/maps/d1c5962babd8a2a9
```

これは IIIF Georeference Annotation。GCP、画像座標、緯度経度、変換方式が入っている。

主な内容:

```json
{
  "motivation": "georeferencing",
  "target": {
    "source": {
      "id": "https://iiif.digitalcommonwealth.org/iiif/2/commonwealth:xg94j193b",
      "type": "ImageService2",
      "height": 7248,
      "width": 10144
    }
  },
  "body": {
    "type": "FeatureCollection",
    "transformation": {
      "type": "polynomial",
      "options": {
        "order": 1
      }
    }
  }
}
```

### 元画像

```text
https://iiif.digitalcommonwealth.org/iiif/2/commonwealth:xg94j193b/info.json
```

IIIF Image API 2.0 の ImageService。

主な内容:

```json
{
  "width": 10144,
  "height": 7248,
  "tiles": [
    {
      "width": 1024,
      "height": 1024,
      "scaleFactors": [1, 2, 4, 8, 16, 32, 64]
    }
  ],
  "profile": [
    "http://iiif.io/api/image/2/level2.json",
    {
      "formats": ["tif", "jpg", "gif", "png"]
    }
  ]
}
```

実画像は Cantaloupe が返している。

例:

```text
https://iiif.digitalcommonwealth.org/iiif/2/commonwealth:xg94j193b/0,0,512,512/256,/0/default.jpg
```

レスポンス:

```text
content-type: image/jpeg
x-powered-by: Cantaloupe/5.0.6
access-control-allow-origin: *
```

参考:

- [IIIF Image API](https://iiif.io/api/image/3.0/)
- [Cantaloupe Image Server](https://cantaloupe-project.github.io/)
- [Digital Commonwealth IIIF info.json](https://iiif.digitalcommonwealth.org/iiif/2/commonwealth:xg94j193b/info.json)

### Allmaps viewer の実装上の特徴

Allmaps viewer は、PMTiles/MBTiles/COG を直接配信しているわけではない。

おおまかには以下の構成。

```text
IIIF ImageService
  -> 画像タイルを部分取得
Georeference Annotation
  -> GCP と変換情報
Allmaps viewer
  -> ブラウザ側 WebGL でワープ表示
```

つまり、元画像をあらかじめ WebMercator の JPEG タイルに焼き切るのではなく、IIIF 画像タイルを取得して、ブラウザ側でジオリファレンスに従って歪ませている。

この方式では、PMTiles の JPEG タイルに白地を固定的に焼き込む構成とは違い、マスクや透明処理を表現しやすい。

また viewer バンドル内には、以下のような XYZ タイル URL を UI に出す実装もあった。

```text
https://allmaps.xyz/maps/{mapId}/{z}/{x}/{y}.png
```

これは Allmaps 側でワープ済み PNG タイルとして配信するルートと思われる。ただし、今回の `d1c5962babd8a2a9` でいくつか試したタイル URL は `404` だった。新しい Annotation のため未生成、未インデックス、または範囲外の可能性がある。

## 配信方式の比較

| 方式 | 表示のしやすさ | 透明対応 | 静的配信 | 処理負荷 | 備考 |
| --- | --- | --- | --- | --- | --- |
| JPEG PMTiles | 高い | なし | 強い | 低い | 今回の白地問題が出やすい |
| PNG PMTiles | 高い | あり | 強い | 低い | サイズが大きくなりやすい |
| WebP PMTiles | 高い | あり | 強い | 低い | ツール対応確認が必要 |
| COG + MapLibre protocol | 中 | あり | 可能 | ブラウザ側でやや高い | R2 + Range + CORS で試せる |
| COG + TiTiler/Martin | 高い | あり | サーバー必要 | サーバー側 | キャッシュ設計が必要 |
| IIIF + Allmaps 型 | 中 | 実装次第 | IIIF サーバー必要 | ブラウザ側 | ジオリファレンス古地図向き |

## ローカルMBTilesから画質劣化なしCOGを作る検証

作成日: 2026-05-23

入力は `data/tokyo5000.mbtiles`。これは GDAL では EPSG:3857、`15818 x 15859`、RGBA として読める。ただし Alpha band の統計は `Minimum=255, Maximum=255` で、実質的に全ピクセル不透明だった。そのため、単純にCOG化しても白い外周は透明にならない。

画質を追加劣化させないため、COGの圧縮は可逆のみを使った。JPEG / WebP などの非可逆圧縮は使っていない。

### 作成したファイル

```bash
gdal_translate data/tokyo5000.mbtiles data/tokyo5000-alpha-deflate.cog.tif \
  -of COG \
  -co COMPRESS=DEFLATE \
  -co PREDICTOR=2 \
  -co BLOCKSIZE=256 \
  -co OVERVIEWS=AUTO

gdal_translate data/tokyo5000.mbtiles data/tokyo5000-alpha-zstd.cog.tif \
  -of COG \
  -co COMPRESS=ZSTD \
  -co LEVEL=9 \
  -co PREDICTOR=2 \
  -co BLOCKSIZE=256 \
  -co OVERVIEWS=AUTO
```

白いピクセルを透明化する比較版は、`RGB >= 250` の箇所だけ Alpha 0 にした。RGB値は元のMBTiles由来の値をそのまま使い、4バンド目だけ差し替えた。

```bash
gdal_calc.py \
  -A data/tokyo5000.mbtiles --A_band=1 \
  -B data/tokyo5000.mbtiles --B_band=2 \
  -C data/tokyo5000.mbtiles --C_band=3 \
  --calc="where((A>=250)*(B>=250)*(C>=250),0,255)" \
  --outfile=/private/tmp/tokyo5000-white-mask-250-alpha.tif \
  --type=Byte \
  --NoDataValue=none

gdal_translate /private/tmp/tokyo5000-white-mask-250-rgba.vrt \
  data/tokyo5000-white-mask-250-deflate.cog.tif \
  -of COG \
  -colorinterp red,green,blue,alpha \
  -co COMPRESS=DEFLATE \
  -co PREDICTOR=2 \
  -co BLOCKSIZE=256 \
  -co OVERVIEWS=AUTO
```

実際には `gdalbuildvrt -separate` の前に、RGB各バンドを一時GeoTIFFへ分けてから、白マスクAlphaと4バンドVRTにまとめた。

### サイズ比較

| ファイル | 形式 | サイズ | 備考 |
| --- | --- | ---: | --- |
| `data/tokyo5000.mbtiles` | JPEG MBTiles | 118,422,528 bytes / 113M | 入力 |
| `data/tokyo5000.pmtiles` | JPEG PMTiles | 116,619,304 bytes / 111M | 既存比較対象 |
| `data/tokyo5000-alpha-deflate.cog.tif` | COG DEFLATE | 660,946,666 bytes / 630M | 可逆、Alphaは全255 |
| `data/tokyo5000-alpha-zstd.cog.tif` | COG ZSTD | 639,350,085 bytes / 610M | 可逆、DEFLATEより少し小さい |
| `data/tokyo5000-white-mask-250-deflate.cog.tif` | COG DEFLATE + Alpha mask | 678,342,661 bytes / 647M | `RGB >= 250` を透明化 |

可逆COGは、JPEGタイルのPMTilesより約5.5倍から5.8倍大きい。画質を追加劣化させない方針では、このサイズ増は避けにくい。

### GDAL検証結果

3つのCOGはいずれも `LAYOUT=COG`、EPSG:3857、`Block=256x256`、overviewあり。

白マスク版の主な確認結果:

```text
COMPRESSION=DEFLATE
PREDICTOR=2
Band 4 ColorInterp=Alpha
Band 4 Minimum=0, Maximum=255, Mean=236.211
RGB bands STATISTICS_VALID_PERCENT=92.63
```

素のAlpha保持版は Alpha band が `Minimum=255, Maximum=255` だったため、白地問題の解消には白マスク版が必要。

### 表示・性能確認

検証ページを追加した。

```text
viewer/cog-compare.html
```

Range request対応のローカルサーバーで開く。

```bash
env npm_config_cache=/private/tmp/npm-cache-cog npx --yes http-server . -p 4174 -c-1
```

`python3 -m http.server` は `Range: bytes` に対して `206 Partial Content` を返さなかったため、COG検証には使わない。

確認結果:

- `PMTiles JPG` は既存どおり白い矩形の余白が見える。
- `COG DEFLATE` / `COG ZSTD` は可逆COGとして表示できるが、Alphaが全255なので白地は残る。
- `COG 白マスク` は背景地図の上で白い外周が抜けて見える。
- `RGB >= 250` のマスクでは、目視範囲では道路・文字・薄い線の大きな欠落は見えなかった。ただし詳細な採否には地点を増やした目視確認が必要。

ブラウザ内の簡易計測では、COG protocol の内部取得とブラウザキャッシュの影響で、初回表示時間と転送量は安定したベンチマークにはならなかった。計測UIでは12秒経過時点の暫定値を `12000 ms以上` として表示する。Range request自体は `http-server` への `curl -r 0-1023` で `206 Partial Content` と `Accept-Ranges: bytes` を確認した。

今回の結論:

- 白地除去だけなら `data/tokyo5000-white-mask-250-deflate.cog.tif` が有効。
- ただし配信用サイズはPMTilesより大幅に大きい。
- COGはブラウザ直接配信の最終形式としては追加検証が必要で、現時点では「画質劣化なしの保存・中間形式」として有力。
- 軽量なWeb配信を優先するなら、別途PNG/WebPタイルPMTilesを作る比較が必要。ただしWebPは非可逆設定にすると今回の画質条件から外れる。

## 現時点の推奨

今回の目的が「R2 に置いて MapLibre で古地図を重ねる」なら、次の順で検証するのがよい。

1. 元 GeoTIFF を用意する
2. NoData / alpha を正しく設定する
3. EPSG:3857 の COG を作る
4. R2 に置く
5. `@geomatico/maplibre-cog-protocol` で MapLibre から直接表示する
6. 表示品質、速度、通信量を確認する
7. 重ければ透明 PNG/WebP PMTiles 化を検討する

短期的には COG 直接表示を試す価値がある。うまくいけば、PMTiles 化する前に白地問題を回避できる可能性がある。

一方で、多人数向け公開や高頻度アクセスが前提なら、最終的には透明 PNG/WebP の PMTiles、または COG から生成するタイルサーバー + キャッシュ構成も検討する。

## 次の実験案

実行計画は別ファイルに整理した。

- [DVC 関東 pipeline メモ](./dvc-kanto-pipeline.md)

### A. COG 直接表示

`tokyo5000.mbtiles` ではなく、元 GeoTIFF が必要。もし元の `Tokyo5000-900913.tif` 相当を入手できれば、以下の方向で COG 化する。

```bash
gdalwarp input.tif tokyo5000-cog.tif \
  -of COG \
  -t_srs EPSG:3857 \
  -co BLOCKSIZE=256 \
  -co TILING_SCHEME=GoogleMapsCompatible \
  -co COMPRESS=DEFLATE \
  -co OVERVIEWS=IGNORE_EXISTING \
  -dstalpha
```

JPEG 圧縮 COG は軽いが、透明を扱うなら alpha と圧縮方式の組み合わせを検証する。

### B. 透明 PMTiles

MBTiles からタイルを取り出し、白地を透明化して PNG/WebP にする。

注意点:

- 古地図の紙色や文字まで抜ける可能性がある
- 完全な白だけ抜くか、白っぽい色も抜くかの閾値設計が必要
- 全変換前に数タイルで見た目とサイズを比較する

### C. Allmaps 型の検討

古地図のジオリファレンスを GCP として保持し、元画像は IIIF 互換で配信し、ブラウザ側でワープする構成。

これは PMTiles より柔軟だが、MapLibre の通常 raster layer とは違う実装になる。既存の Allmaps ライブラリや viewer の再利用可能性を調べる価値がある。
