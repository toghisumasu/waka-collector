# waka-collector AWS デプロイ作業まとめ

作業日: 2026-04-15

---

## 環境情報

| 項目 | 値 |
|------|-----|
| EC2 パブリックIP | 15.152.49.240 |
| EC2 プライベートIP | 172.31.41.97 |
| リージョン | ap-northeast-3（大阪） |
| OS | Ubuntu 24.04.4 LTS |
| Ruby | 3.2.3 |
| Rails | 7.2.3 |
| PostgreSQL | 16.13 |
| アプリディレクトリ | `/var/www/waka-collector` |
| SSHキー | `~/.ssh/waka-collector-key.pem` |

---

## 作業前の状態

- EC2インスタンス: 起動済み
- アプリ: `/var/www/waka-collector` にgit clone済み
- DB: `waka_collector_production` 作成済み・マイグレーション適用済み
- Nginx: 起動済み・設定済み
- データ: EC2側は1件のみ（テストデータ）

---

## 実施した作業

### 1. ローカルDBからデータダンプ

```bash
# WSL側で実行
sudo -u postgres pg_dump -d waka_collector_development \
  --data-only --table=wakas \
  -f /tmp/wakas_dump.sql
```

- `pg_dump -U postgres` はPeer認証エラーになるため `sudo -u postgres` を使用
- `-h localhost` （TCP接続）はkeiba_userのパスワード不一致でエラー
- `sudo -u postgres`（ソケット接続）で解決

### 2. EC2へ転送

```bash
scp -i ~/.ssh/waka-collector-key.pem \
  /tmp/wakas_dump.sql \
  ubuntu@15.152.49.240:/tmp/
```

### 3. EC2側でインポート

```bash
ssh -i ~/.ssh/waka-collector-key.pem ubuntu@15.152.49.240
sudo -u postgres psql -d waka_collector_production -f /tmp/wakas_dump.sql
```

- インポート結果: 1,103首（COPY 1103）
- インポート後合計: 1,104件（既存1件 + 1,103件）

### 4. systemd自動起動設定

```bash
# SECRET_KEY_BASE生成
cd /var/www/waka-collector
bundle exec rails secret
```

`/etc/systemd/system/waka-collector.service` を作成:

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
ExecStart=/usr/local/bin/bundle exec rails server -e production -b 0.0.0.0 -p 3000
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable waka-collector
sudo systemctl start waka-collector
```

**詰まりポイント**: `ExecStart` のbundleパスは `/usr/bin/bundle` ではなく `/usr/local/bin/bundle`
→ `which bundle` で確認してから設定すること

---

## 動作確認結果

| 確認項目 | 結果 |
|----------|------|
| ブラウザ一覧表示 | ✅ http://15.152.49.240/wakas |
| 和歌詳細表示 | ✅ |
| 検索・フィルター | ✅ |
| systemd自動起動 | ✅ active (running) |

---

## 今後のリリースサイクル

```
ローカル（WSL）で開発
  ↓
git push origin main
  ↓
EC2で以下を実行:
  ssh -i ~/.ssh/waka-collector-key.pem ubuntu@15.152.49.240
  cd /var/www/waka-collector
  git pull
  bundle install（gemに変更がある場合）
  bundle exec rails db:migrate RAILS_ENV=production（マイグレーションがある場合）
  sudo systemctl restart waka-collector
```

---

## 今後の課題

- [ ] SECRET_KEY_BASE を環境変数ファイルで管理（現在はserviceファイルに直書き）
- [ ] DBパスワードを強固なものに変更（公開サービス化する場合）
- [ ] SSL証明書設定（ドメイン取得後にLet's Encryptで対応）
- [ ] ルートパス設定（`root 'wakas#index'` を routes.rb に追加）
- [ ] EC2インスタンス再起動の確認テスト

---

## 管理コマンド集

```bash
# SSH接続
ssh -i ~/.ssh/waka-collector-key.pem ubuntu@15.152.49.240

# サービス操作
sudo systemctl start waka-collector
sudo systemctl stop waka-collector
sudo systemctl restart waka-collector
sudo systemctl status waka-collector

# ログ確認
sudo journalctl -u waka-collector -f

# Nginx操作
sudo systemctl restart nginx
sudo nginx -t
```
