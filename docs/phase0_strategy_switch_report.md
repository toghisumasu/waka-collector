# 調査報告書：:waka_extraction → :direct 切り替え検討 Phase 0

- 作成日：2026-09-03
- セッション：其の◯◯（依頼書 `docs/依頼書_strategy_switch_phase0.md`）
- 種別：Phase 0（読み取り専用・コード変更なし）
- 対象コード：`app/services/renga_generator.rb`（614行）、
  `app/controllers/rengas_controller.rb`、`config/routes.rb`
- ゲートチェック：`bundle exec ruby script/verify_shikimoku.rb` → **116 pass / 0 fail**（調査中も維持）

---

## 0. 結論（要約）

- **dispatch機構は既に統一済み**：`RengaGenerator#generate_tsugeku`は
  `constraints[:generation_strategy] == :waka_extraction`で
  `StepwiseWakaGenerator`へ完全委譲する分岐を既に持つ（其の七十三実装）。
  **「完全切り替え」も「並走」も、コード上はコントローラのconstraints hashに
  1行`generation_strategy: :waka_extraction`を足すだけで技術的には可能**。
  依頼書が想定した「RengaGeneratorをStepwiseWakaGeneratorに置き換える」
  規模の変更は不要。
- しかし**真の障壁はコードではなくレイテンシ**：`:waka_extraction`は
  1句あたり平均49秒（最大256秒）を要し、現行の`RengasController#create`は
  ActiveJob等の非同期基盤を一切持たない**完全同期のHTTPリクエスト**である。
  Web標準・プロキシのタイムアウト（多くは30-60秒）を頻繁に超過する規模の
  待ち時間であり、**「完全切り替え」も「並走」も、まず非同期化
  （ジョブキュー＋結果通知/ポーリングUI）という別の前提作業が必須**。
  これはA/B/Cいずれを選んでも避けられない共通コスト。
- `:direct`と`:waka_extraction`は共通祖先を持ちながら**異なる方向に
  改良が分岐**しており、単純な「上位互換」関係ではない
  （`:direct`固有のStep0感覚ドメインローテーション・Socratic対話は
  `:waka_extraction`側には無い。逆に`:waka_extraction`固有の
  WakaPersona・Step1.5・案C/Fは`:direct`側には無い）。
- **推奨：B（バックポート）を軸にした部分移植**。ただし今回のPhase0調査で
  判明した「非同期化が両方に共通の前提」という点を踏まえ、**まず
  非同期化のPhase0調査を別途起票することを強く推奨**する（詳細は§3）。

---

## §1 :direct（RengaGenerator）の現行実装確認

### §1-1 :directに反映済みの改善

| 改善 | :directでの実装状況 |
|---|---|
| **案A（`continue_line`、commit `5d4e9a6`）** | ✅ **反映済み**（`directive_lines`、`:450-454`）。ただし`must_continue`側の`continue_line`のみで、**`switch_line`（案A後半、`:waka_extraction`側にはある「季を転じるべき局面です」の文言）は未反映** |
| **案C（`ZATSU_SEED_BIAS`）** | ❌ **未反映**。`filter_pool`（`:377-410`）は`must_switch`/`must_continue`のハード絞り込みのみを持つ（これは元々:waka_extractionの`sample_seed`と同等の防御的二重化として存在していたロジックであり、両者で共通）。だが「雑局面で雑seedを確率的に優先する」という案C固有の考え方は`filter_pool`に存在しない |
| **案F（`shift_window_to_kigo`）** | ❌ **未反映、かつ移植の意味が薄い**。`:direct`は31音のテキストを生成してから切り出す方式ではなく、17音/14音を直接LLMに生成させる方式のため、「窓をずらして季語を含む位置を探す」という概念自体が`:direct`のアーキテクチャに存在しない |
| その他バックポート実績 | 季節ヒント（`season_hint`, `must_switch`/`must_continue`）の基本的な受け渡し配線（D-44-1）は両方式で共通の`RengasController`/`ShikimokuChecker#next_constraints`を経由するため、**季ヒントの生成・受け渡し自体は既に共有インフラ** |

### §1-2 :directに未反映の改善

