# 其の七十八 Phase 0 調査報告（read-only）

- 調査日: 2026-08-22
- 方針: read-only。app/ には一切変更を加えていない。
- ゲートチェック: `verify_shikimoku.rb` 116 pass / 0 fail（調査開始前に確認済み）

## 1. gaze_path の逐語コピーが発生するステップ

**該当ステップ: Step1（自由詠み）のプロンプト構築 `build_free_verse_prompt` → `gaze_block`**
（`app/services/stepwise_waka_generator.rb:284-333`）

`gaze_block` は `@gaze_mode` によって挙動が分岐する。

- `:literal`（其の七十四方式、比較用）: `persona[:gaze_path]` の3フレーズ（例:
  「足元に萌え出づる若草の露」）を**完成した名詞句のまま**プロンプトへ埋め込む
  （`stepwise_waka_generator.rb:317-323`）。これがそのままStep1出力に転記される
  というのが其の七十六 Phase Aで確認された逐語コピーの発生源。
- `:abstract`（現在の既定）: 距離帯ラベルと感覚チャネルのみを渡し、コピー可能な
  完成句をプロンプトに一切含めない（`stepwise_waka_generator.rb:325-331`）。

**重要な時系列の確認**: `:abstract` を既定にするD-77-2の修正はコミット
`2e8ed59`（2026-08-05）で本番コードに入っている。一方、調査対象ログ
`observation_sono76_calls_sono76_14b_run1_20260821.jsonl` およびその実体である
`log/stepwise_steps_20260821.jsonl` / `log/stepwise_steps_20260822.jsonl` は
2026-08-21〜22の実行であり、**D-77-2適用後**のもの。実際に該当ログの全レコードは
`"gaze_mode":"abstract"` であり、`:literal` 方式によるgaze_path丸写しは
このログには理論上発生し得ない（プロンプトに埋め込まれる完成句が存在しないため）。

→ 「gaze_path逐語コピー」問題そのものは、其の七十七のD-77-2で**既に閉じられている**。
今回のログに現れる繰り返し・停滞パターン（後述§3）は、gaze_pathとは別系統の
自己強化ループが原因である。

## 2. WakaPersona.best_match の自己強化ループ

`best_match(maeku)`（`app/services/waka_persona.rb:84-90`）はキーワード一致数に
基づく**決定論的**な関数であり、同じ `maeku` を渡せば必ず同じペルソナを返す
（一致0件ならnil→ランダム）。

呼び出し経路（`stepwise_waka_generator.rb:69-77`, `generate`）:

```ruby
def generate
  MAX_DRAFT_ATTEMPTS.times do |draft_i|   # 5回
    seed      = @pool.sample
    persona   = WakaPersona.resolve(@persona_key, @maeku)   # ← @maekuは不変
    ...
```

`@maeku` は `initialize` 時に固定され、`generate` 内の5回の draft attempt を通じて
一切変化しない。したがって `persona_key` が `nil`（自動選択、既定）の場合:

- 1回の `generate()` 呼び出し内では、5回のdraft attemptすべてで
  **同一ペルソナ**が選ばれ続ける（seedはdraft_iごとに再サンプルされ変わるが、
  ペルソナは変わらない）。
- `generate()` が `nil` を返し、呼び出し元（RengaGenerator側）が同じ句position
  （＝同じ`@maeku`）で新しい `StepwiseWakaGenerator` を作って再試行した場合も、
  `@maeku` が変わらない限り**再び同じペルソナ**が選ばれる。

これが自己強化ループの本体：「前句→同一ペルソナ選択」という経路が、
`:literal` モードでは「同一gaze_path提示→丸写し→前句エコー→詠み直しでも
同一ペルソナ・同一gaze_path→再び丸写し」という脱出不能ループを生んでいた
（waka_persona.rb:12-19のコメントに其の七十六診断として明記）。

`:abstract`モードでは `resolve_zone` が `content_retry` ごとに再抽選される
（`stepwise_waka_generator.rb:96-99`）ため、少なくとも距離帯（near/middle/far）は
retry間で変わり得る。ただし **ペルソナ自体は不変**であり、かつ`generate()`をまたぐ
outer retry（同一`@maeku`での再試行）でも `zone`は独立に再抽選されるだけで
必ずしも変化を保証しない。→ ループの根本原因（`best_match(maeku)`の決定論性）は
`:abstract`移行後も**構造的には残存**している。§3のクラスタBはその実例。

