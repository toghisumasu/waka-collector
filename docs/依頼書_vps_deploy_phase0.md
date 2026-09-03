# 依頼書 waka-collector ConoHa VPS デプロイ Phase 0 調査

**担当**: クロコさん（Claude Code）
**起票**: Claude.ai（其の◯◯）
**種別**: Phase 0（調査・設計のみ・VPS上への変更は最小限）
**ベースコミット**: e5f8d9c（cable.yml postgresqlアダプタ変更後）

---

## 背景と目標

**目的**: 平野連歌会での披露に向けて、waka-collector を ConoHa VPS（163.44.114.31）に初回デプロイする。

**技術構成**:

```
参加者ブラウザ → Nginx（VPS）→ Puma（VPS）→ PostgreSQL（VPS）
                                    ↓ Tailscale VPN
                              Ollama qwen3:14b（Mac mini）
```

**既存参考資料**: `docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`（Peer認証・Nginx・systemd・nftables の実績手順書、VPS同居アプリとして配置済み）

**Phase 0の成果物**: デプロイ手順書の草稿（`docs/vps_deploy_procedure_v1.0.md`）

---

## やること

### §0 事前確認

```bash
# Mac mini側
bundle exec ruby script/verify_shikimoku.rb
# → 116 pass / 0 fail を確認
```

---

### §1 VPS現状確認（SSH経由・読み取り中心）

Mac miniからSSHでVPSに接続して以下を確認する。

```bash
ssh <VPSユーザー>@163.44.114.31
```

#### §1-0 VPSリソース現状確認（増強判断の材料）

```bash
# RAM使用状況
free -h

# ディスク使用状況
df -h

# CPU・プロセス概況
top -bn1 | head -20

# 既存Pumaのworker/thread設定
grep -E 'workers|threads' /etc/systemd/system/keiba*.service 2>/dev/null
grep -E 'workers|threads' /etc/systemd/system/eiyou*.service 2>/dev/null
```

以下の判断基準で増強要否を報告する：

| 空きRAM | 判断 |
|--------|------|
| 500MB以上 | 増強不要（waka-collectorを追加可能） |
| 200-500MB | 要注意（Pumaのworker数を絞れば可能） |
| 200MB未満 | **増強必要**（プランアップグレードを推奨） |

waka-collectorが追加で必要とするRAMの概算：
- Puma（worker 1 / thread 5）: 約150-200MB
- PostgreSQL追加接続: 約10-20MB
- 合計: 約170-220MB

---

#### §1-1 使用中ポートと既存アプリ構成

```bash
# 使用中ポート
sudo ss -tlnp | grep -E 'puma|nginx|postgres'

# 既存Pumaの起動ポート
sudo systemctl list-units --type=service | grep -E 'keiba|eiyou|waka'
```

keiba-web と eiyokeikaku_app が使用しているポート番号を記録する。waka-collector に割り当て可能なポートを提案する（3002等）。

#### §1-2 既存Nginx設定の確認

```bash
ls /etc/nginx/sites-enabled/
cat /etc/nginx/sites-enabled/keiba-web    # または該当ファイル
cat /etc/nginx/sites-enabled/eiyokeikaku  # または該当ファイル
```

既存のserver blockの構成を確認し、waka-collector用の雛形を設計する。**特にAction Cable（WebSocket）のproxy設定が必要**——既存アプリでWebSocketを使っている場合はその設定を流用する。

#### §1-3 nftablesの現在のルール

```bash
sudo nftables list ruleset  # または nft list ruleset
```

現在の開放ポートを確認し、waka-collector用のポート追加コマンドを設計する。

#### §1-4 PostgreSQLのユーザー・DB一覧

```bash
sudo -u postgres psql -c '\l'   # DB一覧
sudo -u postgres psql -c '\du'  # ユーザー一覧
```

waka-collector用のDB名・ユーザー名を設計する（例: `waka_collector_production` / `waka_user`）。

#### §1-5 Tailscale状態確認とOllama疎通確認

**Mac miniのTailscale IP（確定値）**: `100.71.107.6`（shinobunomac-mini）

まずVPS上でTailscaleがインストールされているか確認する：

```bash
# VPS上で
which tailscale
tailscale status
```

**ケースA: Tailscaleがインストール済みで接続中**

```bash
curl http://100.71.107.6:11434/api/tags
# → モデル一覧が返れば疎通成功
```

**ケースB: Tailscaleが未インストール（想定されるケース）**

ConoHa VPSはTailscaleネットワークに現在未登録のため、インストールコマンドを記録するのみ（実施はPhase 1）：

