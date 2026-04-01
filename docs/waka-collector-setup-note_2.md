# waka-collector セットアップ学習ノート

## 概要

Ruby on Rails + PostgreSQL で和歌収集Webアプリを構築する手順。  
keiba-webと同じ環境（システムRuby + `vendor/bundle`方式）を前提とする。

---

## 1. 事前準備：GitHubリポジトリ作成

1. GitHub.com で `New repository`
2. 名前: `waka-collector`、Public で作成
3. README は**追加しない**（Railsが自動生成するため）

---

## 2. rails new

```bash
rails new waka-collector --database=postgresql
cd ~/waka-collector
```

**ポイント：** `rails new` 時点で `git init` まで自動的に完了する。

---

## 3. gemのインストール（vendor/bundle方式）

システムのgemディレクトリ（`/var/lib/gems`）は一般ユーザーに書き込み権限がないため、プロジェクト内にgemをインストールする。

```bash
bundle config set --local path 'vendor/bundle'
bundle install
```

`.bundle/config` に以下が記録される：

```yaml
BUNDLE_PATH: "vendor/bundle"
```

---

## 4. .gitignore の整備

`vendor/bundle` と `config/database.yml` をGit管理対象から除外する。

```bash
echo '/vendor/bundle' >> .gitignore
echo '/config/database.yml' >> .gitignore
```

確認：

```bash
grep vendor .gitignore
grep database .gitignore
```

---

## 5. error_highlight の競合対処

Rails 7.2系では `error_highlight` gemがシステム側と競合してrailsコマンドが失敗することがある。

**症状：**
```
You have already activated error_highlight 0.3.0,
but your Gemfile requires error_highlight 0.7.0.
```

**対処：** Gemfile の該当行をコメントアウトする。

```ruby
# gem "error_highlight", ">= 0.4.0", platforms: [ :ruby ]
```

その後 `bundle install` を再実行する。

---

## 6. RSpec導入

```ruby
# Gemfile の group :development, :test do ブロックに追加
gem "rspec-rails"
gem "factory_bot_rails"
```

```bash
bundle install
bundle exec rails generate rspec:install
```

**生成されるファイル：**

- `.rspec`
- `spec/spec_helper.rb`
- `spec/rails_helper.rb`

**注意：** railsコマンドは必ず `bundle exec` を付けて実行する。

---

## 7. database.yml の設定

`config/database.yml` を編集する。パスワードは直書き（開発環境）。  
**公開リポジトリのため `.gitignore` に追加して管理すること。**

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  username: keiba_user
  password: keiba_pass
  host: localhost

development:
  <<: *default
  database: waka_collector_development

test:
  <<: *default
  database: waka_collector_test

production:
  <<: *default
  database: waka_collector_production
  password: <%= ENV["DATABASE_PASSWORD"] %>
```

サンプルファイルをGit管理用に作成：

```bash
cp config/database.yml config/database.yml.sample
```

`database.yml.sample` はパスワードを空にしてコミットする。

---

## 8. データベース作成

```bash
bundle exec rails db:create
```

成功すると以下が表示される：

```
Created database 'waka_collector_development'
Created database 'waka_collector_test'
```

---

## 9. SSH鍵の作成とGitHub登録

```bash
ssh-keygen -t ed25519 -C "メールアドレス"
cat ~/.ssh/id_ed25519.pub
```

表示された公開鍵を GitHub → Settings → SSH keys → New SSH key に登録する。

接続確認：

```bash
ssh -T git@github.com
# Hi ユーザー名! You've successfully authenticated... と表示されればOK
```

---

## 10. 最初のコミットとpush

```bash
git add .
git status  # config/database.yml が含まれていないことを確認
git commit -m "Initial commit: Rails new with RSpec, PostgreSQL setup"
git remote add origin git@github.com:ユーザー名/waka-collector.git
git push -u origin main
```

---

## 11. モデル設計の考え方

### 和歌のデータ構造

和歌は上の句（五七五）と下の句（七七）を**別カラムで管理**する。

理由：
- 句ごとの分析（歌枕・季語など）が可能になる
- 連歌的な展開（別の上の句と下の句の組み合わせ）に対応できる
- 一体として扱いたい場合は結合すればよい

### 音節（五七五）の扱い

DBでの音節数強制はしない。理由：

- 字余りは万葉集から存在する正統な表現
- 入力者の判断を尊重すべき

単語の切れ目にスペースを入れる運用とする（強制はしない）。  
例：`春はあけぼの やうやう白く なりゆく山ぎは`

### カラム設計

| カラム名 | 型 | 内容 |
|---|---|---|
| `upper_phrase` | string | 上の句（五七五） |
| `lower_phrase` | string | 下の句（七七） |
| `author` | string | 作者 |
| `source` | string | 出典（古今集など） |
| `era` | string | 時代 |
| `notes` | text | 備考・解説 |

---

## 12. モデル生成とマイグレーション

```bash
bundle exec rails generate model Waka \
  upper_phrase:string \
  lower_phrase:string \
  author:string \
  source:string \
  era:string \
  notes:text
