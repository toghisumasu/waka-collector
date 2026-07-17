# 依頼書: 其の四十四 — next_constraints配線（B-4: forbidden_bui / season_hint → RengaGenerator）

<!--
  テンプレート規約:
  - 本ファイルが仕様書であり検収基準。実装側はここに書かれていないことを勝手にやらない。
  - 実装側は §7 の作業ログを更新しながら進める（中断・再開を冪等にするため）。
  - 山括弧〈 〉はプレースホルダ。流用時に書き換える。
-->

## 1. 目的

其の四十一(T5)の調査で判明した通り、`ShikimokuChecker`側には`next_constraints`（`forbidden_bui`/`season_hint`）が実装・テスト済みであるにもかかわらず、本番経路（`RengasController` → `RengaGenerator`）にも観測スクリプトにも一切配線されておらず、`script/dryrun_hyakuin.rb`（検証ハーネス）のみが使用している状態である。

本セッションでは、`ShikimokuChecker`が算出した`next_constraints`を実際に`RengaGenerator`の`filter_pool` / `kigo_hint` / `build_full_prompt`に渡し、次句生成時にメンタムさんへのヒントとして反映されるよう配線する。

**背景（合意事項）**: 其の四十一T7で「D-41-1修正 → 観測 → next_constraints配線」の順序に人間合意済み。其の四十二(D-41-1修正)・其の四十三(Run6再観測、効果実証済み)を経て、ノイズの少ないクリーンな状態でB-4に着手する条件が整った。

## 2. 前提環境（Mac mini）

- マシン: Mac mini M4 / macOS Tahoe / Tailscale IP 100.71.107.6
- プロジェクト: `/Volumes/externalHDD/projects/waka-collector`
- Ruby 3.3.6 / Rails 7.2.3 / PostgreSQL 16.13 / Gemは `vendor/bundle`
- **作業開始前チェック（必須・全タスクの前提）**:
  ```sh
  cd /Volumes/externalHDD/projects/waka-collector
  git log -5 --oneline   # b8db2af(D-41-1修正)がHEADに含まれていることを確認
  git status
  bundle exec ruby script/verify_shikimoku.rb   # 88 pass / 0 fail であること
  ```
  ゲートチェックが崩れていたら**作業を中断して人間に報告**（先へ進まない）。

## 3. 不変条件（壊してはいけないもの）

- D-19-1: `build_full_prompt`内の冒頭指示文は変更しない
- D-19-5: ShikimokuCheckerは隣接ペアのみ判定（D-38-1で本体は置換済み、この設計自体は本タスクで変更しない）
- D-33-1: RengasController / RengaGenerator / ShikimokuChecker 本体は人間承認なしに変更しない
- D-36-1: 履歴パスに含めるbui情報はB層BuiDictionary確定値のみ。C層LLM自己申告buiを混在させない
- D-41-1: build_verse_historyの二重カウント修正（其の四十二実装済み）を壊さない
- ShikimokuChecker はA層の純粋関数のまま（Rails/MeCab/Ollama依存を持ち込まない） — `next_constraints`の算出ロジック自体は既存のまま、呼び出し側の配線のみが対象
- ゲート条件: `bundle exec ruby script/verify_shikimoku.rb` が 88 pass / 0 fail

## 4. 作業範囲 / 禁止範囲

| 区分 | 対象 |
|---|---|
| 触ってよい | `RengaGenerator`内の`filter_pool` / `kigo_hint` / `build_full_prompt`呼び出し部分への`next_constraints`受け渡し配線、`RengasController`側で`ShikimokuChecker`の`next_constraints`戻り値を次句生成に渡す部分、関連spec |
| 禁止 | `ShikimokuChecker`本体の判定ロジック変更、`build_full_prompt`冒頭指示文(D-19-1)の変更、`build_verse_history`(D-41-1修正済み部分)への追加変更、DBスキーマ変更 |

## 5. タスク一覧（依存順）

- [x] **T1** 現状配線の再確認（読み取り専用）
      其の四十一T5の調査結果を踏まえ、`ShikimokuChecker#next_constraints`の戻り値の型・内容（`forbidden_bui`/`season_hint`の形式）と、`script/dryrun_hyakuin.rb`での使用箇所を確認する。
      → 確認完了。`next_constraints`は`{ verse_type:, forbidden_bui: [...], season_hint: { current:, count:, must_continue:, must_switch: } }`を返す。`RengaGenerator`の`filter_pool`/`kigo_hint`/`build_full_prompt`は既にこの形式を消費する実装済みで、無変更のまま使えることを確認した。
- [x] **T2** 配線設計案の提示（実装前・必須）
      `RengasController`が`ShikimokuChecker`から`next_constraints`を受け取り、`RengaGenerator`の`filter_pool` / `kigo_hint` / `build_full_prompt`にどう渡すかの設計案（diff）を人間に提示する。**D-33-1に基づき、明示的な承認を得てから実装に進むこと。承認なしでのコミットは受け入れ条件を満たさない。**
      → diffを提示し、人間の承認を得た。ただし承認時、`script/observe_production_hyakuin.rb`側の同様の配線は**対象外**とする指示を受けた（T5は同スクリプトを変更しない別の方法で行う）。
