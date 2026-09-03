# waka-collector ConoHa VPS デプロイ手順書 v1.0（草稿・Phase 0成果物）

**作成日**: 2026-09-04
**種別**: Phase 0調査結果に基づく設計草稿（VPS上への変更は未実施）
**調査対象VPS**: ConoHa 163.44.114.31（ホストエイリアス `conoha`、rootユーザーでSSH接続確認済み）
**ベースコミット**: e5f8d9c

---

## 0. サマリ（承認判断のための要点）

| 項目 | 結果 |
|---|---|
| §1-0 RAM | **available 250MB / free 75MB — 要注意〜増強検討ライン**（詳細は1章） |
| §1-5 Tailscale | **未インストール**（想定ケースB通り）。Ollama疎通確認はPhase1後回し |
| waka-collector用ポート | **8081**（nginx）/ **3002**（Puma内部） を提案 |
| PostgreSQL認証 | 実際はpeer認証ではなく**TCP+scram-sha-256（パスワード認証）** — 依頼書の前提と異なる（重要な訂正） |
| WebSocket(Action Cable) | 既存2アプリとも**未設定**。waka-collectorのpostgresqlアダプタ用に新規で`/cable`ブロックが必要 |
| Ruby/Railsバージョン | Ruby 3.3.6でVPSと一致、追加インストール不要 |
| VPS上への変更 | **なし**（読み取り確認のみ実施） |

---

## 1. VPS現状確認結果（§1）

### §1-0 リソース状況

```
Mem:  total 965Mi / used 714Mi / free 75Mi / buff-cache 339Mi / available 250Mi
Swap: total 2.0Gi / used 317Mi / free 1.7Gi
Disk: / 99G中5.5G使用（89G空き、6%）— ディスクは全く問題なし
Load average: 0.11, 0.06, 0.01（アイドル状態）
```

**判断**: 依頼書の基準表（500MB以上=不要／200-500MB=要注意／200MB未満=増強必要）に照らすと、
- `free`列（75MB）だけを見れば「増強必要」ライン
- Linuxのメモリ管理としてより実用的な`available`列（250MB、buff/cacheの回収可能分を含む）で見れば「200-500MB=要注意」ラインの下限

waka-collectorの追加見込み（依頼書想定: Puma worker1/thread5で約170-220MB）と照らすと、availableの250MBはほぼ使い切ってしまう水準。既存2アプリのPuma設定（後述）はどちらも`threads_count`のみでworkerクラスタ化はしていない（単一プロセス・スレッドのみ）ため、waka-collectorも同様に**単一プロセス・スレッド構成**にすればメモリ増分は抑えられるが、それでも**現行965MBプランでは綱渡り**。

→ **結論: 増強を推奨（要注意〜増強必要の境界）**。最低限、waka-collectorのPuma設定は`WEB_CONCURRENCY`（workers）を設定せず単一プロセス・スレッド数を絞る（例: 2〜3）ことを前提条件とする。可能であればConoHaのプランを1GB→2GBクラスへ増強するのが安全。

既存アプリの実メモリ使用量（`ps aux`実測）:
- keiba-web (puma 7.2.0, port 3000): RES 135MB
- eiyokeikaku_app (puma 8.0.1, port 3001, solid_queue同居): RES 56MB（+ solid_queue子プロセス、COWで共有分あり）

既存Puma設定はどちらも`config/puma.rb`に`workers`指定なし（systemdユニットファイルにもworker/threads指定なし＝依頼書のgrep対象は空振り。実体は各アプリの`config/puma.rb`にあった）:
```ruby
threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count
bind "tcp://127.0.0.1:#{ENV.fetch('PORT', 3000)}"
```

---

### §1-5 Tailscale / Ollama疎通

```
$ which tailscale       → NOT FOUND
$ tailscale status      → command not found
$ dpkg -l | grep tailscale → パッケージなし
```

