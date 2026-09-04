# waka-collector ConoHa VPS デプロイ Phase 1 実施結果

**実施日**: 2026-09-04
**担当**: クロコさん（Claude Code）
**依頼書**: `docs/依頼書_vps_deploy_phase1.md`（§2以降を実施）
**手順書**: `docs/vps_deploy_procedure_v1.0.md`
**対象VPS**: ConoHa 163.44.114.31（ホストエイリアス `conoha`、root）
**コミット**: `7167d1c`（force_ssl）/ `aa6aaee`（puma bind）/ `<routes>`（root path）

---

## 0. サマリ

| ステップ | 状態 |
|---|---|
| §0 事前確認（verify_shikimoku 116 pass） | ✅ Mac mini・VPS 両方で 116 pass / 0 fail |
| §1 Tailscale / Ollama 疎通 | ✅ 実施済みを確認（waka-vps 稼働、qwen3:8b/14b/30b 応答） |
| §2 PostgreSQL | ✅ ロール `waka_collector` ・DB `waka_collector_production` 作成 |
| §3 アプリデプロイ（clone/bundle/migrate/assets） | ✅ 完了。**手順書にない追加作業を4件実施**（後述） |
| §4 systemd | ✅ `waka-collector.service` 稼働・enable 済み（RSS 約96MB） |
| §5 Nginx | ✅ `sites-available/waka-collector`（listen 8081、`/cable` あり） |
| §6 nftables | ✅ host 側 `tcp dport 8081 accept` 追加・`/etc/nftables.conf` 永続化 |
| §7 動作確認 | ⚠️ **VPS内部は全て成功。外部到達のみ ConoHa セキュリティグループ待ち** |

**外部公開の最後の1手（人間作業）**: ConoHa コントロールパネルのセキュリティグループで
**TCP 8081 を許可**する必要がある（§1 Tailscale authorize と同種の、シェルから実施不可の作業）。
これが済めば `http://163.44.114.31:8081` が外部から開通する。

---

## 1. 確定した構成

```
参加者ブラウザ → Nginx(:8081) → Puma(127.0.0.1:3002) ─Tailscale→ Ollama qwen3:8b (100.71.107.6:11434)
                                     └ PostgreSQL 17 (127.0.0.1:5432, scram-sha-256)
                                     └ Action Cable (postgresql adapter, LISTEN/NOTIFY)
```

- Ruby 3.3.6（rbenv）/ Rails 7.2.3 / Puma 7.2.0 / bundler 2.6.9
- Job backend: ActiveJob `:async`（Puma プロセス内スレッド、Redis 不要）
- MeCab 0.996 + mecab-ipadic-utf8 2.7.0（`dict/user.dic` は無改変で互換）
- 使用モデル: `qwen3:8b`（`OllamaClient::MODEL` デフォルト。依頼書背景の「qwen3:14b」とは不一致だが
  Mac mini Ollama に qwen3:8b は存在するため現状は動作。切替は `WAKA_OLLAMA_MODEL` 環境変数で可能）

### VPS 上のファイル（リポジトリ管理外）

| パス | 内容 |
|---|---|
| `/etc/systemd/system/waka-collector.service` | Puma 起動。環境変数一式（下記） |
| `/etc/nginx/sites-available/waka-collector` | listen 8081、`location /` と `location /cable`（共に `Host $http_host`） |
| `/etc/nftables.conf`（`.bak_20260904` 退避あり） | `tcp dport 8081 accept` を8080の直後に追記 |
| `/var/www/waka-collector/config/database.yml` | `.sample` + `host: 127.0.0.1` / `port: 5432`（`.gitignore` 対象） |
| `/var/www/waka-collector/.bundle/config` | `deployment: true` / `without: [development, test]` |

### systemd 環境変数

```
RAILS_ENV=production
PORT=3002
RAILS_MAX_THREADS=3
WAKA_COLLECTOR_DATABASE_PASSWORD=<生成28桁>
SECRET_KEY_BASE=<rails secret 生成>
OLLAMA_URL=http://100.71.107.6:11434
WAKA_APP_ORIGIN=http://163.44.114.31:8081
HOME / PATH / GEM_HOME / GEM_PATH = rbenv 3.3.6（keiba-web と同方式）
```
DB パスワードと SECRET_KEY_BASE の実値は本ドキュメントには記載しない
（`/etc/systemd/system/waka-collector.service`、chmod 600、に格納済み）。

---

## 2. 手順書になかった追加作業（4件）

### 2-1. `config/environments/production.rb` の HTTP 対応（コミット `7167d1c`）
- `config.force_ssl = true` → **`false`**。SSL/ドメインは今回スコープ外で、IP:ポート直アクセスだと
  HTTPS 強制リダイレクト＋HSTS でアプリに到達不能になるため。keiba-web / eiyokeikaku_app も HTTP 運用。