```

**生成されるファイル：**

- `db/migrate/YYYYMMDDHHMMSS_create_wakas.rb`
- `app/models/waka.rb`
- `spec/models/waka_spec.rb`（RSpec）
- `spec/factories/wakas.rb`（factory_bot）

マイグレーション実行：

```bash
bundle exec rails db:migrate
```

---

## 13. 今後の開発フェーズ整理

### フェーズ1: CRUD基本機能（次のステップ）

- `WakasController` の作成
- ルーティング設定（`config/routes.rb`）
- ビュー作成（index / show / new / edit）
- バリデーション追加

### フェーズ2: 検索・絞り込み機能

- 作者検索
- 時代・出典による絞り込み
- フリーワード検索

### フェーズ3: テスト

- RSpecによるモデルテスト
- コントローラテスト
- factory_botでテストデータ作成

### フェーズ4: AWSデプロイ

- AWSアカウントセットアップ完了
- EC2環境構築
- アプリ公開

---

## 14. AWS デプロイ計画

### 全体の流れ

```
ローカル開発（WSL2）
    ↓ アプリ完成後
AWSアカウントセットアップ完了
    ↓
EC2インスタンス作成
    ↓
サーバー環境構築（Ruby / Rails / PostgreSQL / Nginx）
    ↓
アプリデプロイ
    ↓
独自ドメイン・SSL対応（任意）
```

### 構成案（最小コスト）

EC2 1台にすべて同居させる構成：

```
EC2 t3.micro（大阪リージョン: ap-northeast-3）
├── Rails アプリ
├── PostgreSQL（RDSは使わず直接インストール）
└── Nginx（Webサーバー）
```

RDSを使わないことで月額費用を抑える。

### 費用目安

| サービス | 内容 | 目安費用 |
|---|---|---|
| EC2 t3.micro | Railsサーバー | 約$10/月 |
| Route 53 | ドメイン管理 | 約$1/月 |
| ACM | SSL証明書 | 無料 |
| **合計** | | **約$11/月（約1,600円）** |

### 無料枠について

新規AWSアカウントは登録から12ヶ月間、EC2 t2.microが750時間/月無料。  
アカウントセットアップ完了後に確認する：

```
AWSコンソール → Billing and Cost Management → 無料利用枠
```

### AWSアカウントセットアップ手順

アプリ完成後に以下を完了させる：

1. クレジットカード情報の登録
2. 本人確認
3. サポートプランの選択 → **Basicプラン（無料）** を選ぶ

### 注意事項

- 使用しないEC2インスタンスは**停止**しておく（停止中はEC2料金発生しない）
- RDSは停止中も料金が発生するため今回は使用しない
- 請求アラートを設定して予期しない課金を防ぐ

---

## Railsの重要な概念メモ

**Convention over Configuration（設定より規約）**  
ファイルの置き場所・命名規則に従うと自動的に動く。  
`rails routes`、`rails console` を使って裏で何が起きているかを確認する習慣をつける。

**bundle exec について**  
システムのgemと競合を避けるため、railsコマンドは常に `bundle exec` を付ける。  
→ `bundle exec rails ...`

**マイグレーションについて**  
COBOLのレコード定義と違い、カラムの追加・変更は後からマイグレーションで対応できる。  
最初はシンプルな設計で始め、必要になったら追加する。

**t.timestamps について**  
マイグレーションの `t.timestamps` は `created_at` と `updated_at` を自動追加する。  
更新日時の管理が自動化される。