| 改善 | 状況 |
|---|---|
| Step1.5（`adjust_free_verse_length`、閾値29/33） | ❌未反映。`:direct`には「自由詠み→音数調整→書き換え」という多段構造自体が無い（1コールで直接17音/14音を狙う設計のため、概念上対応する箇所が存在しない） |
| `clean_phrase_edges?`長句「に」止め許容（`dd4e3ab`） | ❌未反映。`:direct`は`extract_mora_segment`を使わず（`open_phrase?`という別の简易判定を使用、`renga_generator.rb:325`付近）、この関数自体を呼んでいない |
| Step3プロンプト受理域明示（案6、`9cdda76`） | ❌未反映（該当する「Step3」が存在しない。ただし`mora_feedback_message`という:direct独自のmora不一致feedback文言は別途存在し、こちらは数値を明示済み、後述） |
| `boundary_index_near`のtanku最低mora検証（`b68ffbf`） | ❌未反映（`extract_mora_segment`は`:direct`でも共有関数として呼ばれている（`:354,358,360`、上の句・下の句抽出用）が、これは短歌の切り出しであり`:waka_extraction`のchouku/tanku抽出とは用途が異なる。ただし**同じ関数を経由するため、`boundary_candidates_near`によるtolerance救済の恩恵は既に自動的に及んでいる**（コードは共有）。したがって「未反映」ではなく**既に共有インフラとして反映済み**が正しい） |
| `WakaPersona`（3ペルソナ） | ❌未反映。`:direct`はペルソナ・視座の概念を持たない（前述の通り、代わりに独自のStep0感覚ドメインローテーションを持つ） |

**訂正**：`boundary_index_near`関連の改修（`b68ffbf`）は`verse_text_analysis.rb`が
両クラスでincludeされる共有モジュールのため、**既に`:direct`にも自動的に
反映されている**（`extract_mora_segment`呼び出し箇所が`renga_generator.rb`に
3箇所存在、`:354,358,360`）。依頼書の想定（未反映）とは異なる。

### §1-3 :directの生成フロー

```
RengaGenerator#generate_tsugeku
 ├─ build_seed_pool（キャッシュ） → filter_pool（bui/使用済み/季ヒント）
 ├─ Step0（其の七十九、:direct専有）
 │    前句の情景・感覚を1文で言語化 + 感覚ドメインを4種からローテーション決め打ち
 │    → LLM 1コール（chat）
 ├─ outer loop ×5（seed再抽選）
 │    └─ inner loop ×5（attempt）
 │         ├─ mora_error_streak≥2 → Socratic対話（chat、転じ方hint付き、300秒timeout）
 │         ├─ repeat_streak≥2     → Socratic対話（chat、転じ方hint付き、300秒timeout）
 │         └─ 通常                → build_full_prompt → OllamaClient.generate
 │                                   （1コールで17音 or 14音を直接生成、180秒timeout）
 │         ├─ mora検証（±1音超で失敗）→ feedback付き同attempt内リトライ、
 │         │                            wrong_streak≥3でseed再抽選
 │         └─ mora OK → echo/鸚鵡返し/固着(sticky)/history_repeat検査
 │                        → 全通過でaccept・break
 └─ 理論上限：Step0(1) + 5×5(25) + Socratic分（streak条件成立時のみ追加）
```

```
StepwiseWakaGenerator#generate（:waka_extraction、RengaGeneratorから完全委譲）
 └─ outer draft loop ×5（seed + persona再抽選）
      ├─ Step1 自由詠み ⇄ Step2内容判定（最大3往復、LLM1コール/往復、31音程度の自由文）
      ├─ Step1.5 音数調整（最大3往復、LLM1コール/往復、29-33音域に収まるまで）
      └─ Step3書き換え ⇄ Step4機械抽出（最大5往復、LLM1コール/往復）
           ├─ Step4: extract_mora_segment(tolerance:1) + boundary_candidates_near
           ├─ clean_phrase_edges?（長句「に・て・で・ば」止め許容）
           └─ shift_window_to_kigo（季語を含む窓へのスライド）
 理論上限：5×(3+3+5)=55コール、実測平均11.7-16.5コール/句（p4-p6run100）
```