```bash
# インストール手順（Ubuntu/Debian系、記録のみ）
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# → ブラウザでauthorize（Nobusonさんが実施）
```

Tailscale未インストールの場合、Ollama疎通確認はPhase 1完了後に実施する。その旨と「Tailscaleインストール」をPhase 1手順書に追加すること。

---

### §2 デプロイ設計

§1の結果を踏まえて、以下を設計し報告書に記載する。

#### §2-1 Nginx server block設計

```nginx
# 設計案（§1-2の既存設定を参考に）
server {
    listen 80;
    server_name <ドメインまたはIP>;

    location / {
        proxy_pass http://localhost:<waka-collectorのポート>;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Action Cable（Turbo Streams）用WebSocket proxy
    location /cable {
        proxy_pass http://localhost:<waka-collectorのポート>/cable;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
```

既存のeiyokeikaku設定との差分（WebSocket部分の追加）を明記する。

#### §2-2 systemdサービスファイル設計

`eiyokeikaku_conoha_deploy_procedure_v1.0.docx`のsystemdサービスファイルを雛形として、waka-collector用に以下の環境変数を追加した設計を示す：

```ini
[Service]
# 既存のeiyokeikaku設定をベースに追加
Environment="RAILS_ENV=production"
Environment="OLLAMA_URL=http://<Mac miniのTailscale IP>:11434"
Environment="RAILS_MASTER_KEY=<master.keyの内容>"
# 非同期Job実行のため、Pumaのスレッド数を確認・設定
```

#### §2-3 環境変数・credentials設計

本番で必要な環境変数のリストを作成する：

| 変数名 | 値 | 設定場所 |
|--------|-----|---------|
| RAILS_ENV | production | systemd |
| OLLAMA_URL | http://\<Tailscale IP\>:11434 | systemd |
| RAILS_MASTER_KEY | config/master.key の内容 | systemd or credentials |
| DATABASE_URL | （Peer認証の場合は不要か確認） | 要否を確認 |

---

### §3 既存手順書との差分整理

`docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`を参照し、以下の形式で差分を整理する：

| 手順 | eiyokeikaku | waka-collector | 差分 |
|------|------------|----------------|------|
| PostgreSQL作成 | 同様 | 同様 | なし |
| Nginx設定 | 基本形 | WebSocket追加 | /cable ブロック追加 |
| systemd | 基本形 | OLLAMA_URL追加 | 環境変数追加 |
| デプロイフロー | git pull→bundle→migrate→restart | 同様 | なし |
| nftables | ポート追加 | 同様 | なし |

---

### §4 デプロイ手順書草稿の作成

§1〜§3の結果をまとめて `docs/vps_deploy_procedure_v1.0.md` を作成する。

**構成**:
1. 前提条件（Tailscale疎通確認・Mac mini稼働確認）
2. VPS側の初回セットアップ（PostgreSQL・Nginx・systemd・nftables）
3. デプロイフロー（git clone・bundle・migrate・master.key配置）
4. 動作確認手順（curl・ブラウザ）
5. トラブルシューティング（OLLAMA_URL疎通失敗時・Action Cable未接続時）

---

## やらないこと

- VPS上でのファイル作成・変更（§1の確認コマンド実行のみ）
- git clone・bundle install（Phase 1）
- Nginx設定ファイルの配置（Phase 1）
- nftablesルールの変更（Phase 1）
- Mac mini上の`app/`配下の変更（D-33-1）

---

## 成果物

以下の2ファイルをコミットする（2コミット）：

1. `docs/依頼書_vps_deploy_phase0.md`（本依頼書）
2. `docs/vps_deploy_procedure_v1.0.md`（デプロイ手順書草稿）

---

## 受入条件

- `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- §1-5のTailscale疎通結果を明記（成功・失敗どちらも）
- waka-collector用ポート番号の提案を明記
- Nginx WebSocket設定の草稿を手順書に含める
- VPS上の既存ファイルへの変更なし

---

## 承認ゲート

`docs/vps_deploy_procedure_v1.0.md` の内容をClaude.aiスレッドに貼り付けて確認を受けること。実際のVPSへの変更作業（Phase 1）はClaude.aiの承認後にのみ着手する。

---

## 参照資料

- `docs/eiyokeikaku_conoha_deploy_procedure_v1.0.docx`（VPS同居アプリの実績手順書）
- `config/cable.yml`（postgresqlアダプタ設定済み）
- Phase 1実装コミット一覧（f8f86ed〜e5f8d9c）
- Mac mini Tailscale IP: `tailscale ip -4` で確認
