# 其の七十八：:direct vs :waka_extraction(14b) 100句ログ比較分析

- 分析日: 2026-08-25
- 対象ログ:
  - :direct 100句: `log/observation_sono39_sono78_direct_run1_20260822.jsonl`（209行、verse_no 0〜100）
  - :waka_extraction 14b 100句: `log/observation_sono76_sono78_14b_hyakuin_run1_20260822.jsonl`（282行、verse_no 0〜100）
  - :waka_extraction callsログ: `log/observation_sono76_calls_sono78_14b_hyakuin_run1_20260822.jsonl`（api呼出単位、verse_no/attempt付き）

## 前提：最終確定句のmora_result（参考）

verse_no 0（seed）を除く100句のうち、各verse_noの最終レコード（最大attempt）のmora_result集計。

| mora_result | :direct | :waka_extraction(14b) |
|---|---|---|
| ok | 32 | 81 |
| warning | 64 | 7 |
| ng | 4 | 12 |

:waka_extraction(14b)はok率が高い一方、ng（最終的にモーラ不適合のまま採用）も:directの3倍出ている。

---

## 1. ng違反種別ごとの件数・verse_no分布

`violations`配列の要素を「:」の前までを種別としてカテゴライズ（該当なしはそのまま）。1verse_noで複数attempt・複数種別が出るため、件数は延べ数。

### :direct

| 種別 | 件数 | verse_no |
|---|---|---|
| 生成失敗 | 56 | 3,4,5,7,17,21,27,43,45,47,52,54,62,64,68,76,78,84,94,98 |
| 句去:七句去物 | 45 | （句去47件のうち大半、下記参照） |
| 句去（内、七句去物45／植物2） | 47 | 18,22,25,32,36,42,43,44,46,47,54,56,58,62,79,80,83,89,91,98,99 |
| 接続タイムアウト | 15 | 12,21,37,47,56,65,96,98 |
| 句数（春11／秋3） | 14 | 23,31,50,54,57,58 |
| 前句forced_zatsu由来ng | 7 | 4,5,48,99 |
| 一座一句物:嵐 | 1 | 14 |

句去・句数の内訳:
- 句去:七句去物 45件
- 句去:植物 2件
- 句数:春 11件
- 句数:秋 3件

### :waka_extraction(14b)

| 種別 | 件数 | verse_no |
|---|---|---|
| 生成失敗 | 176 | 1,2,3,5,7,8,10,12,14,15,16,18,20,21,22,24,26,27,29,30,31,35,38,42,43,45,47,53,54,55,58,62,63,65,68,71,72,75,77,78,79,81,84,86,88,89,90,93,95,99 |
| 句数（秋22／春17） | 39 | 8,14,15,24,43,47,53,63,81,90,93 |
| 前句forced_zatsu由来ng | 5 | 16,72 |
| 句去:七句去物 | 4 | 72 |
| モーラng(15音) | 1 | 96 |

句数の内訳:
- 句数:秋 22件
- 句数:春 17件

**所見**: :waka_extraction(14b)は「生成失敗」が:directの約3倍（176件 vs 56件、対象verse_noも約2.5倍の広がり）。一方で式目系（句去・一座一句物）の違反は:directで顕著（句去47件・一座一句物1件）に対し:waka_extraction(14b)ではほぼ収束（句去4件のみ、一座一句物0件）。句数（季）違反はどちらも「秋」に偏る傾向は共通（既知のD-50-1課題、[[sono51_status]]参照）だが件数自体は:waka_extraction(14b)がやや多い（39 vs 14）。

---

## 2. forced_zatsu採用句の一覧

各verse_noの最終レコード（action名に"forced_zatsu"を含む＝forced_zatsu系処理で確定した句）を抽出。

### :direct（6句）

