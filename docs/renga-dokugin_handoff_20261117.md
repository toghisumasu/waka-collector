# 連歌独吟 向け引き継ぎメモ（waka-collector 品質基盤の整備）

作成: 2026-11-17 / 対象リポジトリ: waka-collector（連歌独吟のコードを含む）

## 背景
「AIエージェントに自律開発させるには、決定論的な制約（Lint・型・テスト）で土台を固めるのが先」という考えから、再発しがちな不具合を機械的に止める仕組みを段階的に入れている。第1段階として waka-collector の整備を実施。

## 完了したこと（main に反映済み・未push）
- `b645971` style: rubocop -a で基準を0にする（87ファイル、Layout/Style系のみ。`rubocop` は no offenses）
- `f541f8a` chore: `.git-blame-ignore-revs` に上記コミットの40桁ハッシュを登録（`git blame` で整形コミットを無視）
- 環境: Ruby 3.3.6 / `.ruby-version` 一致

## 現状の課題: rspec が赤（173 examples, 19 failures, 20 pending）
mainでも同数で、今回の整形が原因ではない（元から失敗）。内訳:
- `spec/controllers/rengas_controller_spec.rb` 11件: `fetch_verse_history` / `build_verse_history` / `build_mecab` が RengasController に無い。D-41-1（前句二重カウント）回帰テストを含む。移動先は未確認
- `spec/models/waka_spec.rb` / `spec/requests/wakas_spec.rb` 5件: factory が旧カラム名（`upper_phrase` 等）。現行は `upper_phrase_text` / `lower_phrase_text`
- `spec/services/stepwise_*` 3件: `build_length_adjust_prompt` は引数3個、steps は step1 / step2 / step1.5 / step4 構成
- pending 20件: `WAKA_UNIDIC_DICDIR` 未設定（環境依存）と、scaffold のまま空の view spec

重要: D-41-1 回帰テストが赤のままだと、連歌生成の既知バグ（前句二重カウントによる句数え誤却下）の再発を検知できない。

## 次の作業（順序）
1. ブランチ `fix/stale-specs` で spec/factory のみ修正（実装は触らない）→ `0 failures`
2. OllamaClient の temperature テスト追加（`options` 内にあり、トップレベルに無いこと）。過去に2回再発（0c3a1d6, 863f7d0）
3. 辞書整合性チェック（季語・式目の登録漏れ、重複、矛盾）。薄・すすき、嵐、野分、「しも」誤検出など再発多数
4. 配線の結合テスト（ichiza / kuzari チェッカーが本番生成経路で実際に呼ばれること）。c6ac7d5 型の不具合は本番走行でしか発見できなかった
5. 集計・実験スクリプトのロジックを `lib/` へ移し、小さなテストを付ける
6. CI で `rspec` と `rubocop` を必須化

## 履歴から見た再発パターン（コミットメッセージからの読み取り）
- OllamaClient の temperature 指定位置: 2回
- 季語・辞書の登録漏れや誤判定: 5件以上
- 配線バグ（実装したが本番経路で未使用）: 3件以上
- 集計・実験スクリプトの誤カウント: 4件以上
- nil クラッシュ、前句二重カウント、off-by-one: 各1〜3件

RuboCop のカスタム Cop より、テスト・整合性チェックのほうが向いている。

## 備考
- Gemfile に `csv` を足すと Ruby 3.4 移行時の警告が消える
- 本番（ConoHa VPS）は一時閉鎖中。再開時は `.ruby-version` と `Gemfile.lock` を揃える
