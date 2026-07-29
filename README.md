# waka-collector — 連歌ウェブアプリ（× Ollama）

古典和歌の収集システム waka-collector に、ローカル LLM（Ollama / qwen3:8b メンタムさん）を統合し、連歌百韻の付句生成・式目検証を行う Ruby on Rails アプリケーション。

**動作環境**

| 項目 | バージョン |
|------|-----------|
| Ruby | 3.3.6 |
| Rails | 7.2.3 |
| PostgreSQL | 16.13 |
| Ollama | 0.23.2 / qwen3:8b（GPU オフロード） |
| 形態素解析 | MeCab（natto）+ ユーザー辞書 `dict/user.dic` / UniDic（並行運用） |

**アクセス**
http://192.168.**0.**1:*000/rengas/new

現在はローカル Mac mini でのみ稼働（未デプロイ）。

---

## アーキテクチャ（3層）

| 層 | 実装 | 責務 |
|----|------|------|
| **A層** | Ruby | 式目の決定論的検証 — `ShikimokuChecker`（句去・句数・定座・一座一句物・七句去物） |
| **B層** | Ruby + YAML | 候補フィルタ — `BuiDictionary`（`app/data/*.yml`）、seed pool（`Waka` テーブル由来） |
| **C層** | LLM | 付句生成 — qwen3:8b via Ollama（`RengaGenerator` / `StepwiseWakaGenerator`） |

判定（A・B層）は LLM に委ねず純 Ruby で完結させ、LLM には生成タスクのみを与えるのが本プロジェクトの基本方針。

---

## 付句生成の2方式

`RengaGenerator#generate_tsugeku` は `constraints[:generation_strategy]` で生成方式を切り替える。

| 方式 | 値 | 概要 |
|------|-----|------|
| 直接生成 | `:direct`（**デフォルト・本番稼働中**） | 前句に対し七七/五七五を直接生成。Socratic 対話・5×5 リトライループを持つ |
| 和歌抽出 | `:waka_extraction` | 和歌一首（31音）を詠ませ、そこから短句/長句を機械抽出。`StepwiseWakaGenerator` へ完全委譲 |

```ruby
RengaGenerator.new(
  maeku, honka_candidates, :tanku,
  constraints: {
    generation_strategy: :waka_extraction,
    persona: :hermit,          # 省略時は自動選択
    season_hint: { current: "秋", must_switch: false },
    forbidden_bui: ["降物"],
    verse_history: [...]
  }
).generate_tsugeku
```

---

## StepwiseWakaGenerator — 和歌抽出パイプライン

一発のプロンプトで「文脈継承」「前句非重複」「31音厳守」を同時に要求すると qwen3:8b では成功率が低い。そのため生成を分割し、LLM には *自由な文脈生成* と *形式への書き換え* という単純なタスクだけを与え、判定・抽出は Ruby 側で行う。

```
  ┌─ Step 1   自由詠み（LLM）
  │            音数制約なし／ペルソナ（視座）を注入して詠ませる
  │            目安：三十一音程度（三十〜三十五音前後）
  │
  ├─ Step 1.5 音数調整・動的推敲（LLM）      ← 其の七十五で追加
  │            50音超  → 核心の情景へ要約・凝縮（:condense）
  │            25音未満 → 遠景を加えて対比・拡張（:expand）
  │            適正範囲に収まるまで、上限3回まで繰り返す
  │
  ├─ Step 2   内容判定（Ruby・LLM 呼び出しなし）
  │            前句エコー／一巻内の既出表現／禁じ手（forbidden_bui）を検出
  │            違反時は理由をフィードバックして Step 1 へ差し戻し（同一 seed で最大3回）
  │
  ├─ Step 3   形式整形（LLM）
  │            意味・情景を保ったまま五・七・五・七・七＝31音へ書き換え
  │
  └─ Step 4   機械抽出（Ruby）
               31音テキストから extract_mora_segment で切り出す
                 長句（chouku・五七五＝17音）… 先頭17音
                 短句（tanku ・七七  ＝14音）… 17音スキップ後の14音
```

### 各段の上限・閾値（`app/services/stepwise_waka_generator.rb`）

