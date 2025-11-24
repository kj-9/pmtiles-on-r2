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
* [pmtiles CLI](https://github.com/protomaps/go-pmtiles)（`scripts/convert_and_upload.sh` 内で `npx -y pmtiles@5.5.0` を自動実行）
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