| verse_no | action | mora_result | text |
|---|---|---|---|
| 3 | forced_zatsu_mora_ng | ng | 夢の果てに光りゆく遠き道なりけり |
| 4 | forced_zatsu_mora_ng | ng | 夜風に揺れる星の灯りもまたかなきや |
| 47 | forced_zatsu_mora_ng | ng | 夜風のそよぐ声に心揺れるなりけり |
| 54 | forced_zatsu_create | ok | 夢の果てに光り出でしやう |
| 58 | forced_zatsu_create | warning | 夜の夢はただ消えゆくばかり |
| 98 | forced_zatsu_mora_ng | ng | 風の音に混じる静かな誓いの声 |

### :waka_extraction(14b)（18句）

| verse_no | action | mora_result | text |
|---|---|---|---|
| 5 | forced_zatsu_mora_ng | ng | 夜風に揺れる花の香りが届く |
| 8 | forced_zatsu_create | warning | 夜明けの夢を追うように歩く |
| 14 | forced_zatsu_mora_ng | ng | 月の光に揺れる影のゆらめき |
| 15 | forced_zatsu_mora_ng | ng | 静かな夜の終わりに灯る灯の揺れ |
| 20 | forced_zatsu_mora_ng | ng | 夢の果てに揺れる星の光を追う |
| 21 | forced_zatsu_mora_ng | ng | 幽霊船の汽笛が夜風を裂く |
| 24 | forced_zatsu_create | warning | 風の音に心は揺れるまま |
| 30 | forced_zatsu_mora_ng | ng | 夢の終わりに揺れる星の光 |
| 47 | forced_zatsu_create | warning | 風の音に揺れる枯葉の影 |
| 53 | forced_zatsu_mora_ng | ng | 夜明けの果てに静けさが広がる |
| 58 | forced_zatsu_mora_ng | ng | 星の光りゆかし夜は静かに |
| 63 | forced_zatsu_create | warning | 夢見る子守の歌に聴こえず |
| 71 | forced_zatsu_mora_ng | ng | 月の光揺れて心にそっと届く |
| 72 | forced_zatsu_mora_ng | ng | 夜風そよぐ声に心震わす |
| 81 | forced_zatsu_mora_ng | ng | 夢の果てに光る星屑の海 |
| 90 | forced_zatsu_mora_ng | ng | 夢の果てに星の光揺れてゆくも |
| 93 | forced_zatsu_create | warning | 夜風に揺れる孤独な影の |
| 99 | forced_zatsu_create | ok | 風の音木に揺れる葉揺るぐ |

**所見**: forced_zatsu採用句は:directが6句（全体の6%）に対し:waka_extraction(14b)は18句（18%）と3倍。上記1.の「生成失敗」多発と直結しており、Step Architecture（[[sono73_status]]）が正規経路での生成に失敗するケースが多いことを示唆する。

---

## 3. callsログのmaeku（前句）フィールド確認

**確認結果: callsログには`maeku`フィールドは記録されていない（0/該当ログ全行）。**

callsログのキー構成は `api, attempt, elapsed, error, kind, ok, timeout_setting, verse_no` の8種のみ。サンプル3件:

```json
{"verse_no":1,"attempt":1,"api":"generate","kind":"step1_free_verse","timeout_setting":180,"elapsed":10.13,"ok":true,"error":null}
{"verse_no":1,"attempt":1,"api":"generate","kind":"step1_5_length","timeout_setting":180,"elapsed":3.52,"ok":true,"error":null}
{"verse_no":1,"attempt":1,"api":"generate","kind":"step3_mora_rewrite","timeout_setting":180,"elapsed":2.83,"ok":true,"error":null}
```

コミット`96c90d8`（2026-08-22 15:40）で`maeku`が追記されたのは`app/services/stepwise_step_logger.rb`の`append_step_record`であり、これは別ログファイル`log/stepwise_steps_20260822.jsonl`（全ステップ詳細ログ、14,197行）に書き出される。今回分析対象のcallsログ（`observation_sono76_calls_*`）はAPI呼出のタイミング計測用の別経路で、`maeku`追記の対象ではない。前句の収束診断を行う場合は`stepwise_steps_20260822.jsonl`側を参照する必要がある。

---

## 4. step3_mora_rewrite呼出回数トップ5（verse_no別）