| 定数 | 値 | 意味 |
|------|-----|------|
| `MAX_DRAFT_ATTEMPTS` | 5 | Step 1 のやり直し（新しい seed・ペルソナで最初から） |
| `MAX_CONTENT_RETRIES` | 3 | Step 1 ⇄ Step 2 の往復（同一 seed・同一ペルソナ） |
| `MAX_LENGTH_ADJUST_ATTEMPTS` | 3 | Step 1.5 の推敲回数上限 |
| `MAX_REWRITE_ATTEMPTS` | 5 | Step 3 ⇄ Step 4 の往復（同一 free_text） |
| `FREE_VERSE_MORA_LONG_THRESHOLD` | 50 | これを超えたら凝縮を指示 |
| `FREE_VERSE_MORA_SHORT_THRESHOLD` | 25 | これを下回ったら遠景追加を指示 |
| `WAKA_TOTAL_MORA` (± `TOLERANCE`) | 31 (±2) | Step 4 の総モーラ数許容範囲 |

Step 1.5 は「大きな振れ幅の補正」に留め、31音への精密な収束は Step 3 が担う。上限に達して適正範囲へ収束しなかった場合もテキストはそのまま Step 2 以降へ流す。

### 設計上の注意（実地確認から得た知見）

- **音数制約を外すだけでは短くなる** — 下限の目安（「短いフレーズだけで終わらせない」）を明示しないと 7〜25音で終わり、Step 3 で伸ばしきれない。
- **フィードバック文の位置** — 書き換え対象テキストの直後にフィードバックを置くと、モデルが指示文ごと出力に複写する。指示ブロック側（対象テキストより前）に置き、`【】` 見出しで区切る。
- **Step 4 の総モーラ数ガード** — `extract_mora_segment` が偶然 non-nil を返しても、総モーラ数が31から大きく外れていれば句境界と無関係な断片になる。±2音を超える場合は成功扱いにしない。

---

## WakaPersona — ペルソナ（視座）の注入

抽象的な形容詞（「寂しい」「美しい」）に逃げた平板な描写を避け、身体感覚に基づく密度の高い表現を引き出すため、Step 1 に「誰が・どこから・どんな境遇で詠んでいるか」というペルソナを注入する（`app/services/waka_persona.rb`）。

### 指定方法

`constraints[:persona]` に以下を渡す。

| 値 | 挙動 |
|----|------|
| `nil`（省略） | 自動選択：前句のキーワード一致で最良のペルソナ → 一致なしならランダム |
| `:random` | 常にランダム |
| `:youth` / `:hermit` / `:woman` | 明示指定 |
| 上記以外 | `ArgumentError` |

ペルソナは Step 1 ⇄ Step 2 の往復中は固定され、`generate` の外側ループ（draft attempt）ごとに再選択される。

### 定義済みペルソナ

| キー | 名 | 立ち位置 |
|------|-----|---------|
| `:youth` | 前途ある若者 | 野辺に立つ若者 |
| `:hermit` | 世を捨てた庵の主 | 山深き草庵の軒端に座す隠者 |
| `:woman` | 日々を営む女 | 格子窓のそばで手仕事をする女 |

### gaze_path（視線移動）

各ペルソナは3段の `gaze_path` を持ち、プロンプトで「この順に視線を移し、それぞれを丁寧に描写せよ」と指示する。

```
一、手元・身近   … 例（:hermit）手にした冷たい茶碗や経机の木目
二、目の前の対象 … 例（:hermit）軒端に落ちる雫や苔むした庭石
三、遠くの景色   … 例（:hermit）谷間にたなびく霧や遠い山の稜線
```

併せて `NEGATIVE_INSTRUCTION`（「客観的な状況説明や形容詞だけに頼らず、色・光・音・肌触りといった主体の身体感覚で描写すること」）を毎回添える。`gaze_path` の語彙が出力へ直接反映され、描写の質感が向上することを実地確認済み。

`keywords` は前句との一致数によるペルソナ自動選択（`WakaPersona.best_match`）にのみ使用し、プロンプトには含めない。

---

## ファイル構成

