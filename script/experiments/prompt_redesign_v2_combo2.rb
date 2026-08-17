#!/usr/bin/env ruby
# frozen_string_literal: true

# T8: prompt_redesign_v2の追試（前句・concrete_themeを差し替えた組み合わせ2）
#
# 目的: T4〜T7で使用した前句「玉なす月に鹿の声あり野辺の雪」・
# concrete_theme「山の露、秋風」の固定値が交絡要因になっていないかを確認するため、
# 水無瀬三吟百韻から未使用の前句を1つ、未使用の具体的名詞句のconcrete_themeを1つ選び、
# 同一の実験（条件B・C各5回、T7のtheme_echo検出込み）を実施する。
#
# 選定理由:
# - 前句: 水無瀬三吟17句「はるゝまも袖は時雨の旅衣」（柏・長・冬・降物/旅/衣裳）。
#   T4〜T7の固定前句は水無瀬三吟由来ではない創作句であり、季も明示されていなかった。
#   本追試ではdocs/minase_sangin_hyakuin.mdに実在する句を採用し、季（冬）・部立
#   （旅・衣裳）が明確な前句で試すことで、固定前句への依存を排除する。
# - concrete_theme: 「遠寺の鐘、枯野の道」。前句の冬・旅の情景と自然に呼応する
#   具体的名詞句としつつ、「山の露、秋風」とは文字を一切共有しない語を選んだ。
#   これにより、theme_echo型の断片化がテーマ語句そのもの（「山の露」「秋風」という
#   特定の文字列）に起因するのか、それとも「具体的な名詞句を手がかりとして提示する」
#   というプロンプト構造一般に起因するのかを切り分ける。
#
# 実行:
#   bundle exec ruby script/experiments/prompt_redesign_v2_combo2.rb
#
# 出力:
#   tmp/experiments/prompt_redesign_v2_combo2_results.jsonl （10行: 条件B5件+条件C5件）

require_relative 'prompt_redesign_v2'

if __FILE__ == $0
  experiment = PromptRedesignV2Experiment.new(
    maeku: "はるゝまも袖は時雨の旅衣",
    concrete_theme: "遠寺の鐘、枯野の道",
    output_path: File.expand_path('../../../tmp/experiments/prompt_redesign_v2_combo2_results.jsonl', __FILE__)
  )
  experiment.run
end
