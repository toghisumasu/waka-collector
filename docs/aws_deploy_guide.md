# Rails アプリ AWS EC2 デプロイ手順書

対象アプリ: waka-collector（Rails 7.2 + PostgreSQL + Nginx）  
作成日: 2026-04-15  
環境: Ubuntu 24.04 LTS / t3.micro / 大阪リージョン（ap-northeast-3）

---

## 目次

1. [AWSアカウント準備](#1-awsアカウント準備)
2. [EC2インスタンス作成](#2-ec2インスタンス作成)
3. [SSH接続](#3-ssh接続)
4. [サーバー初期設定](#4-サーバー初期設定)
5. [Ruby・Railsインストール](#5-rubyrailsインストール)
6. [PostgreSQL設定](#6-postgresql設定)
7. [アプリのデプロイ](#7-アプリのデプロイ)
8. [Nginx設定](#8-nginx設定)
9. [Railsの起動](#9-railsの起動)
10. [動作確認](#10-動作確認)
11. [次のステップ](#11-次のステップ)
12. [トラブルシューティング](#12-トラブルシューティング)

---

## 1. AWSアカウント準備

### アカウント有効化の確認

新規アカウント作成後、AWSコンソールにログインすると「Complete your account setup」ページが表示される場合がある。クレジットカード登録・本人確認が完了していないと EC2 が使えない。

1. [https://aws.amazon.com](https://aws.amazon.com) → 「Sign in to console」
2. 「Complete your AWS registration」が表示された場合は完了させる
3. 有効化完了メールが届いたらコンソールにアクセスできる

> **注意**: 有効化には最大24時間かかることがある。メールボックス（スパムフォルダも）を確認すること。

### リージョンの設定

コンソール右上のリージョン選択から **アジアパシフィック（大阪）ap-northeast-3** を選択する。  
日本からのアクセスは大阪が最も低レイテンシ。

---

## 2. EC2インスタンス作成

### インスタンスの起動

AWSコンソール → EC2 → 「インスタンスを起動」

#### 設定項目

| 項目 | 設定値 | 備考 |
|------|--------|------|
| 名前 | `waka-collector` | 任意 |
| OS | Ubuntu Server 24.04 LTS | 無料利用枠対象 |
| アーキテクチャ | 64ビット (x86) | |
| インスタンスタイプ | t3.micro | 無料利用枠対象 |
| キーペア | 新規作成 | 後述 |
| ストレージ | 8GB (gp3) | デフォルト |

#### キーペアの作成

「新しいキーペアの作成」をクリック。

| 項目 | 設定値 |
|------|--------|
| キーペア名 | `waka-collector-key` |
| タイプ | RSA |
| 形式 | `.pem`（OpenSSH用、WSL2やMacで使用） |

> **重要**: `.pem` ファイルは自動でダウンロードされる。**再ダウンロードは不可**なので安全な場所に保管すること。

#### セキュリティグループ（ファイアウォール）

以下の3つにチェックを入れる：

- ☑ SSHトラフィックを許可（ポート22）
- ☑ HTTPSトラフィックを許可（ポート443）
- ☑ HTTPトラフィックを許可（ポート80）

「インスタンスを起動」ボタンをクリック。

#### パブリックIPの確認

インスタンス一覧で起動したインスタンスの **パブリックIPv4** を控えておく。  
例: `15.152.49.240`

---

## 3. SSH接続

### WSL2（Windows）からの場合

ダウンロードした `.pem` ファイルをWSL2にコピーする。

```bash
# Windowsのダウンロードフォルダからコピー
cp /mnt/c/Users/（ユーザー名）/Downloads/waka-collector-key.pem ~/.ssh/

# パーミッションを設定（必須。これがないとSSH接続エラーになる）
chmod 600 ~/.ssh/waka-collector-key.pem
```

> **注意**: `chmod 600` を忘れると `WARNING: UNPROTECTED PRIVATE KEY FILE!` エラーが出て接続できない。

### SSH接続

```bash
ssh -i ~/.ssh/waka-collector-key.pem ubuntu@（パブリックIP）
```

初回接続時に以下のメッセージが表示される：

```
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

`yes` と入力してEnter。以降はこのメッセージは表示されない。

---

## 4. サーバー初期設定

### パッケージの更新

```bash
sudo apt update && sudo apt upgrade -y
```

アップグレード後、カーネル更新が含まれる場合は再起動が推奨される：

```bash
sudo reboot
```

再起動後はSSH接続が切れるので、1〜2分待ってから再接続する。

### 必要パッケージのインストール

```bash
sudo apt install -y git curl libssl-dev libreadline-dev zlib1g-dev libpq-dev \
  nodejs npm nginx postgresql postgresql-contrib libyaml-dev
```

> **詰まりポイント**: `libyaml-dev` を忘れると、後の `bundle install` で `yaml.h not found` エラーが発生する。最初から含めておくこと。

インストール確認：

```bash
git --version && nginx -v && psql --version && node --version && npm --version
```

---

## 5. Ruby・Railsインストール

### Rubyのインストール

```bash
sudo apt install -y ruby-full
ruby --version
```

### Bundlerのインストール

```bash
sudo gem install bundler
bundler --version
```

---

## 6. PostgreSQL設定

### DBユーザーとデータベースの作成

```bash
sudo -u postgres psql -c "CREATE USER （DBユーザー名） WITH PASSWORD '（パスワード）';"
sudo -u postgres psql -c "CREATE DATABASE （DB名）_production OWNER （DBユーザー名）;"
```

waka-collectorの場合：

```bash
sudo -u postgres psql -c "CREATE USER keiba_user WITH PASSWORD 'keiba_pass';"
sudo -u postgres psql -c "CREATE DATABASE waka_collector_production OWNER keiba_user;"
```

> **注意**: `rails db:create` を実行するとエラーが出ることがあるが、PostgreSQLユーザーにCREATEDB権限がない場合は正常。手動でDBを作成済みなので問題ない。

---

## 7. アプリのデプロイ

### アプリディレクトリの作成

```bash
cd /var/www
sudo mkdir waka-collector
sudo chown ubuntu:ubuntu waka-collector
```

### GitHubからクローン

```bash
git clone https://github.com/（GitHubアカウント）/（リポジトリ名）.git waka-collector
cd waka-collector
```

### database.yml の作成

`.gitignore` に含まれているため、手動で作成する：

```bash
vi config/database.yml
```

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  host: localhost
  username: keiba_user
  password: keiba_pass

development:
  <<: *default
  database: waka_collector_development

test:
  <<: *default
  database: waka_collector_test

production:
  <<: *default
  database: waka_collector_production
```

> **詰まりポイント**: `production` セクションのみ記述すると、Rails起動時に `The 'development' database is not configured` エラーが出る。`default` / `development` / `test` / `production` の4セクションを必ず記述すること。

### master.key のコピー

`config/master.key` も `.gitignore` に含まれているため、ローカルからコピーする。  
**WSL2側のターミナルで実行する**：

```bash
scp -i ~/.ssh/waka-collector-key.pem config/master.key ubuntu@（パブリックIP）:/var/www/waka-collector/config/
```

### gemのインストール

```bash
bundle config set --local path 'vendor/bundle'
bundle install
```

> **詰まりポイント**: `yaml.h not found` エラーが出た場合は `sudo apt install -y libyaml-dev` を実行してから再度 `bundle install`。

### データベースのマイグレーション

```bash
bundle exec rails db:migrate RAILS_ENV=production
```

### アセットのプリコンパイル

```bash
bundle exec rails assets:precompile RAILS_ENV=production SECRET_KEY_BASE=$(bundle exec rails secret)
```

### production.rb の設定

SSL強制をオフにする（SSL証明書を設定するまでの暫定対応）：

```bash
vi config/environments/production.rb
```

以下の行を変更：

```ruby
# 変更前
config.force_ssl = true

# 変更後
config.force_ssl = false
```

> **詰まりポイント**: `force_ssl = true` のままだと、HTTPでアクセスした際にHTTPSへリダイレクトされ、SSL証明書がない状態では `ERR_CONNECTION_REFUSED` になる。必ずfalseに変更すること。

---

## 8. Nginx設定

### サイト設定ファイルの作成

```bash
sudo vi /etc/nginx/sites-available/waka-collector
```

```nginx
server {
    listen 80;
    server_name （パブリックIP またはドメイン名）;

    root /var/www/waka-collector/public;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /assets {
        expires max;
        add_header Cache-Control public;
    }
}
```

### デフォルトサイトの無効化

```bash
sudo rm /etc/nginx/sites-enabled/default
```

> **詰まりポイント**: デフォルトサイトを削除しないと、Nginxのデフォルトページ（"Welcome to nginx!"）が表示され続ける。必ず削除すること。

### 設定の有効化と起動

```bash
sudo ln -s /etc/nginx/sites-available/waka-collector /etc/nginx/sites-enabled/
sudo nginx -t       # 設定ファイルの構文チェック
sudo systemctl restart nginx
```

---

## 9. Railsの起動

### 動作確認（起動前テスト）

```bash
SECRET_KEY_BASE=$(bundle exec rails secret) bundle exec rails runner "puts 'OK'" RAILS_ENV=production
```

`OK` と表示されれば正常。

### Railsサーバーの起動

```bash
cd /var/www/waka-collector
SECRET_KEY_BASE=$(bundle exec rails secret) bundle exec rails server -e production -b 0.0.0.0 -p 3000
```

---

## 10. 動作確認

### サーバー側での確認

別ターミナルでSSH接続し、以下を実行：

```bash
# ポートのLISTEN確認
sudo ss -tlnp | grep -E '80|3000'

# Nginxの状態確認
sudo systemctl status nginx

# Nginxを経由したアクセス確認
curl http://localhost
curl http://localhost:3000/wakas
```

### ブラウザでの確認

```
http://（パブリックIP）/wakas
```

> **注意**: アドレスバーには必ず `http://` を明示すること。ブラウザが自動で `https://` に変換する場合があり、SSL未設定の状態では接続できない。

---

## 11. 次のステップ

### ルートパスの設定

`config/routes.rb` に以下を追加：

```ruby
root 'wakas#index'
```

### Railsのサービス化（自動起動）

システム再起動後も自動でRailsが起動するよう systemd に登録する：

```bash
sudo vi /etc/systemd/system/waka-collector.service
```

```ini
[Unit]
Description=Waka Collector Rails App
After=network.target postgresql.service

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/var/www/waka-collector
Environment=RAILS_ENV=production
Environment=SECRET_KEY_BASE=（rails secretの出力値）
ExecStart=/usr/bin/bundle exec rails server -e production -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable waka-collector
sudo systemctl start waka-collector
```

### データのインポート

```bash
cd /var/www/waka-collector
bundle exec rails waka:import_kokin RAILS_ENV=production
```

### SSL証明書の設定（Let's Encrypt）

ドメインを取得した後、certbotでSSL証明書を設定する：

```bash
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d （ドメイン名）
```

---

## 12. トラブルシューティング

### `yaml.h not found`（bundle install 失敗）

```bash
sudo apt install -y libyaml-dev
bundle install
```

### `permission denied to create database`（db:create 失敗）

DBを手動で作成済みであれば無視してよい。`db:migrate` が成功すれば問題なし。

### `ERR_CONNECTION_REFUSED`（ブラウザでアクセスできない）

以下を順番に確認：

1. Nginxが起動しているか: `sudo systemctl status nginx`
2. Railsが起動しているか: `ps aux | grep rails`
3. ポートがLISTENしているか: `sudo ss -tlnp | grep -E '80|3000'`
4. デフォルトサイトが残っていないか: `ls /etc/nginx/sites-enabled/`
5. `force_ssl = false` になっているか: `grep force_ssl config/environments/production.rb`

### `The 'development' database is not configured`（Rails起動失敗）

`config/database.yml` に `development` セクションがない。`default` / `development` / `test` / `production` の4セクションを記述すること。

### `301 Moved Permanently` → https にリダイレクト（curl で確認）

`config/environments/production.rb` の `config.force_ssl` を `false` に変更してRailsを再起動。

---

## 環境情報まとめ

| 項目 | 値 |
|------|-----|
| OS | Ubuntu 24.04 LTS |
| Ruby | 3.2.3 |
| Rails | 7.2.3 |
| PostgreSQL | 16.x |
| Nginx | 1.24.0 |
| Node.js | 18.x |
| インスタンスタイプ | t3.micro |
| リージョン | ap-northeast-3（大阪） |
| アプリディレクトリ | `/var/www/waka-collector` |
| gemインストール先 | `vendor/bundle`（プロジェクトローカル） |