**構造的な違い**：
1. **生成対象の違い**：`:direct`は目標の17音/14音を**直接**1コールで生成させる。
   `:waka_extraction`は31音程度の**自由な文章をまず生成し、そこから機械的に
   切り出す**（生成と整形を分離）。区切り不一致・句切れ不自然という
   `:waka_extraction`特有の問題群は、この「切り出し」という工程自体に
   起因しており、`:direct`には構造的に発生しない。
2. **リトライ機構の違い**：`:direct`はmora不一致・重複が連続すると
   単発feedbackから**複数ターンのSocratic対話（chat）**へエスカレーションする
   独自機構を持つ。`:waka_extraction`はfeedback文言の強化と温度上昇のみで、
   chatベースの対話的エスカレーションは持たない。
3. **創造性補助の違い**：`:direct`はStep0（感覚ドメインローテーション）、
   `:waka_extraction`はWakaPersona（視座・ペルソナ）と、**別々の考え方で
   創造性を補助**しており、どちらかがどちらかの上位互換ではない。

---

## §2 切り替えコストの試算

### §2-1 「完全切り替え」のコスト

**コード変更コスト：極小**。`RengasController#create`（`:59-97`）の
`RengaGenerator.new(...)`呼び出しの`constraints`ハッシュに
`generation_strategy: :waka_extraction`を1行追加するだけで、
dispatch機構（`renga_generator.rb:106-119`）が既に存在するため
それ以上の変更は不要。

**真のコストはレイテンシ**：

| | :direct | :waka_extraction |
|---|---|---|
| 1句あたりOllama呼出回数（実測/理論） | 理論上限25回+α（実測値の系統的記録なし） | 実測平均11.7-16.5回、最大62-65回 |
| 1句あたり所要時間（実測） | **未計測**（`observe_production_hyakuin.rb`系のログにelapsed記録なし） | 実測平均48.7-55.5秒、最大256.1秒 |
| 現行Web（`RengasController#create`）の実行方式 | 完全同期（ActiveJob等の非同期基盤は未使用、`app/jobs/`はRails既定の空スケルトンのみ） | 同上（同じコントローラを通る） |

`:direct`の1コールあたりの応答時間はqwen3系モデルで概ね4-5秒程度と
:waka_extraction側の実測から類推でき、通常1-3attemptで収束する想定
（式目チェック通過を前提）から、**:directの典型ケースは5-20秒程度**と
推定される（未計測のため推定に留まる）。対して`:waka_extraction`は
**平均49秒・最悪256秒**であり、一般的なWebサーバ/プロキシの
タイムアウト（Nginx既定60秒、Herokuルータ30秒等）を頻繁に超過する
水準。**現行の同期リクエストのまま`:waka_extraction`へ完全切り替えると、
高確率でユーザーに504/タイムアウトエラーを返すことになる**。

**結論**：完全切り替えは、コード上は1行で可能だが、**非同期化
（バックグラウンドジョブ＋結果通知またはポーリングUI）が事実上の
前提条件**であり、これ自体が本調査のスコープを超える別工程となる。

### §2-2 「バックポート」のコスト

未反映の改善を優先度順に並べる（効果の大きさ × 移植難易度）。

| 優先度 | 改善 | 効果見込み | 移植難易度 |
|:-:|---|---|---|
| 高 | 案A後半（`switch_line`） | 低コストで対称性が取れる（`continue_line`と同型の1行追加） | 極小（`directive_lines`に1行足すだけ） |
| 中 | 案C（`ZATSU_SEED_BIAS`相当） | :directの雑局面での季転換に効く可能性（:waka_extraction側で確認済みの効果） | 小（`filter_pool`の雑局面分岐に確率的重み付けを追加） |
| 低〜中 | `clean_phrase_edges?`長句「に」止め相当の緩和 | `:direct`は`open_phrase?`という別の簡易判定を使っており、そもそも`:waka_extraction`ほど厳格な語境界判定を経由していない可能性が高い（要個別調査） | 中（`open_phrase?`の実装確認が前提、今回未実施） |
| 低 | Step1.5・Step3プロンプト受理域明示・WakaPersona | `:direct`のアーキテクチャ（1コール直接生成）に対応する箇所が存在しないため、移植ではなく**新規設計**が必要 | 大（多段パイプラインを1コール方式に組み込むのは設計変更に近い） |

