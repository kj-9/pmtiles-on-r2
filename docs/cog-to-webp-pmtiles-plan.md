# 古地図 COG から WebP PMTiles を作る実行プラン

作成日: 2026-05-23

## 目的

COG をマスター元データとして保持しつつ、白い余白や空タイルを除外し、MapLibre で軽く表示できる WebP PMTiles を作る。

狙いは以下。

1. COG は再処理可能なマスターとして残す
2. 地図外側の白い余白を透明化する
3. 完全に空のタイルは配信物から除外する
4. MapLibre + PMTiles protocol で静的配信できる形にする
5. PNG より軽く、JPEG より古地図表示に向いた成果物を作る

## 全体方針

| 項目 | 方針 |
| --- | --- |
| 元データ | COG を保持する |
| 加工対象 | まず小さい COG で試す |
| 配信用形式 | WebP PMTiles |
| 白い部分 | Alpha / NoData 化して透明にする |
| 空タイル | 生成時に除外する |
| 表示 | MapLibre + PMTiles protocol |
| 最終検証 | 容量、画質、白抜け、表示速度を見る |

## 推奨パイプライン

```text
COG
↓
白い外周・NoData 領域を Alpha 化
↓
WebP タイル生成
↓
空タイル除外
↓
PMTiles 化
↓
MapLibre で表示確認
```

## Phase 1: 小さい COG で検証

いきなり大きい関東迅速測図ではなく、まず小さい方で試す。

```text
東京5000 COG
↓
WebP PMTiles
```

検証目的:

| 確認項目 | 見ること |
| --- | --- |
| 白い余白 | 透明になるか |
| 地図内の白 | 消えすぎないか |
| 文字・細線 | WebP で崩れないか |
| 容量 | PNG / JPG MBTiles より妥当か |
| MapLibre 表示 | 正常に読めるか |
| ズーム | 必要な範囲まで十分か |

## Phase 2: 白い部分の扱いを決める

ここが一番重要。

基本方針は、**地図外側の白い余白・空白タイルだけ除外する**こと。

やりすぎ注意:

```text
地図内の紙色まで全部透明化する
```

これは危険。理由は以下。

- 古地図の雰囲気が消える
- 白い道路、注記背景、文字周辺が抜ける
- 境界が不自然になる可能性がある

白抜き方針:

| 対象 | 処理 | 推奨 |
| --- | --- | --- |
| 完全白タイル | 除外 | ◎ |
| 外周の白余白 | Alpha 化 | ◎ |
| ほぼ白の外周 | `nearblack` などで Alpha 化 | ○ |
| 地図内の紙色 | 基本残す | 推奨 |
| 線・文字だけ重ねたい場合 | 紙色も透明化を検討 | 要検証 |

## Phase 3: Alpha 付き GeoTIFF を作る

COG に NoData や Alpha が入っていれば、そのまま使える可能性がある。

入っていない場合は、白を透明化した中間ファイルを作る。

### 完全白を NoData 扱いする例

```bash
gdalwarp \
  -srcnodata "255 255 255" \
  -dstalpha \
  -of GTiff \
  -co TILED=YES \
  -co COMPRESS=DEFLATE \
  input.cog.tif \
  alpha.tif
```

### ほぼ白い外周を Alpha 化する例

```bash
nearblack \
  -white \
  -near 15 \
  -setalpha \
  -of GTiff \
  -o alpha.tif \
  input.cog.tif
```

まずは `-near 10` から `-near 20` あたりで試す。

注意:

- `near` を上げるほど白フチは消えやすくなる
- 上げすぎると地図内の紙色や薄い注記まで抜ける
- 最初は小範囲で見た目を確認する

## Phase 4: WebP PMTiles を作る

`rio-pmtiles` を使う想定。

CLI オプションは実行前に `rio pmtiles --help` で確認する。特に `--format WEBP`、`--rgba`、`--exclude-empty-tiles`、`--co` の対応は、インストールするバージョンで確認が必要。

### 容量・画質バランス版

```bash
rio pmtiles alpha.tif output.webp.pmtiles \
  --format WEBP \
  --rgba \
  --exclude-empty-tiles \
  --tile-size 512 \
  --zoom-levels 8..16 \
  --co QUALITY=90
```

### 劣化を避ける版

```bash
rio pmtiles alpha.tif output.lossless.webp.pmtiles \
  --format WEBP \
  --rgba \
  --exclude-empty-tiles \
  --tile-size 512 \
  --zoom-levels 8..16 \
  --co LOSSLESS=TRUE
```

初期値は lossy WebP、`QUALITY=90` を推奨する。lossless は比較用。

## Phase 5: MapLibre で表示確認