callsログから`kind:"step3_mora_rewrite"`のみを抽出しverse_no別に集計（全100句が対象、合計4,385回、1句あたり平均43.9回・中央値24.5回）。

**同数タイの句が7件、いずれも呼出回数の上限値と思われる125回で並ぶ:**

| 順位 | verse_no | 呼出回数 |
|---|---|---|
| 1 | 5 | 125 |
| 1 | 20 | 125 |
| 1 | 21 | 125 |
| 1 | 30 | 125 |
| 1 | 58 | 125 |
| 1 | 71 | 125 |
| 1 | 99 | 125 |
| 8 | 15 | 121 |
| 9 | 68 | 116 |
| 9 | 72 | 116 |

**所見**: 125回で頭打ちになる句が7件存在し、単純な上位5件ではすべて同値のタイとなる。これらの多くはそのまま「2.」のforced_zatsu採用句（5,20,21,30,58,71は一致、99も一致）と重なっており、step3（モーラ調整のための書き直しループ）が収束せず上限まで空転した末にforced_zatsuへ落ちるパターンが確認できる。125という値が実装上のリトライ上限（外側attempt×内側retry等の積）に一致するかは、`StepwiseWakaGenerator`側のリトライ設定を確認する必要がある。

---

## 5. 両戦略の句サンプル比較（10句ずつ、verse_no揃え）

verse_no 10,20,...,100 の各最終確定句を並べる（seedが異なるため文脈は連続しないが、構造上の対応点として同じverse_noを比較）。

| verse_no | :direct（action/mora） | :direct 句 | :waka_extraction(14b)（action/mora） | :waka_extraction(14b) 句 |
|---|---|---|---|---|
| 10 | create/warning | 白妙に庭に花の香るかな | create/ok | 市井の気配やさしくかかり |
| 20 | create/ok | 夜の海に心を沈めしにけり | forced_zatsu_mora_ng/ng | 夢の果てに揺れる星の光を追う |
| 30 | create/ok | 山の静けさに月の光漏れる | forced_zatsu_mora_ng/ng | 夢の終わりに揺れる星の光 |
| 40 | create/warning | 月の光に揺れる花の香り | create/ok | 石畳の隙間光這い上がるや |
| 50 | create/warning | ききょうの香りよ紅葉に揺れる | create/ok | 格子の影そっと手のひらに触れる |
| 60 | create/warning | 心を照らすに物ならなくに | create/ok | 石垣の陰に手をかけたとき肌 |
| 70 | create/warning | 光の果てをゆく時の流れ | create/ok | 格子の影指先にそっと伸びて |
| 80 | create/warning | 風の音も心に届く | create/ok | 指先に春の露が溶けゆく遠き |
| 90 | create/warning | 夜空に散る星の光の跡 | forced_zatsu_mora_ng/ng | 夢の果てに星の光揺れてゆくも |
| 100 | create/warning | 夜風に揺れる心の重さにけり | create/ok | 石の上に置かれた水鉢の底 |

**所見**:
- :directはほぼ全句が「create/warning」（モーラ許容範囲内だが厳密一致ではない）で安定して収まる一方、内容面では「月の光」「風の音」「夢」等の常套句への収束が目立つ。
- :waka_extraction(14b)はcreateできた句は「create/ok」（モーラ厳密一致）が多く、「石畳」「格子の影」「指先」など具体的な情景描写（[[sono74_status]]のgaze_path機構の効果と整合）が見られるが、forced_zatsuに落ちた句（20,30,90）は:direct同様「月の光」「夢の果て」といった常套表現に収束している。
- 全体として、:waka_extraction(14b)は「成功時の質」は:directを上回るが「失敗率（生成失敗・forced_zatsu率）」も上回るというトレードオフが本比較でも再確認された（[[sono76_14b_status]]のA層到達率17.1%→29.0%改善／Step3構成比67.4%→70.6%の記述と整合）。

---

## まとめ

