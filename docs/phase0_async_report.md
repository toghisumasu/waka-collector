# 調査報告書：RengasController非同期化 Phase 0 調査

- 作成日：2026-09-03
- セッション：其の◯◯（依頼書 `docs/依頼書_async_phase0.md`）
- 種別：Phase 0（読み取り専用・コード変更なし）
- 対象コード：`app/controllers/rengas_controller.rb`、`app/models/renga.rb`、
  `app/views/rengas/`、`config/application.rb`・`config/environments/*.rb`・
  `config/cable.yml`・`config/puma.rb`・`Gemfile`
- ゲートチェック：`bundle exec ruby script/verify_shikimoku.rb` → **116 pass / 0 fail**（調査中も維持）

---

## 0. 結論（要約）

**現行スタックは非同期化に必要な基盤を実質的に「素の状態で」既に持っている**。
`ActiveJob`のqueue_adapterは未設定だが、実測確認したところ**Railsの既定値
`:async`（プロセス内スレッドプール、追加gem・Redis不要）が有効**になっている。
さらに`turbo-rails`（2.0.23）が既にGemfileに入っており、Action Cableの
development環境も`async`アダプタ（Redis不要）設定済みである。

**現在の個人利用規模（Mac mini・単一ユーザー）を踏まえると、Sidekiq/Redis/
専用Workerプロセスのような重いインフラを導入する必要は無く、
「ActiveJob（:asyncアダプタ）＋Turbo Streamsのブロードキャスト機能
（`turbo-rails`が既に提供、WebSocketチャンネルの自作も不要）」という
組み合わせで、新規gem追加・Redisインストール・Workerプロセス常駐管理
のいずれも不要な最小コスト構成が組める**。これは依頼書が提示した
方式A（ポーリング）・方式B（Action Cable自作）のどちらとも異なる、
より軽量な第三の選択肢（「方式B'」として後述）である。

ただし`:async`アダプタには**プロセス再起動でジョブが失われる**という
明確な制約があり、Rails公式もproduction利用を推奨していない。
個人の実験利用では許容範囲と判断するが、リスクとして明記する。

---

## §1 現行スタックの確認

### §1-1 ActiveJobの設定状況

| 項目 | 確認結果 |
|---|---|
| queue_adapter | **未設定**（`config/environments/production.rb:74`に`# config.active_job.queue_adapter = :resque`とコメントアウトされているのみ）。実行時確認（`bundle exec rails runner`）では**`:async`（`ActiveJob::QueueAdapters::AsyncAdapter`）が有効** |
| Sidekiq/Resque/DelayedJob | **Gemfileに記載なし**。導入実績なし |
| Redis gem | **Gemfileでコメントアウト**（`# gem "redis", ">= 4.0.1"`）。未インストール |
| Action Cable（`config/cable.yml`） | development: `async`（Redis不要）／test: `test`／**production: `redis`**（Railsスキャフォールド既定値のまま、`REDIS_URL`環境変数も未設定でRedis自体が実在するか未確認） |
| Puma（`config/puma.rb`） | `threads_count = 3`固定、**workers数の指定なし＝単一プロセス構成**（クラスタモードではない） |

**keiba-webでのRedis使用有無**：本セッションからは`keiba-web`リポジトリに
アクセスできないため確認不可。同一ConoHa VPSでの共存を検討する際は
別途直接確認が必要（本報告では未確認事項として明記するに留める）。

### §1-2 RengasControllerの現行実装

`app/controllers/rengas_controller.rb`（`create`アクション、`:24-127`）：

1. **処理フロー**：①`KuValidator`でmaeku音数チェック（同期・高速）
   → ②式目チェック用の`ShikimokuChecker#next_constraints`（同期・高速、
   DB問い合わせのみ）→ ③**`RengaGenerator#generate_tsugeku`を同期呼び出し
   （ここがOllama呼び出しを含む重い処理、49秒〜256秒）** → ④式目最終検証
   → ⑤`Renga.create!`でDB保存 → ⑥`redirect_to @renga`