PMTiles を MapLibre で読む。

```js
import maplibregl from "maplibre-gl";
import * as pmtiles from "pmtiles";

const protocol = new pmtiles.Protocol();
maplibregl.addProtocol("pmtiles", protocol.tile);

map.addSource("old-map", {
  type: "raster",
  url: "pmtiles://https://example.com/output.webp.pmtiles",
  tileSize: 512,
});

map.addLayer({
  id: "old-map",
  type: "raster",
  source: "old-map",
  paint: {
    "raster-opacity": 0.7,
  },
});
```

確認すること:

- PMTiles protocol で正常に読めるか
- WebP raster tile がブラウザで表示されるか
- 透明部分が背景地図を隠していないか
- `tileSize: 512` が MapLibre 側と成果物側で一致しているか

## Phase 6: 品質評価

| 観点 | 確認内容 |
| --- | --- |
| 白抜き | 外周だけ透明になっているか |
| 欠損 | 地図内の白い文字、道、余白が消えていないか |
| 境界 | 白いフチが残っていないか |
| 画質 | 文字・細線が読めるか |
| 容量 | PNG MBTiles / PNG PMTiles より軽いか |
| 速度 | MapLibre でスムーズに表示されるか |
| ズーム | 最大ズームが足りるか |

比較対象:

```text
既存 JPG PMTiles
PNG PMTiles
WebP PMTiles QUALITY=90
WebP PMTiles lossless
```

見るべき指標:

- ファイルサイズ
- 初回表示速度
- ズーム・パン時の体感
- 細線と文字の読みやすさ
- 白フチや抜けすぎの有無

## Phase 7: 大きい COG へ適用

東京5000で問題なければ、関東迅速測図など大きい COG に適用する。

ただし、いきなり全域は重いので以下の順に進める。

```text
小範囲切り出し
↓
品質確認
↓
ズーム範囲調整
↓
全体変換
```

大容量データでの注意:

| 問題 | 対策 |
| --- | --- |
| 変換が重い | 範囲分割する |
| PMTiles が巨大 | zoom 上限を下げる |
| 画質が悪い | `QUALITY` を上げる / lossless を試す |
| 容量が大きい | WebP lossy にする |
| 白抜きしすぎ | `near` 値を下げる |
| 白フチが残る | `near` 値を上げる |

## 推奨パラメータ初期値

| 項目 | 初期値 |
| --- | --- |
| 形式 | WebP |
| 圧縮 | lossy |
| `QUALITY` | 90 |
| `tileSize` | 512 |
| zoom | 8..16 |
| 透明化 | Alpha あり |
| 空タイル | 除外 |
| 検証範囲 | 東京5000 → 小範囲 → 全域 |

## 成功条件

以下を満たせば成功。

1. COG はマスターとして保持されている
2. 白い外周・空タイルは表示されない
3. MapLibre で WebP PMTiles が表示できる
4. 古地図の文字・線が読める
5. PNG MBTiles / PNG PMTiles より大幅に軽い
6. JPG MBTiles より重くても、透明と画質のメリットがある

## 最終構成案

```text
data/source/
  tokyo5000.cog.tif
  kanto_rapid.cog.tif

data/intermediate/
  tokyo5000_alpha.tif

data/output/
  tokyo5000.webp.pmtiles
  kanto_rapid.webp.pmtiles
```

## 判断まとめ

| 選択肢 | 判断 |
| --- | --- |
| MBTiles を直接加工 | できるが後処理感が強い |
| COG から作り直す | おすすめ |
| PNG PMTiles | 互換性は高いが重い |
| WebP PMTiles | 本命 |
| JPG MBTiles | 軽いが透明不可で古地図には微妙 |
| COG 直接表示 | 可能性はあるが配信実装が重くなりがち |

## 結論

進め方は以下でよい。

```text
COG を DL
↓
白い余白を Alpha 化
↓
WebP PMTiles 化
↓
MapLibre で表示
↓
東京5000で検証
↓
問題なければ関東迅速測図へ展開
```

まずは小さい COG で `QUALITY=90` の WebP PMTiles を作り、容量・白抜き・表示品質を比較するのが一番堅い。

## 実行前チェック

別セッションで実行する前に、以下を確認する。

1. 元 COG の入手先とライセンス
2. 元 COG の CRS、NoData、alpha の有無
3. `gdalinfo` での band 構成
4. `nearblack` の結果が地図内の紙色を抜きすぎないか
5. `rio-pmtiles` のインストール方法と CLI オプション
6. MapLibre / PMTiles JS が WebP raster tile を読めるブラウザ環境
7. R2 配信時の `Content-Type`、CORS、Range 対応