**結果: 未インストール（依頼書想定のケースB）**。Ollama疎通確認（`curl http://100.71.107.6:11434/api/tags`）はTailscale導入後（Phase 1完了後）に実施する。Phase 1手順書に以下を追加する必要がある:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → ブラウザでauthorize（Nobusonさんが実施）
```

---

### §1-1 使用中ポート・既存アプリ構成

| ポート | 用途 | プロセス |
|---|---|---|
| 22 | SSH | sshd |
| 80 | Nginx（keiba-web公開） | nginx |
| 8080 | Nginx（eiyokeikaku_app、Basic認証あり） | nginx |
| 3000 | Puma（keiba-web、内部のみ） | puma 7.2.0 |
| 3001 | Puma（eiyokeikaku_app、内部のみ、solid_queue同居） | puma 8.0.1 |
| 5432 | PostgreSQL（127.0.0.1のみ） | postgres |

systemdサービス: `keiba-web.service`、`eiyokeikaku.service`（どちらも`/etc/systemd/system/`、`Type=simple`、`Restart=always`、rbenv 3.3.6経由）。

**waka-collector用ポート提案**:
- Puma内部ポート: **3002**（3000/3001の次番）
- Nginx公開ポート: **8080は既存アプリと衝突するため使えない。新規で8081を提案**（80/8080ともに既存アプリが専有しており、パスベースでの同居は非推奨。ドメイン名が使えるなら`server_name`分離の方が将来的にクリーン）

---

### §1-2 既存Nginx設定

`/etc/nginx/sites-enabled/`に2ファイル（`keiba-web`, `eiyokeikaku`、どちらも`sites-available`へのシンボリックリンク）。

```nginx
# keiba-web (port 80, server_name "_" = 全ホスト名でマッチ)
server {
    listen 80;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}