2. **タイムアウト対策**：`Timeout::timeout`等の明示的なラップは**無い**。
   `OllamaClient.generate`/`.chat`が内部で`timeout: 180`or`300`を持つのみ
   （`Net::ReadTimeout`→ `RuntimeError`化）。Webサーバ・プロキシ側の
   タイムアウトとは独立で、Ollama呼び出し自体が180-300秒でタイムアウトしても
   Railsのリクエスト処理はその分だけブロックされ続ける
3. **エラー時のフォールバック**：`rescue RuntimeError => e`で捕捉し、
   `@renga`を再構築して`flash.now[:alert]`にメッセージを乗せ
   `render :new, status: :service_unavailable`（HTTP 503）を返す
4. **レスポンス形式**：**HTMLのみ**。`format.json`・`format.turbo_stream`の
   分岐は無い。`redirect_to`/`render`は通常のRailsアクション

### §1-3 現行のフロントエンド構成

1. **リクエスト送信方法**：`app/views/rengas/new.html.erb`の
   `form_with model: @renga`（Rails 7既定でTurbo Drive経由のfetch送信、
   カスタムJSは無し）
2. **レスポンス受信後の画面更新**：Turbo Driveの標準的なページ遷移
   （`redirect_to @renga`でshowページへフルページ相当の遷移。
   Turbo Frame/Streamでの部分更新は使っていない）
3. **ローディング表示**：**無し**。`app/javascript/`にファイル自体が
   存在せず、カスタムJS・Stimulusコントローラは0件。ブラウザ既定の
   ローディングインジケータに依存している状態

---

## §2 非同期化の設計試案

### §2-0（依頼書に無い第三の選択肢の提示）

依頼書の方式A・Bはいずれも「Sidekiq等のWorkerプロセス」「Action Cableの
自作チャンネル」を前提としているが、§1の確認結果を踏まえると、
**現在の規模（個人・単一ユーザー・Mac mini）では以下の「方式B'」が
最小コストで実現できる**：

```
方式B'：ActiveJob(:asyncアダプタ) + Turbo Streamsブロードキャスト
[ブラウザ] → POST /rengas → プレースホルダのRengaレコードを即時作成
                             （status: "pending"）→ Jobをenqueue
                             → showページへ即座にredirect（200 OK、数百ms）
[showページ] → <%= turbo_stream_from @renga %> でチャンネルを自動購読
              （turbo-railsが提供、チャンネル自作不要）
[Job（同一プロセス内スレッドで実行）]
              → RengaGenerator#generate_tsugekuを実行
              → 完了したらRengaレコードを更新
              → Renga#broadcast_replace_to（turbo-railsのモデルconcern、
                after_update等で1行呼ぶだけ）で該当DOM要素を自動更新
[ブラウザ] → Action Cable（development/このスケールならasyncアダプタで
              Redis不要）経由でHTML差分を受信・自動反映
```

新規gem・Redisインストール・専用Workerプロセスの起動管理が**一切不要**
（`turbo-rails`は既にGemfileにあり、ActiveJob/Action Cableとも
`:async`アダプタはRails本体に同梱）。

### §2-1〜§2-2 変更箇所リスト（方式A・B・B'共通部分と差分）

