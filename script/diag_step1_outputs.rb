# frozen_string_literal: true

# diag_step1_outputs.rb — 其の七十六 Phase A 追加診断：Step1（自由詠み）の実出力を見る
#
# 使用法:
#   bundle exec rails runner script/diag_step1_outputs.rb sono76_phaseA_20260729
#
# script/observe_waka_extraction.rb の走行ではStep1の応答テキストを記録して
# いなかったため、「最初の生成プロンプトに対してモデルが何を返すのか」が
# 後から確認できなかった。本スクリプトは指定したobservation_batchのRenga
# レコード列から各句の前句・履歴・式目制約（forbidden_bui / season_hint）を
# 再構築し、StepwiseWakaGeneratorのStep1（generate_free_verse）だけを1回ずつ
# 呼んで、投入したseed・選ばれたペルソナ・返ってきた和歌・その音数を表示する。
#
# seed（@pool.sample）とペルソナ（未指定時はbest_match→なければランダム）が
# 乱数に依存するため、元の走行と同一の出力にはならない。あくまで「同じ前句・
# 同じ制約でStep1に何が返るか」を観察するための再現診断であり、app/配下は
# 一切改修しない（private メソッドをsendで呼ぶだけ）。

BATCH = ARGV[0].presence or raise "observation_batchを指定してください"

class Diag; include VerseTextAnalysis; end
diag       = Diag.new
controller = RengasController.new
nm         = controller.send(:build_mecab)
bui_dict   = BuiDictionary.new
pool_all   = Rails.cache.fetch("seed_pool_v2", expires_in: 1.hour) { nil }

rengas = Renga.where(observation_batch: BATCH).order(:id)
raise "observation_batch=#{BATCH} のRengaが見つかりません" if rengas.empty?

puts "=" * 78
puts "Step1（自由詠み）実出力診断  batch=#{BATCH}  対象#{rengas.size}句"
puts "※seed・ペルソナは乱数依存のため、元の走行と同一の出力にはなりません"
puts "=" * 78

rengas.each_with_index do |renga, idx|
  verse_no    = idx + 1
  maeku       = renga.maeku
  maeku_mora  = KuValidator.new(maeku).count_mora
  maeku_type  = KuValidator.nearest_verse_type(maeku_mora)
  next_type   = (maeku_type == :chouku) ? :tanku : :chouku

  history          = controller.send(:build_verse_history, renga.previous_renga_id, maeku, maeku_type,
                                     nm: nm, bui_dict: bui_dict)
  next_constraints = ShikimokuChecker.new.next_constraints(history)
  verse_history    = controller.send(:fetch_verse_history, renga.previous_renga_id)
  used_waka_ids    = controller.send(:fetch_used_waka_ids, renga.previous_renga_id)

  constraints = {
    verse_history: verse_history,
    forbidden_bui: next_constraints[:forbidden_bui],
    season_hint:   next_constraints[:season_hint],
    used_waka_ids: used_waka_ids,
    generation_strategy: :waka_extraction
  }

  # RengaGeneratorと同じ手順でpoolを構築・filterする（filter_poolはprivate）
  generator = RengaGenerator.new(maeku, [], next_type, constraints: constraints)
  pool      = Rails.cache.fetch("seed_pool_v2", expires_in: 1.hour) { generator.send(:build_seed_pool, nm) }
  pool      = generator.send(:filter_pool, pool)

  stepwise = StepwiseWakaGenerator.new(maeku, next_type, constraints: constraints,
                                       pool: pool, nm: nm, bui_dict: bui_dict)

  seed         = pool.sample
  persona      = WakaPersona.resolve(nil, maeku)
  persona_kind = WakaPersona.best_match(maeku) ? "best_match（前句語彙一致）" : "ランダム（一致なし）"
  season_label = stepwise.send(:season_label_for, seed)

  t0        = Time.now
  free_text = stepwise.send(:generate_free_verse, seed, persona)
  elapsed   = (Time.now - t0).round(2)

  puts
  puts "-" * 78
  puts "【#{verse_no}句目】 前句: #{maeku}   → 詠む句種: #{next_type}"
  puts "  seed（連想語）: #{seed && seed[:surface]}   季節ラベル: #{season_label}"
  puts "  ペルソナ: #{persona[:name]}（#{persona_kind}）"
  puts "  禁じ手: #{(next_constraints[:forbidden_bui] || []).join('・').presence || 'なし'}"
  if free_text.nil?
    puts "  Step1出力: （3回の内容判定往復をすべて失敗＝nil）  #{elapsed}秒"
    next
  end

  mora = diag.morphemes_of(free_text, nm).sum { |m| m[:mora] }
  band =
    if mora > StepwiseWakaGenerator::FREE_VERSE_MORA_LONG_THRESHOLD  then "長すぎ→Step1.5 condense発動"
    elsif mora < StepwiseWakaGenerator::FREE_VERSE_MORA_SHORT_THRESHOLD then "短すぎ→Step1.5 expand発動"
    else "適正範囲（Step1.5スキップ）"
    end

  puts "  Step1出力: #{free_text}"
  puts "  → #{mora}音（#{band}）  #{elapsed}秒"
end

puts
puts "=" * 78
