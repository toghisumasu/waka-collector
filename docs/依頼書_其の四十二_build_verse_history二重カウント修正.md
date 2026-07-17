# 依頼書: 其の四十二 — build_verse_history前句二重カウントバグ修正（D-41-1）

<!--
  テンプレート規約:
  - 本ファイルが仕様書であり検収基準。実装側はここに書かれていないことを勝手にやらない。
  - 実装側は §8 の作業ログを更新しながら進める（中断・再開を冪等にするため）。
  - 山括弧〈 〉はプレースホルダ。
-->

## 1. 背景

其の四十一（`docs/observation_analysis_其の四十一.md` §4、`docs/architecture_decisions.md`
D-41-1）で、`RengasController#build_verse_history`に**直前1句を履歴に二重カウントする
バグ**を発見・実機で確定させた。

`fetch_verse_chain(previous_renga_id, limit: 9)`が返す配列は、`previous_renga_id`自体
（＝直前句`maeku`と同一の句）を末尾に含む再帰CTEの結果である。その直後に
`build_verse_history`が`history << { ..., season: season_from_text(maeku), ... }`で
同じ句をもう一度明示的に追加しているため、直前の1句が常に2回連続してカウントされる。

Run5ログの実データで検証した結果、句数ng却下17件中**8件（47%）がこのバグによる
誤却下**だった（verse34の5回連続却下→forced_zatsuエスカレーションは全てこのバグが
原因）。バグの影響は`kukazo_over`（連続数上限）方向のみで確認されており、
`kukazo_under`（最短規制）方向は表示streakが1大きくずれるだけで結論（ng/ok）は
変わらないことも確認済み（其の四十一 §4-2参照）。

D-19-5（RengaChecker由来・其の三十八でShikimokuCheckerに置換され既に解消済み）とは
別の不具合であり、D-41-1として区別して記録されている。

**本依頼書は、D-41-1の修正のみを対象とする。** 其の四十一 T7で提案し人間合意済みの
優先順位（D-41-1修正 → 観測 → next_constraints配線＝B-4）に従い、まずこのバグを
修正する。

## 2. 目的

`RengasController#build_verse_history`の二重カウントを解消し、`ShikimokuChecker`に
渡される`history`が各句を正確に1回ずつ含むようにする。

## 3. 前提環境

- `/Volumes/externalHDD/projects/waka-collector`、Ruby 3.3.6 / Rails 7.2.3
- **作業開始前チェック（必須）**:
  ```sh
  cd /Volumes/externalHDD/projects/waka-collector
  git log -3 --oneline
  git status
  bundle exec ruby script/verify_shikimoku.rb   # 88 pass / 0 fail であること
  ```
  ゲートチェックが崩れていたら**作業を中断して人間に報告**。

## 4. 不変条件（壊してはいけないもの）

- D-19-1〜D-41-1（`docs/architecture_decisions.md`記載の全決定事項）
- `bundle exec ruby script/verify_shikimoku.rb` が 88 pass / 0 fail
- `RengaGenerator`・`ShikimokuChecker`本体は無変更（`ShikimokuChecker`側の判定ロジック
  自体は正しく、修正対象ではない）
- `RengasController`内、`build_verse_history`以外のメソッドは無変更
  （`fetch_verse_chain`・`fetch_verse_history`・`build_mecab`・`season_from_text`等、
  他の私有メソッドには触れない。ただし`fetch_verse_chain`の**呼び出し方**
  ＝引数を`build_verse_history`内で変える形の修正は許容する）
- **D-33-1の人間承認プロセス**：`RengasController`は「本体は人間承認なしに変更しない」
  対象である。本依頼書はその承認を**事前に**（本依頼書自体の作成・合意をもって）
  `build_verse_history`メソッドに限定して得ているが、**実際に適用する修正コード
  （diff）自体は、コミット前に人間に提示し明示的な承認を得ること**（§6 T2参照）。
  提案なしに直接実装・コミットしない。

## 5. 作業範囲 / 禁止範囲

| 区分 | 対象 |
|---|---|
| 触ってよい | `app/controllers/rengas_controller.rb`の`build_verse_history`メソッドのみ、関連spec（新規 or 既存拡張）、`docs/architecture_decisions.md`（D-41-1の更新・追記） |
| 禁止 | `RengasController`内の他メソッド、`RengaGenerator`・`ShikimokuChecker`本体、DBスキーマ、`script/observe_production_hyakuin.rb`（其の四十バックログとして別依頼書）、next_constraints配線（B-4、次回以降） |

## 6. タスク一覧（依存順）

- [ ] **T1** ゲートチェック（§3参照）
- [ ] **T2** 修正案の設計・提示（★実装前に人間承認が必須）
      `build_verse_history`の現状コードを再確認し、二重カウントを解消する修正案を
      diff形式で提示する。設計時に以下を必ず考慮すること：
      - `previous_renga_id`が blank（verse1相当、`fetch_verse_chain`が`[]`を返す
        ケース）でも`maeku`自身の情報がhistoryから失われないこと
        （現状はこのケースで`history`が`[maekuエントリ]`の1件になる。修正後も
        この挙動は維持すること）
      - `chain`が非空の場合、`chain`の末尾（`previous_renga_id`自体の行）と
        明示的に追加する`maeku`エントリが重複しないようにすること
      - `verse_type`の交互判定（`offset = chain.size - i`によるchouku/tanku交互）
        が、修正後も既存と同じ結果になること（史実上historyの各要素の
        verse_typeが1つずつずれる・重複が消えることでoffset計算の基準が
        変わらないか要確認）
      - 修正案を人間に提示し、**明示的な承認を得てから次のタスクへ進む**。
        承認内容（承認日時・承認された方針の要約）を§8作業ログに記録すること