```
app/
├── controllers/
│   ├── rengas_controller.rb              # new / create / show
│   ├── wakas_controller.rb               # 和歌 CRUD
│   └── concerns/season_hint_logger.rb    # 季節ヒント（must_switch/must_continue）の可視化
├── models/
│   ├── renga.rb                          # 連歌の句
│   └── waka.rb                           # 古典和歌（seed pool の供給元）
├── services/
│   ├── ollama_client.rb                  # Ollama API 通信（generate / chat / tool calling）
│   ├── ollama_tools.rb                   # tool calling 定義
│   ├── renga_generator.rb                # 付句生成（:direct 方式本体・方式振り分け）
│   ├── stepwise_waka_generator.rb        # :waka_extraction 方式の4ステップ（+Step1.5）
│   ├── waka_persona.rb                   # ペルソナ（視座）定義・選択
│   ├── verse_text_analysis.rb            # 両方式共通のテキスト解析（モーラ計算・抽出）
│   ├── shikimoku_checker.rb              # 式目ガードレール（純 Ruby・A層）
│   ├── renga_checker.rb                  # 字数・去嫌の簡易チェック
│   ├── bui_dictionary.rb                 # 部立辞書（B層）
│   ├── ku_validator.rb                   # 句の読み・モーラ検証
│   └── waka_unidic_analyzer.rb           # UniDic 並行運用（ku_validator へ影響なし）
├── data/
│   ├── bui_dictionary.yml                # 部立語彙
│   ├── kuzari_rules.yml                  # 句去ルール
│   ├── kukazo_rules.yml                  # 句数ルール
│   ├── ichiza_ichiku_words.yml           # 一座一句物
│   ├── nanaku_gomono_words.yml           # 七句去物
│   └── makura_map.yml / decoration_pool.yml
└── views/rengas/{new,show}.html.erb       # 前句入力フォーム / 結果表示（音分解付き）

dict/
├── user_entries.csv                       # MeCab ユーザー辞書のソース
└── user.dic                               # コンパイル済み（「かりね」「紅葉」等）

script/                                    # 検証・観測・分析スクリプト（後述）
docs/                                      # 各セッションの報告書・引き継ぎ文書
```

`build_mecab` は `dict/user.dic` を `userdic:` 指定で読み込み、失敗時は標準辞書へフォールバックする（フォールバック発生自体をゲートチェックで監視）。

---

## テスト・品質管理

### ① 式目ゲートチェック（必須・セッション開始時）

```bash
bundle exec ruby script/verify_shikimoku.rb 2>/dev/null | tail -5
```

**期待値：116 pass / 0 fail**（試験項目は今後も増える）。**失敗している場合は作業禁止。**

句去・句数・長短交互・定座（月・花）・一座一句物・水無瀬三吟全100句の統合スキャン・回帰テスト（`describe(:generation_failed)` / `describe(:mora_error)`）・MeCab ユーザー辞書の読み込み確認などを含む。

### ② RSpec

```bash
bundle exec rspec                # 全体
bundle exec rspec spec/services  # サービス層のみ
```

現状：**108 examples / 5 failures / 20 pending**

- `spec/services` のみなら **83 examples / 0 failures / 14 pending**（green）
- 残る 5 failures は `spec/models/waka_spec.rb`・`spec/requests/wakas_spec.rb` の **Waka ファクトリの既知バグ**によるもので、生成パイプラインとは無関係。

主なサービス層 spec：

| ファイル | 対象 |
|----------|------|
| `spec/services/stepwise_waka_generator_spec.rb` | 4ステップ + Step 1.5 パイプライン |
| `spec/services/waka_persona_spec.rb` | ペルソナ定義・`resolve` / `best_match` |
| `spec/services/verse_text_analysis_spec.rb` | モーラ計算・`extract_mora_segment` |
| `spec/services/ku_validator_spec.rb` / `waka_unidic_analyzer_spec.rb` | 読み解析・UniDic |

> **用語注意：** 「テスト」には ①ゲートチェック（`verify_shikimoku.rb`・期待値 116 pass）と ②RSpec の2種があり、期待値を混同しないこと（過去に取り違え事例あり）。

### ③ 観測・分析スクリプト（`script/`）

