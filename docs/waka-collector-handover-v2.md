# waka-collector 引き継ぎプロンプト v2

作成日: 2026-05-10

---

## プロジェクト概要

日本の勅撰和歌集を収集・検索するWebアプリ。
Rails 7.2.3 + PostgreSQL。知人への公開済み。

---

## 環境情報

### ローカル（WSL2 / Windows PC: 192.168.10.20）

| 項目 | 値 |
|------|-----|
| プロジェクトパス | `~/waka-collector` |
| Ruby | 3.3.6（rbenv） |
| Rails | 7.2.3 |
| DB | waka_collector_development（PostgreSQL） |
| .ruby-version | 3.3.6（変更済み） |
| vendor/bundle | `bundle config set --local path 'vendor/bundle'` で設定済み |

### EC2（AWS 大阪リージョン）

| 項目 | 値 |
|------|-----|
| Elastic IP | 16.209.2.5（固定） |
| インスタンスID | i-0ddf95ee536dbc8cc |
| インスタンスタイプ | t3.micro |
| OS | Ubuntu 24.04 LTS |
| Ruby | 3.2.3 |
| アプリディレクトリ | `/var/www/waka-collector` |
| DB | waka_collector_production（PostgreSQL 16.13） |
| DBユーザー | keiba_user / keiba_pass |
| EBSボリューム | 20GB（2026/05/10に8GB→20GB拡張済み） |
| ディスク使用率 | 22%（拡張後） |
| アクセスURL | http://16.209.2.5/wakas |
| systemd | waka-collector.service（自動起動設定済み） |

### SSH接続

```bash
ssh -i ~/.ssh/waka-collector-key.pem ubuntu@16.209.2.5
```

---

## DB格納データ（2026/05/10時点）

| source | 件数 | インポート元 |
|--------|------|------------|
| 古今集 | 1,102首 | 日文研DB（スクレイピング） |
| 後撰集 | 1,425首 | 日文研DB（スクレイピング） |
| 柿蔭集 | 1首 | 手動登録 |
| 角川「短歌」2026.4月号 | 1首 | 手動登録 |
| **合計** | **2,529首** | |

### データソースについて

**データはCSV/テキストファイルとして保存されていない。**
すべて日文研データベース（lapis.nichibun.ac.jp）からスクレイピングしてDBに直接インポートする方式。

- 古今集: https://lapis.nichibun.ac.jp/waka/waka_i001.html
- 後撰集: https://lapis.nichibun.ac.jp/waka/waka_i002.html

再インポートが必要な場合は以下のrakeタスクを実行：

```bash
# ローカルで実行
bundle exec rails waka:import_kokin   # 古今集
bundle exec rails waka:import_gosen   # 後撰集

# EC2で実行（長時間タスクはnohupを使う）
nohup bundle exec rails waka:import_gosen RAILS_ENV=production \
  > /tmp/import.log 2>&1 &
tail -f /tmp/import.log  # 進捗確認
```

---

## ファイル構成（主要部分）

```
~/waka-collector/
├── app/
│   ├── models/
│   │   └── waka.rb
│   ├── controllers/
│   └── views/
├── config/
│   ├── routes.rb
│   ├── database.yml       # .gitignore対象（各環境で手動作成）
│   └── master.key         # .gitignore対象（各環境で手動配置）
├── db/
│   └── migrate/
│       ├── 20260314113407_create_wakas.rb
│       ├── 20260402033912_change_waka_columns.rb
│       └── 20260412010322_add_flag_to_wakas.rb
├── lib/
│   └── tasks/
│       └── import_waka.rake   # スクレイピング・インポートタスク
└── docs/
    ├── aws_deploy_guide.md          # AWSデプロイ手順書
    ├── waka-collector-aws-deploy-memo.md  # 2026/04/15作業メモ
    ├── waka-collector-setup-note.md
    ├── waka-collector-setup-note_2.md
    └── waka-collector-test-plan.md
```

---

## DBテーブル構造（wakasテーブル）

| カラム | 内容 |
|--------|------|
| id | 主キー |
| upper_phrase_text | 上の句（本文） |
| lower_phrase_text | 下の句（本文） |
| upper_phrase_yomi | 上の句（読み） |
| lower_phrase_yomi | 下の句（読み） |
| author | 作者 |
| source | 出典（古今集・後撰集など） |
| era | 時代 |
| notes | 詞書・備考 |
| flag | 分割不確実フラグ（0:正常, 1:要確認） |

---

## リリースサイクル

```
ローカル（WSL）で開発
  ↓
git push origin main
  ↓
EC2で実行:
  ssh -i ~/.ssh/waka-collector-key.pem ubuntu@16.209.2.5
  cd /var/www/waka-collector
  git pull origin main
  bundle install（gemに変更がある場合）
  bundle exec rails db:migrate RAILS_ENV=production（マイグレーションがある場合）
  sudo systemctl restart waka-collector
```

---

## EC2管理コマンド

```bash
# サービス操作
sudo systemctl restart waka-collector
sudo systemctl status waka-collector

# ログ確認
sudo journalctl -u waka-collector -f

# DB件数確認
sudo -u postgres psql -d waka_collector_production \
  -c 'SELECT source, COUNT(*) FROM wakas GROUP BY source;'

# ディスク確認
df -h /
```

---

## 今後の課題

### 優先度：高
- [ ] 出典・時代での絞り込みUIの追加
- [ ] 作者名の表記統一・補完（後撰集は作者未詳が多い）

### 優先度：中
- [ ] 拾遺和歌集のインポート（waka_i003.html）
- [ ] SSL証明書設定（ドメイン取得後）

### 優先度：低
- [ ] journal上限設定の確認（200MB設定済みのはず）
- [ ] ルートパス設定（現在は `/wakas` でアクセス）

---

## GitHub

https://github.com/toghisumasu/waka-collector

---

## 注意事項

- EC2のdatabase.ymlはGitHub管理外。`keiba_user / keiba_pass` で設定済み
- `force_ssl = false` は暫定設定（HTTPS化後に `true` に戻す）
- 長時間のインポートタスクはSSH切断で中断リスクあり → `nohup` を使うこと
- ローカルの `.ruby-version` は `3.3.6`（元の `ruby-3.1.2` から変更済み）
- DBダンプは `sudo -u postgres pg_dump` を使う（Peer認証のため）

---

*このプロンプトを新スレッドの最初に貼り付けて作業を継続してください。*
