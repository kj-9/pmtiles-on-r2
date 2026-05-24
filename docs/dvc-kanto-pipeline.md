# DVC 関東 pipeline メモ

作成日: 2026-05-24

## 目的

関東迅速測図の COG から、MapLibre で軽く表示できる WebP PMTiles を作り、Cloudflare R2 の固定 object key に公開する。

このリポジトリでは DVC を次の用途に限定する。

- 生成手順を `dvc.yaml` に固定する
- 入力 URL、白抜き閾値、WebP quality、R2 key を `params.yaml` で管理する
- `dvc.lock` に生成物と R2 object の状態を記録する
- 巨大な中間 COG を Git / DVC cache に入れない

## pipeline

```text
source COG
  -> /private/tmp に download
  -> RGB >= threshold の画素だけ alpha 0 にする
  -> WebP PMTiles を data/output/kanto/ に生成
  -> R2 の固定 key に upload
```

`dvc.yaml` の stage:

| stage | cmd | outs |
| --- | --- | --- |
| `build_kanto_webp_pmtiles` | `scripts/build_kanto_webp_pmtiles.sh` | `data/output/kanto/${kanto.output_name}.pmtiles` |
| `publish_kanto_pmtiles` | `scripts/upload_pmtiles_to_r2.sh` | `remote://r2-final/${kanto.publish_key}` |

## output 方針

`build_kanto_webp_pmtiles` の output はローカル確認用の最終 PMTiles のみ。

```yaml
outs:
  - data/output/kanto/${kanto.output_name}.pmtiles:
      cache: false
```

`publish_kanto_pmtiles` の output は R2 上の固定 key。

```yaml
outs:
  - remote://r2-final/${kanto.publish_key}:
      cache: false
```

`cache: false` にしている理由:

- 最終 PMTiles は大きく、`.dvc/cache` に二重保存したくない
- 配信用 URL は DVC cache の hash object ではなく、安定した固定 key にしたい
- 再現性は pipeline、params、lock file で担保する

このため、`dvc push` / `dvc pull` だけで配信用 PMTiles を復元する運用ではない。配信用 object の作成は `publish_kanto_pmtiles` stage が担当する。

## 中間ファイル

以下はすべて一時ファイルとして扱う。

- raw COG
- 白抜き済み COG
- GDAL / pmtiles 変換中の作業ファイル

`scripts/build_kanto_webp_pmtiles.sh` は `mktemp -d /private/tmp/kanto-webp-pmtiles.XXXXXX` を使い、終了時に一時ディレクトリを削除する。

`data/` は最終成果物のローカル確認用置き場で、`.gitignore` で除外する。

## 白抜き方式

`scripts/mask_white_cog.sh` は `RGB >= kanto.white_threshold` の画素だけ alpha を 0 にする。

現在の初期値:

```yaml
kanto:
  white_threshold: 250
```

`nearblack` で周辺色をまとめて消す方式ではなく、RGB 値を維持したまま alpha band を差し替える。地図内の紙色や薄い注記を消しすぎないため、閾値を変えたときは Viewer で必ず確認する。

## WebP quality

`kanto.webp_quality` は GDAL の WebP tile 生成時の `QUALITY` に渡す。

現在の初期値:

```yaml
kanto:
  webp_quality: 90
```

古地図は細線と注記が多いため、単純に quality を下げると容量以上に可読性が落ちることがある。容量を下げたい場合は `85` や `80` の別名 output を作り、Viewer で比較する。

## R2 remote

`remote://r2-final/...` を使うため、DVC remote を設定する。

```bash
cp .env.example .env
./scripts/configure_dvc_r2_remote.sh
```

必要な環境変数:

- `DVC_R2_BUCKET`
- `DVC_R2_ENDPOINT`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

`publish_kanto_pmtiles` は AWS CLI で `s3://$DVC_R2_BUCKET/$R2_KEY` に upload する。R2 の Custom Domain や public access / CORS は bucket 側で別途設定する。

## 実行コマンド

生成だけ:

```bash
uv run --with "dvc[s3]" dvc repro build_kanto_webp_pmtiles
```

公開だけ:

```bash
uv run --with "dvc[s3]" dvc repro publish_kanto_pmtiles
```

一括:

```bash
uv run --with "dvc[s3]" dvc repro
```

状態確認:

```bash
uv run --with "dvc[s3]" dvc status
uv run --with "dvc[s3]" dvc dag
```

## Viewer 確認

```bash
env npm_config_cache=/private/tmp/npm-cache-cog npx --yes http-server . -p 4174 -c-1
```

`http://127.0.0.1:4174/viewer/` で以下を確認する。

- PMTiles が読める
- 白い余白が背景を隠さない
- 地図内の紙色、白い道路、注記が消えすぎていない
- `tileSize` が生成物と Viewer で一致している

## 関連メモ

形式選定、JPEG / PNG / WebP の違い、COG / PMTiles / R2 配信の背景は [古地図ラスター配信方式の調査メモ](/Users/kh03/work/repos/pmtiles-on-r2/docs/raster-map-delivery-notes.md) に残す。