## 3. ログサンプル（step1_free_verse × maeku・gaze_pathの関係）

**注記**: `observation_sono76_calls_sono76_14b_run1_20260821.jsonl` は
呼び出し種別・所要時間のみを記録するメタログで、Step1の実出力テキストは
含まれていない（キー: `verse_no/attempt/api/kind/timeout_setting/elapsed/ok/error`）。
実出力は `StepwiseStepLogger`（D-77-1）が書き出す
`log/stepwise_steps_20260821.jsonl`（38行、23:40〜日付境界まで）と
`log/stepwise_steps_20260822.jsonl`（1771行、日付をまたいだ続き）に記録されている。
このログにも `@maeku` 本文は記録されておらず（`log_context`にverse_no/batchを
渡していない実行だったため`batch/verse_no`列は全行`null`）、前句テキストとの
直接突合はできない。加えて `observation_sono76_sono76_14b_run1_20260821.jsonl`
（44行、verse_no上限が一桁台）は行数の規模が`stepwise_steps`側（1809行相当）と
大きく食い違っており、同一runの記録として単純に結合できない。以下はこの制約の
もとで、**同一ログファイル内で自己完結する形**で抽出した実例。

### サンプル1〜3（正常系: step2通過）

| ts | persona | zone | seed | output | mora |
|---|---|---|---|---|---|
| 23:40:20 | 前途ある若者 | far | くるしき物と | 遠き空にかすみけりし青さ久しき | 19 |
| 00:12:22 | 前途ある若者 | far | 身のいたつらに | 草の端に露の光が揺れて消えゆく | 19 |
| 00:17:17 | 世を捨てた庵の主 | middle | おもかけにのみ | ききょうの香りに嵐の音がさざなみのように揺れる | 26 |

いずれもseed語や具体的なgaze_path句をそのまま転記してはおらず、
`:abstract`方式の「何を見つけるかはモデルに委ねる」という設計意図通りの
出力になっている。gaze_pathの逐語コピーという意味では、この3件に問題はない。

### サンプル4（クラスタA: 同一draft内でのretry間"逐語自己コピー"）

```
draft_attempt=3, content_retry=1, persona=前途ある若者, zone=far, seed=花色衣
  output: 「遠き空に風の声かすむ」 → step2: 前句エコー

draft_attempt=3, content_retry=2, persona=前途ある若者, zone=far, seed=花色衣
  output: 「遠き空に風の声かすむ」 → step2: 前句エコー   ← 1文字も変わらず同一
```

`content_retry=1`が前句エコーで却下された際、`feedback_note`として
「前回の『遠き空に風の声かすむ』は前句エコーでした。前句をそのまま繰り返さず…」
という文言が次のプロンプトに載る（`build_free_verse_prompt`）。それにも関わらず
`content_retry=2`でモデルは**一字一句同一の文字列を再出力**している。
これはgaze_pathの丸写しではなく、**フィードバックで提示した「前回の出力」自体を
モデルが再度そのまま返す**という別種の自己強化ループであり、Step3の
書き換えループで既知だった「フィードバック文言の複写」（D-73-2コメント、
`stepwise_waka_generator.rb:335-340`）と同系統の症状がStep1側にも
（feedback_noteの引用テキストという形で）現れている可能性を示唆する。

### サンプル5（クラスタB: 複数の異なるdraft/seedをまたいだ収束）

同一の出力文字列「遠くにききょうの色はさすかに風」が、**異なる4つのseed**・
**異なるdraft_attempt番号（1, 3, 5, 3）**・**5分以上離れたタイムスタンプ**で
繰り返し出現している。

```
00:23:14  draft_attempt=1  seed=秋しなけれは     → 遠くにききょうの色はさすかに風（前句エコー）
00:24:15  draft_attempt=3  seed=しるもしらぬも   → 遠くにききょうの色はさすかに風（前句エコー）
00:27:05  draft_attempt=5  seed=雪そふるらし     → 遠くにききょうの色はさすかに風（前句エコー）
00:28:16  draft_attempt=3  seed=嵐のかせは       → 遠くにききょうの色はさすかに風（前句エコー）
```