**総評**：軽量な改善（案A後半、案C）は移植コストが小さく即着手可能。
一方、`:waka_extraction`の主要な改善（Step1.5・Step3・boundary系）は
「31音生成→機械抽出」という`:direct`には存在しない工程を前提にしており、
**素直な移植ができない**（`:direct`に同じ問題が発生していない可能性も高い
——`:direct`は最初から17音/14音を狙って生成するため、区切り不一致・
句切れ不自然という`:waka_extraction`特有の失敗モード自体が存在しない）。

### §2-3 「並走」の可否

**技術的には既に可能**：`constraints[:generation_strategy]`による
dispatchが実装済みのため、リクエストごとに`:direct`/`:waka_extraction`を
出し分けるA/Bテストは、コントローラに数行の分岐を足すだけで実現できる
（例：セッションID等でのランダム割り当て、または`params`経由の明示指定）。

ただし§2-1で述べた**非同期化の前提**は並走でも同様に必要
（`:waka_extraction`側に割り当てられたリクエストだけ数十秒〜数分待たせる
UXは、同期方式のままでは受け入れがたい）。**並走を「機能フラグを
足すだけ」で済ませられるのは、`:waka_extraction`側も何らかの形で
低レイテンシ化するか、非同期化された場合に限る**。

---

## §3 推奨方針

### 推奨：**B（バックポート）を軸に、まず低コストな2件（案A後半・案C相当）を先行移植**

理由：
1. **完全切り替え（A）は非同期化という前提工程を要し、今回のスコープを
   大きく超える**。レイテンシの実態（平均49秒・最悪256秒）を踏まえると、
   非同期化なしの完全切り替えは実質的に選択肢たり得ない。
2. **並走（C）も同じ非同期化の前提を共有する**ため、コード上は
   「既に可能」だが実運用上のハードルはAとほぼ同じ。並走の技術的容易さ
   （dispatch機構が既存）は魅力的だが、レイテンシ問題を迂回する
   ものではない。
3. **バックポート（B）は`:direct`のアーキテクチャに適合する改善
   （案A後半・案C相当）から着手すれば、非同期化を待たずに`:direct`
   本番の品質改善という独立した価値を生む**。Step1.5・boundary系のような
   `:waka_extraction`固有の改善は、`:direct`に同型の問題が存在するか
   どうかも未確認であり（`:direct`は生成方式が異なるため同じ失敗モードが
   起きない可能性が高い）、移植の優先度は相対的に低いと判断する。

### 次のアクション（提案、実装はしない）

1. まず**非同期化（ジョブキュー＋結果通知）のPhase0調査**を別途起票し、
   `:waka_extraction`をいずれ本番投入する際の共通の前提を整理する
   （これが無いままA/Cの検討を進めても実運用に至れない）。
2. 並行して、低コストな案A後半・案C相当を`:direct`へバックポートする
   （非同期化を待たずに着手可能）。
3. `:direct`側の`open_phrase?`の実装を別途確認し、`:waka_extraction`の
   句切れ不自然系の知見が`:direct`にも適用可能かを判断する
   （本Phase0では未確認）。

---

## 付録：一次資料

- 対象コード：`app/services/renga_generator.rb`（`generate_tsugeku`:106-119、
  `filter_pool`:377-410、`directive_lines`:433-456、`build_full_prompt`:458-473、
  `step0_miitate`:479-）、`app/controllers/rengas_controller.rb`
  （`create`:24-127）、`config/routes.rb`
- 参照資料：`docs/waka-collector-handover-v2.md`（ファイル名は依頼書記載と
  ハイフン/アンダースコアが異なる。内容は2026-05-10時点の**旧世代**の
  waka-collector＝勅撰和歌集検索アプリのEC2/AWSデプロイ手順で、
  現行の連歌生成機能（`rengas`テーブル・`RengaGenerator`等）が実装される
  **前**の情報。現行メモリ（プロジェクト側の記録）では「waka-collectorは
  未デプロイ・ローカルMac miniのみで動作」と確定しており、本ドキュメントの
  EC2稼働情報は現状と一致しない可能性が高い。A/B判断の参考にはならないため、
  本報告では利用していない）
- 比較元：`docs/phase1_boundary_run100_report.md`ほか一連のp3-p6報告書
  （`:waka_extraction`の現達成値）