1. **ng違反**: :waka_extraction(14b)は「生成失敗」が突出（176件、:directの3倍）。式目系（句去・一座一句物）は:waka_extraction(14b)の方が少ない。句数（季、特に秋）偏重はどちらにも共通。
2. **forced_zatsu採用**: :waka_extraction(14b)は18/100句、:directは6/100句。約3倍。
3. **maeku確認**: callsログには存在しない。stepwise_stepsログ側にのみ存在（コミット96c90d8）。
4. **step3_mora_rewrite**: 4,385回／100句、平均43.9回。125回で頭打ちの句が7件あり、forced_zatsu採用句と大きく重複。
5. **句サンプル**: :direct=常套句中心で安定、:waka_extraction(14b)=成功時は具体的情景描写だが失敗時は同様の常套句に収束。

---

## 6. 秀句選出（其の七十八 Phase 2 タスク2）

選出基準: create/ok採用（forced_zatsu不可）・attempt1一発生成・前句との付けの妙・常套句（「月の光」「夢の果て」等）を避けた具体的情景。

両ログとも上記基準を満たす候補は多数あったが、以下は式の連続性（同一パターンの繰り返し・文法的に不完全な体言止め等）を除外した上での選出。

### 8b/:direct

【verse_no 20】
前句：からくも我は夢に溺れる
付句：夜の海に心を沈めしにけり

解説：前句の「夢に溺れる」を、付句は「心を沈める」という近い動詞へ言い換えつつ、場を「夜の海」という具体的景へ転じている。「溺れる→沈める」「夢→夜の海」の縁語的な発展が滑らかで、抽象的な心情句だった前句を情景のある句へ格上げしている。:direct全体では「月の光」「風の音」に偏りがちな中で、この一句は常套句に頼らず成立している。

【verse_no 63】
前句：たこが浦浪に揺れしゆかし
付句：潮の音に心を寄せし久しき

解説：前句の視覚的な波の揺れを、付句は聴覚（潮の音）と心情（心を寄せし）へ転換している。「景から情へ」という連歌の典型的な付け方が丁寧に踏まれており、语彙も「潮」「久しき」など海辺の景に即して選ばれている。

【verse_no 72】
前句：風の音も聞こえぬ静かな森に
付句：幽霊の手が木の実を揺らす

解説：8b/:direct中で最も独自性が高い一句。「風の音すら聞こえない静けさ」という前句が暗に示す“では何が動いているのか”という問いに対し、「幽霊の手」という超自然的な答えを返す心付け（意味的な発展）になっている。「幽霊」「木の実」はログ全体で他に登場しない語であり、頻出する「月」「夢」「風」への収束から外れた数少ない例。

### 14b/:waka_extraction

【verse_no 11】
前句：市井の気配やさしくかかり
付句：茶碗の縁に指紋が溶けゆく空

解説：前句の「市井（町）の気配」という広い視野を、付句は「茶碗の縁の指紋」という極小の私的な対象へ一気にズームインさせている。この遠景から近景への急激な転換は、WakaPersonaのgaze_path機構（[[sono74_status]]）が意図した「具体的な情景描写」の効果が最も表れた例といえる。「指紋が溶けゆく空」という体言止めも常套句を避けた独自の結句になっている。

【verse_no 34】
前句：鹿の目露に映じて消
付句：しぐれの音にかきむせば格子の間

解説：前句の「鹿の目に映る露が消える」という自然の微細な情景から、付句は「しぐれの音に咽ぶ」人の感情、そして「格子の間」という建築的・人間的な近景へ転じている。動物→人間、自然の消失→人の情という二重の転換が一句の中に収まっており、14b版の中でも情景の運びに無理がない。

【verse_no 100】
前句：風の音木に揺れる葉揺るぐ
付句：石の上に置かれた水鉢の底

解説：百韻の最終句（挙句）。前句の「風で葉が揺れる」という動的な情景を、付句は「石の上の水鉢の底」という静止した景で受け止め、動から静への転換で一巻を落ち着かせている。「水鉢の底」という具体的で慎ましい結びは、常套句（月・夢等）に頼らずに終息感を出せている数少ない例。