- `config.action_cable.allowed_request_origins` を `WAKA_APP_ORIGIN` 環境変数から設定。
  Nginx が `Host` からポートを落とすと Origin 検査で WebSocket が拒否され Turbo Streams が動かないため。

### 2-2. `config/puma.rb` の本番 localhost バインド（コミット `aa6aaee`）
- `port` DSL のみだと 0.0.0.0 待受。本番は nginx 経由のみのため `bind "tcp://127.0.0.1:#{PORT}"`。

### 2-3. `config/routes.rb` にルートパス追加（コミット `<routes>`）
- `root "rengas#new"`。従来 `/` は未定義で 404 だったため、共有 URL 用にトップページを設定。

### 2-4. VPS 環境の欠落物（コード変更なし）
| 欠落 | 対応 |
|---|---|
| `config/database.yml` が `.gitignore` 対象（`.sample` のみ配布） | `.sample` をコピーし production に `host`/`port` を追記 |
| MeCab 未導入（`natto` gem が libmecab を要求） | `apt-get install mecab libmecab-dev mecab-ipadic-utf8` |
| `wakas` テーブルが空（seed 投入手順が依頼書になし） | Mac mini dev DB から `pg_dump -a -t wakas` で 2527 件を移送 |
| ConoHa セキュリティグループ | **未実施（人間作業）**。TCP 8081 の許可が必要 |

---

## 3. §7 動作確認の結果

### §7-1 到達性
| 経路 | 結果 |
|---|---|
| VPS内 `curl 127.0.0.1:3002/`（Puma 直） | 200 |
| VPS内 `curl 127.0.0.1:8081/`（Nginx 経由） | 200 |
| VPS内 `curl 163.44.114.31:8081/`（自分の公開IP） | 200 |
| **Mac mini → `163.44.114.31:8081`（外部）** | **timeout（ConoHa SG でドロップ）** |
| Mac mini → `163.44.114.31:80`（keiba-web） | 302（正常） |
| Mac mini → `163.44.114.31:8080`（eiyokeikaku） | 401（Basic認証、正常） |

### §7-2 句生成 / Turbo Streams
- `GenerateRengaJob.perform_now` で前句「白露も時雨もいたくもる山は」→ 付句生成成功
  - seed pool 3854件、Ollama 応答 約2s、`status: done`、`style_check: ok`
  - 生成句例: 「肌の秋風に心つからや」（model=qwen3:8b、author=メンタムさん）
- Action Cable WebSocket: `curl` で `101 Switching Protocols` → `{"type":"welcome"}` → ping 受信を確認。
  postgresql アダプタの LISTEN/NOTIFY エラーはログになし。
- **ブラウザでの視覚確認（フォーム送信 → show 遷移 → 自動表示）は §7-1 開通後に実施が必要**。

### §7-3 既存アプリへの影響
- keiba-web（:80）・eiyokeikaku_app（:8080）とも稼働継続。nginx reload のみで両者に変更なし。
- メモリ: 増強後 2GB / available 1.0Gi（waka-collector RSS 約96MB）。逼迫なし。

---

## 4. 受入条件の充足状況

| 条件 | 状態 |
|---|---|
| verify_shikimoku 116 pass / 0 fail 維持 | ✅（Mac mini・VPS 両方） |
| `http://163.44.114.31:8081` でアプリ表示 | ⚠️ VPS内 200 / 外部は ConoHa SG 待ち |
| 句生成で Turbo Streams 動作 | ✅ 生成成功・WS 確立確認（ブラウザ実地は SG 開通後） |
| keiba-web / eiyokeikaku_app 稼働継続 | ✅ |

---

## 5. 残タスク

1. **【人間】ConoHa コントロールパネル → セキュリティグループで TCP 8081 を許可**
   （既存の 8080 許可と同じ操作）。開通後、Mac mini から `curl -I http://163.44.114.31:8081/` で 200 を確認。
2. **【人間 or クロコ】ブラウザで §7-2 の視覚確認**（フォーム送信 → 生成中表示 → 付句自動表示）。
3. 未決事項（手順書 v1.0 §5）:
   - 8081 の外部公開に Basic 認証を付けるか（参加者に直 URL 共有想定なら不要）
   - ActiveJob を `:async` のままにするか SolidQueue へ移行するか（プロセス再起動で in-flight ジョブ消失）
   - `WAKA_OLLAMA_MODEL` を `qwen3:14b` に固定するか（依頼書背景の想定モデル）
4. 手順書 v1.0 の §3〜§6 に本結果の追加作業4件を反映（v1.1 化）。