| スクリプト | 用途 |
|-----------|------|
| `observe_production_hyakuin.rb` | 本番構成での百韻通し観測（jsonl ログ出力） |
| `run_observe_and_summarize.sh` | 観測＋集計の一括実行 |
| `dryrun_hyakuin.rb` | ドライラン（**`RengaGenerator` を require しないため本番検証には使わない**） |
| `analyze_generation_failures.rb` | 生成失敗要因の集計 |
| `log_to_html.rb` | jsonl ログ → 百韻本フォーマット HTML（季節色分け） |
| `verify_*.rb` | 個別機能の実地検証 |

本番構成の検証は `rails runner` 経由で行う。jsonl の行数はリトライを含むため句数ではなく、完走判定は `verse_no` の最大値で行う。

---

## サーバ起動

```bash
# Mac mini
bundle exec rails server -b 0.0.0.0 -p 3000

# または WSL2 からリモート SSH
ssh macmini
cd /Volumes/externalHDD/projects/waka-collector
bundle exec rails server -b 0.0.0.0 -p 3000
```

Ollama の疎通確認：

```bash
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen3:8b","prompt":"テスト","stream":false}'
```

---

## プロンプト設計の原則

1. **情報量と安定性はトレードオフ** — プロンプトを短く保つと安定動作する。
2. **否定指示より肯定＋例示** — 「書くな」より「1行で出力する。例：…」が効く。
3. **例示は局所的に効く** — すべての難読語を網羅はできない。
4. **誤りの層を見分ける** — 字数誤判定の根は「漢字→読み」の変換にあることが多い。
5. **1プロンプト1タスク** — 複数条件の同時要求は成功率を落とす。分割し、判定は Ruby 側へ寄せる（StepwiseWakaGenerator の設計思想）。
6. **モデルの創造性を殺さない** — 形式（音数）を一発で強制するのではなく、自由に詠ませてから段階的に寄せる（Step 1 → 1.5 → 3）。

---

## 既知の課題

- **Step 3 の31音収束** — 31音（±2）へ安定収束しない。ペルソナ導入後にむしろ悪化した観測もある。
- **`WakaPersona.best_match` の表記ゆれ** — `keywords` がひらがな/漢字の表記ゆれを吸収できず、ペルソナ自動選択が取りこぼす。
- **Step 1.5 の閾値根拠** — 50音 / 25音は実データ不足のため、実地確認済みの極端事例（201音・14音）と既存目標値から暫定採用したもの。実運用データでの再検証が必要。
- **句数：秋の偏り** — 百韻通し観測で秋の比率が高止まりしており、`next_constraints` 配線後も改善していない。
- **UniDic ユーザー辞書** — モデルファイル不足によりコンパイル未実現（MeCab 標準辞書側のみ対応済み）。

---

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| タイムアウト | Ollama 未ロード | 上記 `curl` で再ロード |
| unknown エラー | プロンプトが長すぎる | プロンプトを短く絞る／安定版に戻す |
| 付句が短い | 出力例が不足 | 出力例を七七の明確な例に修正 |
| 読みが誤判定 | 漢字→読み変換ミス | `dict/user_entries.csv` へ登録し `user.dic` を再コンパイル |
| ペルソナが効かない | 前句にキーワード一致なし | `:persona` を明示指定する |
| Step 1.5 が収束しない | 閾値外の極端な出力 | 上限3回で打ち切られる仕様。Step 3 側のフィードバックを確認 |
| フィードバック文が出力に混入 | プロンプト内の配置 | 対象テキストより**前**に置き `【】` で区切る |

---

## リソース

- **開発手順書1**（フェーズ0〜5） — `Z:\temp\wakas-web\連歌アプリ開発手順書.docx`
- **開発手順書2**（発展フェーズ6〜9） — `Z:\temp\wakas-web\連歌アプリ開発手順書2.docx`
- **式目ルール**（連歌式目の制定） — `Z:\temp\wakas-web\連歌式目の制定`
- **各セッションの成果・申し送り** — `docs/handover_*.md` / `docs/observation_analysis_*` / `docs/依頼書_*` / `docs/phase0_*`
- **百韻本フォーマット** — `public/hyakuin_test.html` + `script/log_to_html.rb`

---

## 最後に

連歌はコンピュータの論理と古典文学の美学が出会う場所。プロンプト調整もまた、制約の中で最良を目指す営みです。各フェーズを通じて、メンタムさんとの対話を深めていきましょう。

---

*「なぁなぁメンタム〜」*