- [ ] **T3**（承認後）`build_verse_history`の修正を実装
- [ ] **T4** 回帰テストの作成・実行
      `spec/controllers/rengas_controller_spec.rb`（存在しなければ新規、または
      `build_verse_history`を直接呼べる形のspec）で以下を検証する：
      - 其の四十一で特定した8件の誤却下パターン（verse30×2「句数:冬」、
        verse34×5「句数:秋」、verse56×1「句数:秋」相当のシナリオ）が、
        修正後は正しく受理される（ng判定にならない）ことを再現する
      - kukazo_under系のケース（streakが実際より1大きく見えていたが結論は
        変わらなかったパターン）が、修正後も同じ結論（ng）のままであることを
        確認する
      - `previous_renga_id`がblankのケース（history= [maekuのみ]）が
        修正後も変わらないことを確認する
      - `script/analyze_sono41.rb`または同等の手段で、Run5ログの句数ng却下
        17件を修正後のロジックで再評価し、8件が解消されることを定量的に
        再確認してもよい（必須ではないが推奨）
- [ ] **T5** ゲートチェック再確認
      `bundle exec ruby script/verify_shikimoku.rb` が88 pass / 0 fail のまま
      であることを確認する
- [ ] **T6** D-41-1の更新
      `docs/architecture_decisions.md`のD-41-1に修正完了を追記する
      （「現時点では未修正」の記述を「其の四十二で修正済み」に更新し、
      修正内容の要約・コミットハッシュを追記）
- [ ] **T7** 引き継ぎ更新
      `docs/observation_analysis_其の四十一.md`または新規の其の四十二引き継ぎ
      文書に、次のステップ（B-4：next_constraints配線）へ進む準備が整った旨を
      記録する

## 7. 受け入れ条件（終了判定 = ここがUNTIL条件）

```sh
cd /Volumes/externalHDD/projects/waka-collector
bundle exec ruby script/verify_shikimoku.rb   # 88 pass / 0 fail 維持
bundle exec rspec spec/                        # build_verse_history関連の新規/既存specが全緑
```

加えて：
- T2の修正案について、コミット前に人間の明示的承認を得たことが§8作業ログに
  記録されていること（承認なしのコミットは受け入れ不可）
- 其の四十一で特定した8件の誤却下パターンが、回帰テストで「修正後は却下されない」
  ことを示していること

**判定ループ規約**：
1. T1〜T7が全て完了し、上記受け入れ条件を満たす → 完了。§8に記録して終了
2. T2の承認が得られない・修正方針に疑義がある場合 → 実装に進まず、方針を
   再検討して人間に再提示する
3. ゲートチェックが崩れた場合 → 即座に作業を中断し人間に報告
4. **修正は最大2往復まで**。3回目も失敗なら作業を止め、状況を整理して人間に報告

## 8. 作業ログ（実装側が追記する）

| 日時 | タスク | 結果 | メモ |
|---|---|---|---|
| 2026-07-17 | T1: ゲートチェック | 88 pass / 0 fail、clean、HEAD=4199b90 | 作業許可 |
| 2026-07-17 | T2: 修正案（diff）提示 | `history << {...}`に`if chain.empty?`を追加する1行diffを提示 | 窓幅(limit:9)には触れないことを人間から確認質問あり、回答して整合性を確認 |
| 2026-07-17 | T2: 人間承認 | **承認済み**。「この修正案を承認します。実装を進めてください」 | 承認後にT3着手 |
| 2026-07-17 | T3: 実装 | `app/controllers/rengas_controller.rb`の`build_verse_history`末尾1行を修正 | 承認済みdiff通りに適用 |
| 2026-07-17 | T4: 回帰テスト作成・実行 | `spec/controllers/rengas_controller_spec.rb`に4件新規追加（verse30/34/56相当のkukazo_over誤却下解消、verse21相当のkukazo_under結論不変）、既存2件を修正後の正しい期待値に更新。11 examples全成功 | verse34は5回分・verse30は2回分・verse56は1回分の誤却下を代表1ケースずつで検証（同一history・同一mechanism） |
| 2026-07-17 | T5: ゲートチェック再確認 | `verify_shikimoku.rb` 88 pass/0 fail維持、`bundle exec rspec`全体は51 examples中5 failure（既知のWakaファクトリ無関係バグのみ、新規failureなし） | |
| 2026-07-17 | T6: D-41-1更新 | `docs/architecture_decisions.md`のD-41-1を「未修正」から「其の四十二で修正済み」に更新、修正内容・回帰テスト結果を追記 | |
| 2026-07-17 | T7: 引き継ぎ更新 | `docs/observation_analysis_其の四十一.md`にD-41-1解消・B-4着手準備完了を追記 | |

## 9. ロールバック

- 修正は`build_verse_history`メソッド1箇所に限定されるため、1コミットで
  `git revert`により即座に戻せる
- 回帰テストで其の四十一の8件パターンのうち一部しか解消しない場合、または
  新たな副作用（既存に合格していたケースが新たにngになる等）が確認された場合は、
  コミットせず方針を人間に再提示すること
- D-41-1の更新（T6）は他タスクと独立して取り消し可能（文書のみ）

## 10. 次回（B-4着手）への申し送り事項

- **D-41-1修正の完了状況：完了。** `build_verse_history`の二重カウントを解消
  （1行修正）、回帰テスト11 examples全成功、`verify_shikimoku.rb` 88 pass/0 fail維持
- 修正後、改めてRun5相当の観測を行い、句去ng（4件、19%）・句数ng残存分の
  発生状況を確認してからB-4（next_constraints配線）に進むことを推奨
  （其の四十一 T7参照）。**B-4着手の準備は整った。**