| コンポーネント | 方式A（ポーリング、Sidekiq等前提） | 方式B（依頼書記載、Action Cable自作） | 方式B'（本報告の提案） |
|---|---|---|---|
| Jobクラス新規作成 | 必要（`GenerateRengaJob`） | 必要（同左） | 必要（同左、内容は共通） |
| Rengaモデルへのカラム追加 | `status`・`job_id` | `status`（job_idは購読先の特定に必要な場合のみ） | `status`のみ（`turbo_stream_from @renga`は既存の`id`だけで購読先を特定できるため`job_id`不要） |
| controller `create`変更 | 必要（プレースホルダ作成＋enqueue＋202/job_id返却） | 必要（同左＋subscribe誘導） | 必要（プレースホルダ作成＋enqueue＋showへredirect、以降は同じ） |
| statusエンドポイント追加 | **必要**（ポーリング先） | 不要（push型のため） | **不要**（Turbo Streamsのpushで代替） |
| フロントエンドJS | **必要**（`setInterval`等の自作ポーリングコード） | 必要（Action Cable購読コードの自作） | **不要**（`turbo_stream_from`タグ1行、`turbo-rails`が全て処理） |
| Action Cableチャンネル自作 | 不要 | **必要**（`RengaChannel`等） | **不要**（`turbo-rails`の`Turbo::StreamsChannel`をそのまま利用） |
| Redis | 通常必要（Sidekiq運用の一般的な前提） | **必要**（productionのcable.ymlが`redis`アダプタのため） | **不要**（cable.ymlのproduction設定を`async`に変更すれば済む、単一プロセス構成の間は成立） |
| Workerプロセスの新規常駐管理 | **必要**（Sidekiq等を別プロセスとして起動・監視） | 同左 | **不要**（`:async`アダプタはPumaプロセス内のスレッドプールで実行されるため、別プロセス管理が丸ごと不要） |

**方式B'の制約**（正直に明記）：
- `:async`アダプタはジョブを**メモリ内**に保持するため、**Pumaプロセスの
  再起動・デプロイ時に実行中/待機中のジョブが消える**（Rails公式ドキュメントも
  production非推奨と明記）。個人の実験利用では許容範囲と考えるが、
  本番相当の信頼性が必要になった時点でSidekiq+Redisへの移行が要る。
- 単一Pumaプロセス前提（`config/puma.rb`が既にworkers指定なしの単一
  プロセス構成のため現状は問題ないが、将来クラスタモードに変える場合は
  `:async`では破綻し、Sidekiq等が必須になる）。
- Turbo Streamsのブロードキャストは「DOM要素の差し替え」という設計思想の
  ため、show画面の該当箇所をpartial化する程度のビュー変更は要る
  （大きな変更ではない）。

### §2-3 方式の比較

| 観点 | 方式A（ポーリング、Sidekiq前提） | 方式B（Action Cable自作） | 方式B'（:async + Turbo Streams） |
|---|---|---|---|
| 実装コスト | 中（Job・DBカラム・statusエンドポイント・自作ポーリングJS） | 中〜大（同左＋チャンネル自作＋購読JS） | **小**（Job・DBカラムのみ、JS・チャンネルは`turbo-rails`任せ） |
| UX | 2秒間隔ポーリングのため若干のタイムラグ、通信回数が多い | 即時プッシュ、通信効率が良い | **即時プッシュ**（方式Bと同等のUX、実装はより単純） |
| デプロイ複雑度 | 高（Redis＋Worker常駐が前提） | 高（同左＋WebSocket対応のリバースプロキシ設定） | **低**（新規インフラ無し、既存Pumaプロセスのみ） |
| Mac mini単機での動作可否 | 可能だがRedis・Worker常駐の追加設定が要る | 可能だが同左＋WebSocket設定 | **既存構成のまま動作可能**（追加インストール不要） |

**推奨は方式B'**：依頼書のA/Bどちらよりも低コストで、UXは方式Bと同等。
将来的にトラフィックが増える、または複数Pumaプロセス（クラスタモード）に
した場合は、その時点でSidekiq+Redisへ切り替える（ActiveJobの
アダプタ切り替えは設定変更のみで、Jobクラス自体のコードは変更不要）。

---

## §3 インフラ要件の確認

### §3-1 Mac mini（現行開発環境）での動作可否

- **方式B'を採る場合、追加のプロセス常駐管理は不要**（`:async`アダプタは
  既存のRailsサーバプロセス内で完結するため、LaunchAgent等の新規登録が
  丸ごと不要）。
