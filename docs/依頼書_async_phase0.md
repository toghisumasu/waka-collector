# 依頼書 RengasController非同期化 Phase 0 調査

**担当**: クロコさん（Claude Code）
**起票**: Claude.ai（其の◯◯）
**種別**: Phase 0（読み取り専用・変更なし）
**ベースコミット**: 0e53b97（切り替え検討Phase 0報告書コミット後）

---

## 背景と問い

`:waka_extraction`の完全切り替えは、技術的には1行で可能だが、
**応答時間（49-56秒/句）がWebサーバタイムアウト（30-60秒）を超える**ため、
非同期化が前提条件となっている。

現行の`RengasController#create`は完全同期のHTTPリクエストで、
ActiveJob等の非同期基盤を持っていない。

本Phase 0では「非同期化に必要な全工程」を洗い出し、
実装コストとリスクを定量化する。

---

## やること

### §0 事前確認

```bash
bundle exec ruby script/verify_shikimoku.rb
# → 116 pass / 0 fail を確認
```

---

### §1 現行スタックの確認

#### §1-1 ActiveJobの設定状況

`config/application.rb`・`config/environments/*.rb`・`Gemfile`を確認する：

1. ActiveJobのキューバックエンドは何か
   （`:async`/`:sidekiq`/`:resque`/`:delayed_job`/未設定）
2. SidekiqやResqueなどのWorkerプロセスは既に使用中か
3. Redisは既に導入済みか（keiba-web等で使用中かも含めて確認）

#### §1-2 RengasControllerの現行実装

`app/controllers/rengas_controller.rb`を読み、以下を記録する：

1. `create`アクションの処理フロー（生成呼び出し→保存→レスポンスまで）
2. タイムアウト対策が現在施されているか（`Timeout::timeout`等）
3. エラー時のフォールバック処理
4. レスポンス形式（JSON/HTML/Turbo Stream等）

#### §1-3 現行のフロントエンド構成

`app/views/rengas/`・`app/javascript/`を確認する：

1. 生成リクエストの送信方法（form submit/fetch/Turbo）
2. レスポンス受信後の画面更新方法
3. ローディング表示の有無

---

### §2 非同期化の設計試案

§1の確認結果を踏まえ、以下の2方式について**実装に必要な変更箇所と工数**を試算する。

#### §2-1 方式A: ActiveJob + ポーリング

```
[ブラウザ] → POST /rengas → JobをキューにEnqueue → job_idを即返す（202 Accepted）
[ブラウザ] → GET /rengas/:job_id/status（2秒おきにポーリング）
[Worker]   → Jobが完了したらRengaレコードを保存
[ブラウザ] → 完了を検知したら結果を表示
```

変更が必要なコンポーネント:
- Jobクラスの新規作成（`GenerateRengaJob`）
- Rengaモデルへのstatus/job_idカラム追加（マイグレーション）
- controllerのcreateアクション変更
- statusエンドポイントの追加
- フロントエンドのポーリング実装（JS）
- Workerプロセスの運用（Mac mini・将来のConoHa VPS）

#### §2-2 方式B: Action Cable（WebSocket）

```
[ブラウザ] → POST /rengas → JobをEnqueue → チャンネルをsubscribe
[Worker]   → 完了したらAction Cable経由でブラウザにpush
[ブラウザ] → pushを受信して結果を表示
```

変更が必要なコンポーネント:
- 方式Aの変更点に加えてAction Cableチャンネルの実装
- WebSocket対応のためのデプロイ設定変更

#### §2-3 方式の比較

| 観点 | 方式A（ポーリング） | 方式B（WebSocket） |
|------|-------------------|-------------------|
| 実装コスト | — | — |
| UX | — | — |
| デプロイ複雑度 | — | — |
| Mac mini単機での動作可否 | — | — |

---

### §3 インフラ要件の確認

#### §3-1 Mac mini（現行開発環境）での動作可否

- Workerプロセス（Sidekiq等）をLaunchAgent等で常駐させられるか
- 現行のOllama LaunchAgent（`homebrew.mxcl.ollama`）との共存

#### §3-2 ConoHa VPS（将来のデプロイ先）での追加要件

- Workerプロセスのサービス管理（systemd/Procfile）
- Redisが必要な場合のインストール・設定
- Nginxの設定変更（WebSocket対応が必要な場合）
- keiba-webとの共存（ポート分離・Nginx server block）

---

### §4 推奨方針

§1〜§3の結果を踏まえ、以下を提示する：

1. **推奨方式**（A/B）とその理由
2. **実装工程の粗い順序**（どこから着手するか）
3. **非同期化完了後に`:waka_extraction`完全切り替えが可能か**の判断

---

## やらないこと

- `app/`配下の変更（D-33-1）
- DBマイグレーションの実行
- Gemfile変更・bundle install
- 走行

---

## 成果物

`docs/phase0_async_report.md` に以下を記録してコミットする：

```
- §1: 現行スタック確認結果
- §2: 方式A・B の変更箇所リストと工数試算
- §3: インフラ要件
- §4: 推奨方針と実装順序
```

---

## 受入条件

- `bundle exec ruby script/verify_shikimoku.rb` → 116 pass / 0 fail 維持
- DBへの書き込みなし
- `docs/phase0_async_report.md` をコミット（1タスク1コミット）
- 本依頼書も `docs/依頼書_async_phase0.md` としてコミット

---

## 承認ゲート

Phase 0完了後、`docs/phase0_async_report.md` の内容を
Claude.aiスレッドに貼り付けて確認を受けること。
実装（Phase 1）はClaude.aiの承認後にのみ着手する。

---

## 参照資料

- `docs/phase0_strategy_switch_report.md`（切り替え検討Phase 0・非同期化が前提条件と結論）
- `app/controllers/rengas_controller.rb`
- `config/application.rb`・`config/environments/`
- `Gemfile`
- インフラメモ（ConoHa VPS: 163.44.114.31、keiba-web稼働中）