`draft_attempt`が1つの`generate()`呼び出し内では1→5と単調増加するはずなのに
ここでは 1, 3, 5, 3 と非単調に現れている。これは**単一のgenerate()呼び出し内の
draft loopでは説明できず**、`generate()`が`nil`を返すたびに呼び出し元が
同じ句position（同じ`@maeku`）で新しい`StepwiseWakaGenerator`インスタンスを
作って再試行した、**複数回のouter retry**にまたがる出現だと考えられる
（persona・zoneがすべて`前途ある若者`/`far`で共通している点も、
`best_match(maeku)`が同一`@maeku`に対して同一ペルソナを返し続けるという
§2の構造と整合する）。

seed語（連想語）が4回とも異なるにも関わらずStep1の出力がほぼ同じ文字列に
収束していることから、モデルはseedよりも**前句（maeku）自体を強く模倣する
傾向**があり、`:abstract`化でgaze_path丸写しを防いでも、前句そのものの
言い換えに寄って`maeku_echo?`に何度も抵触する、という形でループが再現している
可能性が高い。ただし前句本文がログに残っていないため、これは状況証拠による
推定であり確定診断ではない（§4参照）。

## 4. 今回の調査で分かった限界・申し送り

- `StepwiseStepLogger`は`@maeku`本文を記録していない。`log_context`
  （batch/verse_no）も本runでは渡されておらず、`stepwise_steps_*.jsonl`単体では
  「どの前句に対する出力か」を直接突合できない。前句を含めたクラスタBのような
  ループの確定診断には、`@maeku`（または前句のverse_id）をログに追加するか、
  `log_context`を実行時に必ず渡す運用が必要。
- `observation_sono76_calls_sono76_14b_run1_20260821.jsonl`と
  `observation_sono76_sono76_14b_run1_20260821.jsonl`は同名runとして存在するが
  行数規模が`stepwise_steps_20260821/22.jsonl`（合計1809行）と大きく異なり
  （前者893行はコール単位、後者44行は句単位のはずだが句数が少なすぎる）、
  同一の100句本番runの記録として素直に対応付けられなかった。ファイル間の
  対応関係（同一run由来か、別の短縮runか）は本Phase0では確認できず、
  人間側の記憶・実行記録での確認が必要な可能性がある。
- 上記の理由により、本報告のクラスタA/Bは「同一ログファイル内で自己完結する
  事実（同一出力文字列の再出現、draft_attempt/timestampの並び）」から導いた
  推定であり、「前句のどの語がコピーされたか」という直接証拠ではない。

## まとめ

1. gaze_path丸写し問題（其の七十六診断）は、其の七十七のD-77-2
   （`:abstract`既定化）によりコード上は既に解消済み。今回のログ
   （2026-08-21〜22実行）はすべて`:abstract`モードで取得されており、
   `:literal`方式由来の逐語コピーはそもそも発生し得ない。
2. `WakaPersona.best_match(maeku)`が`@maeku`に対して決定論的である構造は
   `:abstract`移行後も変わっておらず、同一前句に対する複数回のouter retryが
   常に同一ペルソナへ収束するという自己強化ループの土台は残っている
   （`stepwise_waka_generator.rb:72`）。
3. 実ログ上も、(a) 同一retry内でモデルが自身の前回出力を一字一句再出力する
   ケース（クラスタA）と、(b) 異なるseed・複数回のouter retryをまたいで
   ほぼ同一の出力に収束するケース（クラスタB）の両方が確認された。
   後者は前句そのものへの言い換え依存が疑われるが、`@maeku`本文が
   ログに残っていないため確定診断には至らず、ログ計装の拡張
   （`@maeku`本文または`log_context`の常時記録）が次の調査の前提条件となる。

本報告はPhase 0（read-only）につき、app/への変更提案・実装は行っていない。
次の一手（ログ計装拡張の是非、クラスタBの確定診断方法など）は人間の判断を仰ぐ。
