# pmtiles-on-r2

迅速測図（農研機構「歴史的農業環境閲覧システム由来データ」など）の MBTiles を Cloudflare R2 に載せ、MapLibre で参照するまでの手順メモです。

## セットアップ概要
1. Web メルカトル（EPSG:3857/900913）で、タイル形式の MBTiles を選ぶ
   * 例: `https://boiledorange73.sakura.ne.jp/rika/habs/tokyo5000.mbtiles`
2. `scripts/convert_and_upload.sh` を使って PMTiles に変換し R2 へアップロード
3. R2 に置いた PMTiles を `viewer/index.html` で開き、MapLibre から閲覧

## 使い方
### 1. 依存関係
* bash / curl
* [pmtiles CLI](https://github.com/protomaps/go-pmtiles)（`scripts/convert_and_upload.sh` 内で `npx -y pmtiles@latest` を自動実行）
* AWS CLI（R2 は S3 互換のため）

### 2. 変換 & アップロード
環境変数を設定してスクリプトを実行します。

```bash
export MBTILES_URL="https://boiledorange73.sakura.ne.jp/rika/habs/tokyo5000.mbtiles" # 好きな MBTiles
export R2_ENDPOINT="https://<accountid>.r2.cloudflarestorage.com" # R2 エンドポイント
export R2_BUCKET="my-habs"                           # バケット名
export R2_KEY="tokyo5000.pmtiles"                    # 保存するキー（省略可）
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...

./scripts/convert_and_upload.sh
```

成功すると、末尾に公開 URL が表示されます。バケットポリシーで public-read を許可していない場合は、署名付き URL を生成して MapLibre に渡してください。

#### 4326 版が必要な場合
MapLibre で使うだけなら 3857/900913 の MBTiles を選ぶのが安全です。4326 版（例: `tokyo5000-4326.jpg.mbtiles`）を使う場合は、変換後も CRS が 4326 になるので、`viewer/index.html` の背景地図と位置合わせがズレることがあります。必要に応じて背景地図を外すか、Style を 4326 に変更してください。

### 3. MapLibre で確認（ローカル）
シンプルなビューワーが `viewer/index.html` にあります。

```bash
# ローカル HTTP サーバーで開く例
python -m http.server 8080 -d viewer
```

ブラウザで `http://localhost:8080` を開き、PMTiles の URL（R2 のオブジェクト URL か署名付き URL）を貼り付けて「Load layer」を押すと表示されます。PMTiles のヘッダーに含まれる bbox を使って自動でズームします。

Viewer 共通の見た目と PMTiles 読み込み処理は `viewer/assets/` にまとめています。ページ固有の比較条件や初期URLだけを各 HTML に残す方針です。

### 4. PMTiles / COG 比較（ローカル）
COG は HTTP Range request が必要なので、Range に対応した静的サーバーでリポジトリ直下を配信します。

```bash
env npm_config_cache=/private/tmp/npm-cache-cog npx --yes http-server . -p 4174 -c-1
```

ブラウザで `http://127.0.0.1:4174/viewer/cog-compare.html` を開くと、`data/tokyo5000.pmtiles` とローカルで作成した COG を切り替えて比較できます。

### 5. COG から WebP PMTiles を作る
白マスク済み COG から、透明を保持した WebP PMTiles を作れます。`rio-pmtiles` がない環境では、GDAL の MBTiles WebP 出力を作ってから `pmtiles convert` で PMTiles 化します。

```bash
./scripts/cog_to_webp_pmtiles.sh \
  data/tokyo5000-white-mask-250-deflate.cog.tif \
  data/output/tokyo5000-webp-q90.pmtiles
```

今回の東京5000検証では、`data/output/tokyo5000-webp-q90.pmtiles` が生成されます。MapLibre 側では `tileSize: 512` を指定してください。

### 6. DVC で kanto パイプラインを管理する
`kanto` 向けのパイプラインは DVC で管理します。DVC 自体はローカル常設インストールせず、`uv run --with "dvc[s3]" dvc ...` で実行できます。

白抜き処理は `tokyo5000-white-mask-250-deflate.cog.tif` と同じ方式で、`RGB >= 250` の画素だけ alpha 0 にします。`nearblack` ではなく、RGB値を維持したまま 4 バンド目の alpha だけ差し替えます。

パイプライン:

1. `build_kanto_webp_pmtiles`

この stage の中で COG のダウンロード、`RGB >= 250` の alpha 化、WebP PMTiles 生成までを行います。raw COG と白抜き COG は `/private/tmp` に作る一時ファイルで、DVC の `outs` には入れません。DVC が管理するのは最終 PMTiles だけです。

定義ファイル:

* [dvc.yaml](/Users/kh03/work/repos/pmtiles-on-r2/dvc.yaml)
* [params.yaml](/Users/kh03/work/repos/pmtiles-on-r2/params.yaml)

実行例:

```bash
uv run --with "dvc[s3]" dvc repro build_kanto_webp_pmtiles
```

一括実行:

```bash
uv run --with "dvc[s3]" dvc repro
```

容量要件:

`kanto` COG は配布元で 17.7 GB あります。raw COG と白抜き COG は一時ファイルとして作るので、実行前に少なくとも 50 GB 以上の空き容量を見ておく方が安全です。処理完了後、一時ファイルは削除されます。

R2 と DVC cache は最終生成物だけを管理します。中間成果物は DVC 管理対象にしません。

#### WebP quality の意味

`params.yaml` の `kanto.webp_quality` は GDAL の WebP タイル生成時に `QUALITY` として渡す値です。範囲は 1-100 で、値を上げるほど画質は上がり、ファイルサイズも大きくなります。

現在の `90` は、古地図の細線・文字の可読性を優先した高めの設定です。容量を下げたい場合は `85` や `80` の比較版を生成し、文字の読みやすさとサイズを見て判断します。古地図は細い線や注記が多いため、単純に品質を下げると見た目以上に可読性が落ちることがあります。

#### DVC remote と配信用 R2 object

`dvc push` で R2 に送られるオブジェクトは DVC cache 用なので、R2 上のキー名は content hash になります。これは DVC の正常な挙動ですが、別アプリケーションから直接参照する PMTiles URL には向きません。

別アプリケーションから読む場合は、配信用の固定キーへアップロードします。このリポジトリでは `publish_kanto_pmtiles` stage が `pmtiles/kanto-rapid-webp-q90.pmtiles` にアップロードし、その R2 object を DVC の外部 output として記録します。

```bash
uv run --with "dvc[s3]" dvc repro publish_kanto_pmtiles
```

この stage の外部 output は `cache: false` です。R2 上の object 名は固定され、`.dvc/cache` に巨大な二重コピーを作りません。それでも `dvc.lock` には checksum や size が残るため、Git 上では「どの入力・パラメータから、どの固定キーの生成物を作ったか」をバージョン管理できます。

R2 リモート設定:

```bash
cp .env.example .env
# .env に値を入れる
# 手動で読み込むなら `source .env`

./scripts/configure_dvc_r2_remote.sh
```

`.env` は `.gitignore` に入っているので、Secret は Git に乗りません。`configure_dvc_r2_remote.sh` は実行時に `.env` を自動で読み込みます。

`dvc push` は DVC cache を remote に送るためのコマンドなので、配信用の固定名 PMTiles には使いません。固定名で配信する PMTiles は `publish_kanto_pmtiles` stage で管理します。

viewer で透明化を確認する:

```bash
env npm_config_cache=/private/tmp/npm-cache-cog npx --yes http-server . -p 4174 -c-1
```

`http://127.0.0.1:4174/viewer/kanto-check.html` を開くと、生成した `data/output/kanto/kanto-rapid-webp-q90.pmtiles` を背景地図またはチェッカーボード上で確認できます。白い余白が残っていれば、背景が隠れて見えます。

## R2 側の設定ポイント
* バケットは public-read にするか、必要なとき署名付き URL を発行する
* CORS を設定し、`GET`/`HEAD` を許可（`*` かドメインを指定）
* R2 Custom Domain を設定すると URL を短くでき、HTTPS で配信しやすくなります

## よくある詰まりどころ
* **MBTiles の座標系が違う**: 3857/900913 版を使う。4326 版を使うなら MapLibre 側も 4326 スタイルにする。
* **R2 で 403/AccessDenied**: 権限（public-read または署名付き URL）、CORS 設定、キー名の打ち間違いを確認。
* **タイルが真っ黒に見える**: JPEG タイルの場合、背景が黒になることがある。PNG 版を試すか、描画のブレンド設定を確認。
* **ズームが合わない**: 付属のビューワーは PMTiles ヘッダーの bbox を優先。範囲が広すぎると初期ズームが粗くなるので、必要に応じて `fitBounds` の padding / maxZoom を調整。

## 参考リンク
* データ配布: https://boiledorange73.sakura.ne.jp/data.html
* PMTiles 仕様: https://github.com/protomaps/PMTiles
* MapLibre GL JS: https://maplibre.org/
