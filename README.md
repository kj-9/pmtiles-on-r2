# pmtiles-on-r2

迅速測図の COG から白抜き WebP PMTiles を生成し、Cloudflare R2 の固定 object key に公開するための作業リポジトリです。

DVC は巨大な中間ファイルを cache する用途ではなく、COG 取得、白抜き、PMTiles 生成、R2 公開の pipeline と lock file を管理するために使います。

## 現在の構成

| 種類 | 場所 | 役割 |
| --- | --- | --- |
| DVC pipeline | `dvc.yaml` | 関東迅速測図 PMTiles の生成と公開 |
| パラメータ | `params.yaml` | 元 COG URL、白抜き閾値、WebP quality、R2 key |
| スクリプト | `scripts/` | download、白抜き、PMTiles 生成、R2 upload |
| Viewer | `viewer/` | 生成済み PMTiles と元 COG の表示確認 |
| 背景メモ | `docs/` | 設計判断と調査メモ |

`data/` は生成物置き場で、Git には入れません。

## DVC pipeline

定義されている stage は 2 つです。

| stage | 内容 | output |
| --- | --- | --- |
| `build_kanto_webp_pmtiles` | COG を一時領域へ download し、白を alpha 化して WebP PMTiles を作る | `data/output/kanto/${kanto.output_name}.pmtiles` |
| `publish_kanto_pmtiles` | 生成 PMTiles を R2 の固定 key に upload する | `remote://r2-final/${kanto.publish_key}` |

raw COG と白抜き済み COG は `/private/tmp` に作る一時ファイルです。DVC output には入れません。

最終 PMTiles と R2 外部 output はどちらも `cache: false` です。巨大ファイルを `.dvc/cache` に二重保存せず、`dvc.lock` で入力、params、checksum、size を記録します。

## セットアップ

必要なもの:

- `uv`
- `curl`
- GDAL CLI
- AWS CLI
- リポジトリルートの `./pmtiles` CLI

R2 / DVC remote の設定:

```bash
cp .env.example .env
# .env に DVC_R2_BUCKET、DVC_R2_ENDPOINT、AWS_ACCESS_KEY_ID、AWS_SECRET_ACCESS_KEY を入れる

./scripts/configure_dvc_r2_remote.sh
```

`.env` と `.dvc/config.local` は Git 管理外です。

## 使い方

PMTiles を生成:

```bash
uv run --with "dvc[s3]" dvc repro build_kanto_webp_pmtiles
```

R2 の固定 key へ公開:

```bash
uv run --with "dvc[s3]" dvc repro publish_kanto_pmtiles
```

生成から公開まで一括実行:

```bash
uv run --with "dvc[s3]" dvc repro
```

DVC cache remote へ送る `dvc push` は、配信用の固定名 PMTiles を公開する操作ではありません。配信用 object は `publish_kanto_pmtiles` stage で管理します。

## パラメータ変更

`params.yaml` の `kanto` を変更してから `dvc repro` します。

| key | 意味 |
| --- | --- |
| `source_url` | 元 COG URL |
| `white_threshold` | `RGB >= threshold` の画素を透明化する閾値 |
| `compression` | 白抜き COG の一時ファイル圧縮方式 |
| `webp_quality` | GDAL WebP tile の `QUALITY` |
| `tile_size` | PMTiles の tile size |
| `output_name` | ローカル PMTiles の basename |
| `publish_key` | R2 に公開する固定 object key |

`output_name` や `source_url` を変えた場合、Viewer の静的 URL 定義も必要に応じて更新してください。

## Viewer

ローカル確認:

```bash
env npm_config_cache=/private/tmp/npm-cache-cog npx --yes http-server . -p 4174 -c-1
```

`http://127.0.0.1:4174/viewer/` を開くと、生成 PMTiles と元 COG を切り替えて確認できます。白い余白が透明化されていれば、背景地図またはチェッカーボードが見えます。

## 容量要件

`kanto.source_url` の COG は大きいため、処理中に raw COG、白抜き COG、最終 PMTiles の領域が必要です。少なくとも 50 GB 以上の空き容量を見ておく方が安全です。一時ファイルは処理終了後に削除されます。

## docs

- [DVC 関東 pipeline メモ](/Users/kh03/work/repos/pmtiles-on-r2/docs/dvc-kanto-pipeline.md)
- [古地図ラスター配信方式の調査メモ](/Users/kh03/work/repos/pmtiles-on-r2/docs/raster-map-delivery-notes.md)

## 参考リンク

- データ配布: https://boiledorange73.sakura.ne.jp/data.html
- PMTiles 仕様: https://github.com/protomaps/PMTiles
- MapLibre GL JS: https://maplibre.org/
