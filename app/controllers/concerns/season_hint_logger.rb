# frozen_string_literal: true

# 其の五十二 D-52-1: ShikimokuChecker#compute_season_hintが返す
# must_switch/must_continueの発火状況を可視化するための共通ログ処理。
# RengasController（Web版）とobserve_production_hyakuin.rb（観測版）の
# 両方から呼ばれ、ログフォーマットの乖離を防ぐ（候補D）。
module SeasonHintLogger
  def log_season_hint(next_constraints, verse_no:)
    hint = next_constraints[:season_hint]
    return unless hint && hint[:current]

    Rails.logger.info \
      "[SeasonHint] verse_no=#{verse_no} season=#{hint[:current]} " \
      "count=#{hint[:count]} must_switch=#{hint[:must_switch]} " \
      "must_continue=#{hint[:must_continue]}"
  end
end