# eiyokeikaku (port 8080, Basic認証あり)
server {
    listen 8080;
    server_name _;
    auth_basic "Eiyokeikaku Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd_eiyokeikaku;
    location / {
        proxy_pass http://127.0.0.1:3001;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

**重要**: どちらの既存設定にも**Action Cable（WebSocket）proxy設定は存在しない**（keiba-webもeiyokeikaku_appもWebSocketを使用していないため）。waka-collectorはTurbo Streams（Action Cable、postgresqlアダプタ）を使うため、`/cable`ブロックは既存設定からの流用ではなく**新規設計**が必要。

---

### §1-3 nftablesルール

```
tcp dport 22 accept
tcp dport 80 accept
tcp dport 443 accept
tcp dport 8080 accept
```
（fail2ban相当の`f2b-table`がSSHブルートフォース対策として別途稼働中、22番のみ対象）

**waka-collector用に追加が必要**: `tcp dport 8081 accept`

---

### §1-4 PostgreSQL

```
DB一覧: eiyokeikaku_app_production / eiyokeikaku_app_production_cable /
        eiyokeikaku_app_production_cache / eiyokeikaku_app_production_queue /
        keiba_web_production / postgres / template0 / template1

ロール: eiyokeikaku_app (Create DB) / keiba_user / postgres (Superuser)
```

**pg_hba.conf実測**（依頼書の前提「Peer認証」に対する訂正）:
```
local   all  postgres                       peer
local   all  all                            peer
host    all  all   127.0.0.1/32            scram-sha-256
host    all  all   ::1/128                 scram-sha-256
```
peer認証はUNIXソケット経由の`postgres`ユーザー操作（`sudo -u postgres psql`等）にのみ適用される。**Railsアプリからの接続は実際には`host`行が使われ、TCP(127.0.0.1)+パスワード認証（scram-sha-256）**。既存2systemdファイルにも`DATABASE_PASSWORD`/`EIYOKEIKAKU_APP_DATABASE_PASSWORD`環境変数が設定されており、これを裏付ける。

→ **DATABASE_URLは不要**（waka-collectorの`config/database.yml`は既にusername/host/passwordを個別指定する構成で、`WAKA_COLLECTOR_DATABASE_PASSWORD`環境変数を読む設計になっている。既存の流儀と一致）。

**waka-collector用DB/ユーザー設計**（既存の命名規則`<app>_production` / `<app>_user or <app>`に準拠、waka-collectorの`config/database.yml`は既に`waka_collector_production` / `waka_collector`ユーザーを前提にしている）:
```sql
CREATE USER waka_collector WITH PASSWORD '<生成パスワード>';
CREATE DATABASE waka_collector_production OWNER waka_collector;
```
Action Cableはpostgresqlアダプタ（LISTEN/NOTIFY、`config/cable.yml`で設定済み）を使うため、eiyokeikaku_appのような`_cable`/`_cache`/`_queue`分割DBは**不要**（単一DBで完結）。

---

## 2. デプロイ設計（§2）

### §2-1 Nginx server block設計

```nginx
server {
    listen 8081;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Action Cable（Turbo Streams、postgresqlアダプタ）用WebSocket proxy
    # 既存2アプリにはこのブロックは存在しない（新規設計）
    location /cable {
        proxy_pass http://127.0.0.1:3002/cable;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

既存設定との差分: `listen`ポート・`proxy_pass`ポートの変更に加え、**`/cable`ブロックが完全新規**（既存2アプリの設定をコピーしても得られない）。

### §2-2 systemdサービスファイル設計

```ini
[Unit]
Description=Puma HTTP Server for waka-collector
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=/var/www/waka-collector
Environment=HOME=/root
Environment=PATH=/root/.rbenv/versions/3.3.6/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=GEM_HOME=/root/.rbenv/versions/3.3.6/lib/ruby/gems/3.3.0
Environment=GEM_PATH=/root/.rbenv/versions/3.3.6/lib/ruby/gems/3.3.0
Environment=RAILS_ENV=production
Environment=PORT=3002
Environment=RAILS_MAX_THREADS=3
Environment=WAKA_COLLECTOR_DATABASE_PASSWORD=<生成パスワード>
Environment=RAILS_MASTER_KEY=<config/master.keyの内容>
Environment=OLLAMA_URL=http://100.71.107.6:11434
ExecStart=/root/.rbenv/versions/3.3.6/bin/bundle exec puma -C config/puma.rb
Restart=always

[Install]
WantedBy=multi-user.target
```

既存2ユニットと同じ構造（Type=simple, rbenv 3.3.6, Restart=always）。**追加点はOLLAMA_URLのみ**。`config/puma.rb`はworkers未指定のままとし（§1-0のRAM制約を踏まえ、cluster化しない）、`RAILS_MAX_THREADS`はデフォルト3のまま様子見。

現状`config/environments/production.rb`は`queue_adapter`が未設定＝デフォルトの`:async`（インメモリ）。GenerateRengaJob（Ollama呼び出しを含む非同期処理）はこの設定で単一Pumaプロセス内のスレッドプールで実行される。プロセス再起動でジョブが失われる点は許容範囲か、既存のSolidQueue採用（eiyokeikaku_app方式）に合わせるかは**Phase1着手前に要判断**（本Phase0では現状維持を前提に設計）。

### §2-3 環境変数・credentials設計

| 変数名 | 値 | 設定場所 |
|---|---|---|
| RAILS_ENV | production | systemd |
| PORT | 3002 | systemd |
| RAILS_MAX_THREADS | 3 | systemd |
| WAKA_COLLECTOR_DATABASE_PASSWORD | 生成パスワード | systemd |
| RAILS_MASTER_KEY | config/master.keyの内容 | systemd |
| OLLAMA_URL | http://100.71.107.6:11434 | systemd |
| DATABASE_URL | **不要**（database.ymlのusername/host/password個別指定と既存アプリの流儀に合わせる、§1-4参照） | — |

---

## 3. 既存手順書との差分整理（§3）

| 手順 | eiyokeikaku_app | waka-collector | 差分 |
|---|---|---|---|
| PostgreSQL作成 | CREATE USER/DATABASE | 同様 | DB分割（cable/cache/queue）なし。単一DBのみ |
| Nginx設定 | port 8080、Basic認証あり | **port 8081**、Basic認証は要検討（平野連歌会参加者向け公開の可否次第） | `/cable`ブロック新規追加、listen port変更 |
| systemd | 基本形+SOLID_QUEUE_IN_PUMA | 基本形+**OLLAMA_URL** | 環境変数の中身が異なる（Job backendがasync vs solid_queue） |
| デプロイフロー | git pull→bundle→migrate→restart | 同様 | なし |
| nftables | 8080追加済み | **8081追加が必要** | ポート番号のみ差分 |
| DB認証 | TCP+scram-sha-256（DATABASE_PASSWORD） | 同様 | なし（依頼書の「Peer認証」前提は誤りと判明、実態はTCPパスワード認証） |

---

## 4. 前提条件・実施フロー（§4、Phase 1向け）

### 4-1 前提条件
- [ ] Tailscale導入・authorize完了（VPS↔Mac mini間）
- [ ] `curl http://100.71.107.6:11434/api/tags`でOllama疎通確認
- [ ] Mac mini側`bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail
- [ ] ConoHa VPSプランの増強要否をNobusonさんと最終判断（§1-0参照、現行965MBは綱渡り）

### 4-2 VPS側初回セットアップ
1. PostgreSQL: `waka_collector`ユーザー・`waka_collector_production`DB作成
2. `git clone`（`/var/www/waka-collector`）→ `bundle install --deployment` (rbenv 3.3.6)
3. `config/master.key`を安全な経路で配置（scp等、リポジトリには含めない）
4. `RAILS_ENV=production bundle exec rails db:create db:migrate`
5. systemdユニット配置（2-2案） → `systemctl daemon-reload && systemctl enable --now waka-collector`
6. Nginx設定配置（2-1案） → `nginx -t && systemctl reload nginx`
7. nftables: `tcp dport 8081 accept`をルールに追加、永続化（現行ルールセットの管理方法に合わせて追記場所を確認する）

### 4-3 動作確認
```bash
curl -I http://163.44.114.31:8081/
# ブラウザで http://163.44.114.31:8081/ にアクセスし、Turbo Streams (Action Cable)が
# ブラウザ開発者ツールのNetworkタブでWSS/WS接続確立していることを確認
```

### 4-4 トラブルシューティング
| 症状 | 想定原因 | 対処 |
|---|---|---|
| ページは表示されるがリアルタイム更新されない | `/cable`のNginx WebSocketプロキシ設定漏れ、または`Upgrade`ヘッダ未転送 | nginx設定の`location /cable`ブロックを再確認 |
| 句生成ジョブが動かない/Ollama応答なし | Tailscale未接続、またはOLLAMA_URL誤り | `tailscale status`、VPSから`curl $OLLAMA_URL/api/tags`で疎通確認 |
| Puma起動失敗（メモリ不足でOOM Killer） | §1-0のRAM逼迫が的中 | `journalctl -u waka-collector`でOOM killログ確認、VPSプラン増強を検討 |
| DB接続エラー（password authentication failed） | `WAKA_COLLECTOR_DATABASE_PASSWORD`とDB作成時のパスワード不一致 | systemd環境変数とPostgreSQLロールのパスワードを再照合 |

---

## 5. 承認が必要な未決事項

1. **RAMプラン増強の要否**（§1-0: available 250MB、waka-collector追加分約170-220MBでほぼ枯渇。増強推奨だが最終判断はNobusonさん）
2. **8081ポートの外部公開方式**（Basic認証を付けるか、平野連歌会参加者に直接URLを共有する想定か）
3. **ActiveJobのqueue_adapter**（現状:async維持か、eiyokeikaku_app同様SolidQueueへ移行するか。Phase1着手前に決定）

VPS上の既存ファイルへの変更は本Phase0では一切実施していません（読み取りコマンドのみ）。