- [x] **T3** 承認後、実装
      T2で承認された設計案どおりに実装する。
      → `app/controllers/rengas_controller.rb#create`のみ実装（承認された範囲通り）。
- [x] **T4** ゲートチェック・回帰テスト
      `bundle exec ruby script/verify_shikimoku.rb`が88 pass/0 failを維持することを確認。関連spec（RengasController, RengaGenerator）を実行し、既存の失敗件数から増加していないことを確認。
      → 88 pass/0 fail維持。`spec/controllers/rengas_controller_spec.rb` 11 examples全成功（D-41-1回帰含む）。
- [x] **T5** 動作確認（小規模観測）
      本番経路で`next_constraints`が実際に反映されているかを、小規模（10〜20句程度）の観測実行で確認する。forbidden_buiに該当する語が候補から除外されているか、season_hintが反映されているかをログから確認。
      → `script/observe_production_hyakuin.rb`は変更しない方針のため、リポジトリ非管理の使い捨てスクリプトで15句分を検証（`observation_batch: "sono44_b4_verify"`としてDB保存）。`@constraints`への配線OK=15/15、forbidden_bui発火時（"植物"、5回）に生成句のbuiと重複した回数0/15、season_hintのmust_continue（4回）・must_switch（2回）が正しく発火し、must_switch発火直後に実際の季節転換（秋→春）を確認。
- [x] **T6** ドキュメント更新
      `docs/architecture_decisions.md`に配線完了を記録（新規決定事項として番号を振る、例: D-44-1）。`docs/依頼書_其の四十四_...md`の完了状況も追記。
      → D-44-1として記録済み。本ファイルの§7・§9も更新済み。

## 6. 受け入れ条件（終了判定 = ここがUNTIL条件）

```sh
cd /Volumes/externalHDD/projects/waka-collector
bundle exec ruby script/verify_shikimoku.rb   # 88 pass / 0 fail 維持
git log -1 --oneline   # 実装コミットがT2承認後であることが分かること
```

**判定ループ規約**:
1. T1〜T6が全て完了し、ゲートチェックが維持され、T5の動作確認で`next_constraints`の反映が確認できた → 完了。§7に記録して終了
2. T2の設計案が人間から差し戻された場合 → 修正案を再提示し、再度承認を得てから実装に進む（実装を先に進めない）
3. ゲートチェックが崩れた場合 → 即座に作業を中断し人間に報告

## 7. 作業ログ（実装側が追記する）

| 日時 | タスク | 結果 | メモ |
|---|---|---|---|
| 2026-07-17 | ゲートチェック | 88 pass/0 fail、HEAD=b8db2af確認 | 開始前提クリア |
| 2026-07-17 | T1: 現状配線確認 | `next_constraints`の型・`RengaGenerator`側の消費実装を確認 | RengaGenerator本体は無変更で使える結論 |
| 2026-07-17 | T2: 設計案提示 | `RengasController#create`の再構成diffを提示 | 人間承認。ただしobserve_production_hyakuin.rbは対象外との指示 |
| 2026-07-17 | T3: 実装 | `app/controllers/rengas_controller.rb#create`のみ変更 | history/checker/next_constraints構築をRengaGenerator呼び出し前に繰り上げ |
| 2026-07-17 | T4: ゲート・回帰テスト | verify_shikimoku.rb 88 pass/0 fail、rengas_controller_spec 11 examples成功 | D-41-1回帰テストも無傷 |
| 2026-07-17 | T5: 動作確認 | 使い捨てスクリプト（observation_batch: sono44_b4_verify）で15句生成 | 配線OK 15/15、forbidden_bui重複0/15、season_hint must_switch後に季節転換を確認 |
| 2026-07-17 | T6: ドキュメント更新 | architecture_decisions.mdにD-44-1追記、本ファイル更新 | |

## 8. ロールバック

- 実装がT4のゲートチェックで失敗した場合、直前コミットに`git revert`で戻す
- 本番経路への配線変更のため、T5の動作確認でメンタムさんの生成品質に予期しない悪影響（極端な生成失敗率上昇など）が見られた場合は、配線部分のみを無効化できるよう、フォールバック（next_constraintsがnilなら既存動作)を必ず維持すること

## 9. 次回への申し送り事項（本セッション終了時に更新）

- B-4配線の効果測定結果：配線自体は15/15で正しく機能していることを確認済み（`@constraints`の値、forbidden_bui回避、season_hintのmust_continue/must_switch発火と季節転換）。ただし式目ng却下率・generate_fail率への実際の効果は、今回の15句規模の使い捨て検証では測定していない。次回、`script/observe_production_hyakuin.rb`で100句規模の観測を行い、其の四十三（Run6、配線前）と比較することを推奨する。
- `script/observe_production_hyakuin.rb`への同様の配線は今回対象外（人間の判断）。次回観測前に、配線するかどうかを改めて判断すること（配線しない場合、観測結果は「配線なし」の状態のままになる点に注意）
- T5で作成した検証用DBレコード（`observation_batch: "sono44_b4_verify"`、15件、途中生成失敗による空句・履歴の乱れを含む）は本番の百韻とは無関係の使い捨てデータ。削除するかどうかは人間の判断を仰ぐこと
- 其の四十バックログ（observe_production_hyakuin.rbのrescue範囲見直し・stderrキャプチャ、A系統）の着手要否：未定
