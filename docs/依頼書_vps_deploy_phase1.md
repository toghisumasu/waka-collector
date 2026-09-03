# 依頼書 waka-collector ConoHa VPS デプロイ Phase 1

**担当**: クロコさん（Claude Code）
**起票**: Claude.ai（其の◯◯）
**種別**: Phase 1（VPS実デプロイ・複数コミット可）
**ベースコミット**: b1ab4fc（vps_deploy_procedure_v1.0.md コミット後）
**前提**: `docs/vps_deploy_procedure_v1.0.md` 承認済み

---

## 背景と目標

平野連歌会での披露に向けて waka-collector を ConoHa VPS
（163.44.114.31）に初回デプロイする。

**技術構成**:
```
参加者ブラウザ → Nginx（VPS port 80/8081）→ Puma（VPS port 3002）
                                               ↓ Tailscale VPN
                                     Ollama qwen3:14b（Mac mini 100.71.107.6）
```

**Phase 0調査で確定した情報**:
- VPS: 2GB RAM / 3Core / Ubuntu（プラン変更済み）
- keiba-web: port 3000（Puma）/ port 80（Nginx）
- eiyokeikaku_app: port 3001（Puma）/ port 8080（Nginx）
- waka-collector: port 3002（Puma）/ port 8081（Nginx）← 今回
- PostgreSQL: TCP + scram-sha-256（パスワード認証、host: 127.0.0.1）
- Ruby: 3.3.6（VPS・Mac mini一致）
- Tailscale: **未インストール**（今回インストール）
- Mac mini Tailscale IP: `100.71.107.6`

---

## やること

### §0 事前確認（Mac mini側）

```bash
bundle exec ruby script/verify_shikimoku.rb
# → 116 pass / 0 fail を確認
```

---

### §1 Tailscaleインストールと疎通確認

#### §1-1 VPSにTailscaleインストール

```bash
ssh conoha
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

`tailscale up` 実行後にブラウザ認証URLが表示される。
**NobusonさんにそのURLを伝え、ブラウザでauthorizeしてもらう**。

#### §1-2 疎通確認

```bash
# VPS上で
curl http://100.71.107.6:11434/api/tags
# → qwen3:14bを含むモデル一覧が返れば成功
```

疎通成功を確認してから次のステップへ進む。

---

### §2 PostgreSQL設定

```bash
ssh conoha
sudo -u postgres psql
```

```sql
CREATE USER waka_user WITH PASSWORD '任意の強いパスワード';
CREATE DATABASE waka_collector_production OWNER waka_user;
GRANT ALL PRIVILEGES ON DATABASE waka_collector_production TO waka_user;
\q
```

パスワードは後の環境変数設定で使用するため記録しておく。

---

### §3 アプリケーションのデプロイ

#### §3-1 git clone

```bash
ssh conoha
cd /var/www
git clone https://github.com/toghisumasu/waka-collector.git
cd waka-collector
```

#### §3-2 Ruby・bundler確認

```bash
ruby -v  # 3.3.6であること
bundle install --deployment --without development test
```

#### §3-3 環境変数・credentials設定

`/var/www/waka-collector/.env.production`（またはsystemd環境変数として設定）:

```
RAILS_ENV=production
OLLAMA_URL=http://100.71.107.6:11434
DB_HOST=127.0.0.1
DB_USERNAME=waka_user
DB_PASSWORD=§2で設定したパスワード
DB_NAME=waka_collector_production
```

`config/master.key` をMac miniから安全な方法でVPSに転送する:

```bash
# Mac mini側で
scp config/master.key conoha:/var/www/waka-collector/config/master.key
```

#### §3-4 database.ymlの確認

`config/database.yml` のproduction設定が以下の形式になっているか確認する:

```yaml
production:
  adapter: postgresql
  host: 127.0.0.1
  database: waka_collector_production
  username: waka_user
  password: <%= ENV['DB_PASSWORD'] %>
```

異なる場合は修正してコミットする（D-33-1に従いdiff確認後）。

#### §3-5 DB migrate・assets precompile

```bash
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails assets:precompile
```

---

### §4 systemdサービス設定

`/etc/systemd/system/waka-collector.service`:

```ini
[Unit]
Description=waka-collector Rails app
After=network.target postgresql.service

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/waka-collector
Environment="RAILS_ENV=production"
Environment="OLLAMA_URL=http://100.71.107.6:11434"
Environment="DB_HOST=127.0.0.1"
Environment="DB_USERNAME=waka_user"
Environment="DB_PASSWORD=§2で設定したパスワード"
Environment="DB_NAME=waka_collector_production"
Environment="RAILS_MASTER_KEY=config/master.keyの内容"
ExecStart=/usr/local/bin/bundle exec puma -C config/puma.rb
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable waka-collector
sudo systemctl start waka-collector
sudo systemctl status waka-collector
```

---

### §5 Nginx設定

`/etc/nginx/sites-available/waka-collector`:

```nginx
server {
    listen 8081;
    server_name 163.44.114.31;

    root /var/www/waka-collector/public;

    location / {
        proxy_pass http://localhost:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }

    # Action Cable（Turbo Streams）WebSocket proxy
    location /cable {
        proxy_pass http://localhost:3002/cable;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /assets {
        expires max;
        add_header Cache-Control public;
    }
}
```

```bash
sudo ln -s /etc/nginx/sites-available/waka-collector \
           /etc/nginx/sites-enabled/waka-collector
sudo nginx -t  # 設定確認
sudo systemctl reload nginx
```

---

### §6 nftablesでポート開放

```bash
# 既存ルールを確認してから追加
sudo nft list ruleset

# port 8081を追加（既存の8080追加と同じパターンで）
sudo nft add rule inet filter input tcp dport 8081 accept

# 再起動後も有効にする（既存の設定ファイルに追記）
# /etc/nftables.conf を確認して同様に追記
```

---

### §7 動作確認

#### §7-1 ブラウザアクセス

```
http://163.44.114.31:8081
```

ログインページまたはトップページが表示されることを確認する。

#### §7-2 Turbo Streams動作確認

句生成リクエストを送信し、以下を確認する:
- リクエスト後即座にshowページへ遷移すること
- 「生成中」表示が出ること
- 35-55秒後に句が自動表示されること（Ollamaが返す）

#### §7-3 既存アプリへの影響確認

```
http://163.44.114.31      # keiba-web（port 80）
http://163.44.114.31:8080 # eiyokeikaku_app
```

両方が引き続き正常動作することを確認する。

---

## やらないこと

- SSL/HTTPS対応（今回スコープ外・将来対応）
- ドメイン設定（今回スコープ外）
- Sidekiq/Redis導入（将来の本番強化時に対応）
- waka-collector以外のアプリ設定変更

---

## 特記事項

**§1-1のTailscale authorize はNobusonさんの操作が必要**。
URLが表示されたらClaude.aiスレッドに知らせて、
Nobusonさんにブラウザで操作してもらう。

---

## 受入条件

- `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- `http://163.44.114.31:8081` でアプリが表示される
- 句生成でTurbo Streamsが動作する（自動更新）
- keiba-web（port 80）・eiyokeikaku_app（port 8080）が引き続き稼働

---

## 承認ゲート

§7の動作確認結果をClaude.aiスレッドに報告すること。
披露準備（説明資料等）はその後に着手する。

---

## 参照資料

- `docs/vps_deploy_procedure_v1.0.md`（Phase 0手順書草稿）
- `docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`（既存アプリの実績手順）
- Phase 1実装コミット: f8f86ed〜e5f8d9c（非同期化実装）