- 既存のOllama LaunchAgent（`homebrew.mxcl.ollama`）とは競合しない
  （Ollamaは別プロセス・別ポートで稼働しており、ActiveJobの:asyncは
  Railsプロセス内部の話のため独立）。
- 方式A/Bを採る場合はSidekiq等のWorkerプロセスをLaunchAgent等で
  別途常駐させる必要があり、Ollama LaunchAgentと同様の運用管理が
  1つ増える（本報告では詳細な手順までは調査していない）。

### §3-2 ConoHa VPS（将来のデプロイ先）での追加要件

- 方式B'であれば、Nginx設定の変更は**Action CableのWebSocket
  アップグレード対応（`Upgrade`/`Connection`ヘッダのプロキシ設定）のみ**
  で済み、Redis・別Workerプロセスのsystemdユニット追加は不要。
- 方式A/Bであれば、Redisのインストール・systemdサービス化、
  Workerプロセス用の別systemdユニット（またはProcfile経由の管理）が
  追加で必要になる。
- **keiba-webとの共存**：ポート分離・Nginx server blockの追加自体は
  方式によらず必要な作業（アプリケーション自体を新規にデプロイする以上、
  非同期化の方式選択とは独立した既定コスト）。keiba-webが既にRedisを
  使っている場合、方式A/Bでの相乗り（DB番号を分ける等）が可能かは
  本セッションからは確認できない未確認事項。

---

## §4 推奨方針

1. **推奨方式：B'（ActiveJob :asyncアダプタ + Turbo Streamsブロードキャスト）**。
   理由は§2-3の通り、実装コスト・デプロイ複雑度が依頼書のA/Bよりも
   明確に低く、現在の個人利用規模（Mac mini・単一プロセス）に対して
   過剰なインフラ投資にならないため。UXは方式Bと同等（即時プッシュ）。
2. **実装工程の粗い順序**（提案、実装はしない）：
   1. `Renga`モデルに`status`（enum: pending/processing/done/failed）と
      失敗時メッセージ用カラムを追加するマイグレーション
   2. `GenerateRengaJob`を新規作成（現行`create`アクションの
      ③④⑤に相当する処理をジョブへ移動、完了時に`status`を更新）
   3. `RengasController#create`を軽量化（①②の同期チェックはそのまま残し、
      ③以降をジョブのenqueueに置き換え、即座に`show`へredirect）
   4. `show.html.erb`に`turbo_stream_from @renga`を追加、
      生成中/完了/失敗の3状態を出し分けるpartialを用意
   5. 10句規模の手動確認（ジョブが実行され、画面が自動更新されることを確認）
3. **非同期化完了後の`:waka_extraction`完全切り替え可否**：
   非同期化（方式B'でも十分）が実現すれば、**同期リクエストのタイムアウト
   問題は解消**され、`:waka_extraction`への切り替え自体は
   `docs/phase0_strategy_switch_report.md`で確認済みの通り
   コントローラの1行変更で可能になる。ただし**1句あたり平均49秒・
   最悪256秒という体感待ち時間はUXとしては依然として長い**ため、
   切り替えの是非（`:waka_extraction`本採用）は非同期化のUX改善とは
   別に、生成品質（ng率・句切れ品質）とのトレードオフとして
   改めて判断すべき論点として残る。

---

## 付録：一次資料

- 対象コード：`app/controllers/rengas_controller.rb`、`app/models/renga.rb`、
  `app/views/rengas/new.html.erb`、`config/environments/production.rb:74`、
  `config/cable.yml`、`config/puma.rb`、`Gemfile`
- 実行時確認：`bundle exec rails runner`で`ActiveJob::Base.queue_adapter`が
  `ActiveJob::QueueAdapters::AsyncAdapter`であることを確認
- 比較元：`docs/phase0_strategy_switch_report.md`（非同期化が前提条件と結論）
- 未確認事項：keiba-web側のRedis使用状況・ConoHa VPS上のRedis有無
  （本セッションからは他リポジトリ・実サーバへのアクセス不可のため）
