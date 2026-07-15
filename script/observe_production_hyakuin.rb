# frozen_string_literal: true

# observe_production_hyakuin.rb — 其の三十九：本番コードパスによる百韻観測
#
# 使用法:
#   bundle exec rails runner script/observe_production_hyakuin.rb          # 100句
#   bundle exec rails runner script/observe_production_hyakuin.rb 5        # スモークテスト（5句）
#
# RengasController#createが呼んでいるのと同じ順序でRengaGenerator→KuValidator→
# ShikimokuCheckerを直接呼び出す薄いラッパー。コントローラ自体は経由しないが、
# 履歴構築ロジック（fetch_verse_history/build_verse_history/build_mecab/
# season_from_text）はコントローラの private メソッドをそのまま再利用し、
# 本番と全く同じ計算になるようにする（ロジックの二重実装によるズレを避けるため）。
#
# 出力: log/observation_sono39_<実行日>.jsonl（試行ごとのJSON Lines）＋標準出力サマリー

require "json"

TOTAL_VERSES = (ARGV[0].presence || 100).to_i
MAX_RETRY    = 5 # script/dryrun_hyakuin.rbのMAX_RETRYと同じ閾値

RUN_DATE   = Time.zone.now.strftime("%Y%m%d")
BATCH_NAME = "sono39_#{RUN_DATE}"
LOG_PATH   = Rails.root.join("log", "observation_sono39_#{RUN_DATE}.jsonl")

# controllerの本体ロジックは変更禁止だが、履歴構築の private メソッドは
# 観測の忠実性のためそのまま呼び出す（新しいインスタンスを作るだけで
# リクエスト/レスポンスには依存しない）。
controller = RengasController.new

log_file = File.open(LOG_PATH, "a")

def log_line(file, hash)
  file.puts(hash.to_json)
  file.flush
end

def violation_category(v)
  case v[:type]
  when :ichiza_duplicate            then "一座一句物"
  when :chotan_chigai               then "長短交互"
  when :kukazo_over, :kukazo_under  then "句数"
  when :teiza_tsuki, :teiza_hana    then "定座"
  else "句去" # :type キーなし＝句去（ShikimokuChecker.describeの後方互換分岐と同じ判定）
  end
end

def violation_detail(v)
  case v[:type]
  when :ichiza_duplicate then v[:word]
  when :chotan_chigai    then "#{v[:verse_type]}→#{v[:expected]}"
  when :kukazo_over      then (v[:season] || v[:bui]).to_s
  when :kukazo_under     then v[:season].to_s
  when :teiza_tsuki, :teiza_hana then v[:fold].to_s
  else v[:bui].to_s
  end
end

def violation_label(v)
  "#{violation_category(v)}:#{violation_detail(v)}"
end

class RetryExhausted < StandardError; end

nm       = controller.send(:build_mecab)
bui_dict = BuiDictionary.new

# 発句選定：dryrun_hyakuin.rbは既知の古典句（東風ふかば…）を固定HAKKUとして
# 使うが、こちらは本番DB（Waka）からランダムに選ぶ。KuValidatorでngな
# （形態素2未満・音数が17/14から2音以上ずれる）候補は発句として不適切なので
# 引き直す。
hakku_waka = nil
hakku_text = nil
20.times do
  candidate_waka  = Waka.where.not(upper_phrase_text: [nil, ""]).order(Arel.sql("RANDOM()")).first
  candidate_text  = candidate_waka.upper_phrase_text.strip
  candidate_mora  = KuValidator.new(candidate_text).count_mora
  candidate_type  = KuValidator.nearest_verse_type(candidate_mora)
  check           = KuValidator.new(candidate_text, type: candidate_type).validate
  next if check[:result] == "ng"

  hakku_waka = candidate_waka
  hakku_text = candidate_text
  break
end
raise "発句として使えるWakaが見つかりませんでした（20回試行）" unless hakku_text

log_line(log_file, {
  verse_no: 0, attempt: 0, text: hakku_text, waka_id: hakku_waka.id,
  mora_result: "ok", shikimoku_result: nil, violations: [], action: "seed"
})

puts "=" * 60
puts "其の三十九 本番コードパス観測開始（目標#{TOTAL_VERSES}句）"
puts "発句: #{hakku_text}（Waka##{hakku_waka.id}）"
puts "ログ: #{LOG_PATH}"
puts "=" * 60

maeku              = hakku_text
previous_renga_id  = nil
total_attempts     = 0
total_ng           = 0
violation_counts   = Hash.new(0)

(1..TOTAL_VERSES).each do |verse_no|
  maeku_mora      = KuValidator.new(maeku).count_mora
  maeku_type      = KuValidator.nearest_verse_type(maeku_mora)
  next_verse_type = (maeku_type == :chouku) ? :tanku : :chouku

  # 本番同様、前句（maeku）自体のモーラチェック。生成した付句は
  # RengaGenerator内部でmora差<=1のみ許容するため通常はok/warningになるが、
  # 万一（全attempt失敗などで）ngな文字列が混入した場合は連鎖破綻として
  # 即座に人間へ報告する。
  maeku_check = KuValidator.new(maeku, type: maeku_type).validate
  if maeku_check[:result] == "ng"
    log_line(log_file, {
      verse_no: verse_no, attempt: 0, text: maeku, mora_result: "ng",
      shikimoku_result: nil, violations: [], action: "abort_maeku_ng"
    })
    raise "verse_no=#{verse_no}: 前句「#{maeku}」がKuValidatorでngのため中断（連鎖破綻の可能性）"
  end

  created = false

  MAX_RETRY.times do |i|
    attempt = i + 1
    total_attempts += 1

    verse_history = controller.send(:fetch_verse_history, previous_renga_id)
    tsugeku = RengaGenerator.new(
      maeku, [], next_verse_type,
      constraints: { verse_history: verse_history }
    ).generate_tsugeku

    if tsugeku.blank?
      total_ng += 1
      action = (attempt == MAX_RETRY) ? "abort" : "retry"
      log_line(log_file, {
        verse_no: verse_no, attempt: attempt, text: tsugeku.to_s, mora_result: "ng",
        shikimoku_result: nil, violations: ["生成失敗"], action: action
      })
      raise RetryExhausted, "verse_no=#{verse_no}: #{MAX_RETRY}回試行しても句が生成できませんでした" if attempt == MAX_RETRY
      next
    end

    mora_check = KuValidator.new(tsugeku, type: next_verse_type).validate
    if mora_check[:result] == "ng"
      total_ng += 1
      action = (attempt == MAX_RETRY) ? "abort" : "retry"
      log_line(log_file, {
        verse_no: verse_no, attempt: attempt, text: tsugeku, mora_result: "ng",
        shikimoku_result: nil, violations: [], action: action
      })
      raise RetryExhausted, "verse_no=#{verse_no}: #{MAX_RETRY}回試行してもモーラ判定ngが解消しませんでした" if attempt == MAX_RETRY
      next
    end

    candidate = {
      bui:        bui_dict.detect_all(tsugeku, nm),
      season:     controller.send(:season_from_text, tsugeku),
      verse_type: next_verse_type
    }
    history = controller.send(:build_verse_history, previous_renga_id, maeku, maeku_type, nm: nm, bui_dict: bui_dict)

    checker    = ShikimokuChecker.new
    violations = checker.all_violations(history, candidate)
    violations += checker.ichiza_violations(history, candidate)
    violations += checker.chotan_violations(history, candidate)

    if violations.any?
      total_ng += 1
      labels = violations.map { |v| violation_label(v) }
      violations.each { |v| violation_counts[violation_category(v)] += 1 }
      action = (attempt == MAX_RETRY) ? "abort" : "retry"
      log_line(log_file, {
        verse_no: verse_no, attempt: attempt, text: tsugeku, mora_result: mora_check[:result],
        shikimoku_result: "ng", violations: labels, action: action
      })
      raise RetryExhausted, "verse_no=#{verse_no}: #{MAX_RETRY}回試行しても式目ngが解消しませんでした" if attempt == MAX_RETRY
      next
    end

    style_result = { "result" => "ok", "issues" => [], "breakdown" => [] }
    renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            tsugeku,
      maeku_author:       "観測スクリプト",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: style_result,
      honka_reference:    [],
      previous_renga_id:  previous_renga_id,
      observation_batch:  BATCH_NAME
    )

    log_line(log_file, {
      verse_no: verse_no, attempt: attempt, text: tsugeku, mora_result: mora_check[:result],
      shikimoku_result: "ok", violations: [], action: "create"
    })

    puts "  #{verse_no}/#{TOTAL_VERSES}句目 OK（#{attempt}回目の試行）: #{tsugeku}"

    previous_renga_id = renga.id
    maeku              = tsugeku
    created             = true
    break
  end

  raise "verse_no=#{verse_no}: 想定外の状態（createされずループ終了）" unless created
end

log_file.close

puts "=" * 60
puts "観測完了"
puts "総試行回数: #{total_attempts}"
puts "総ng回数:   #{total_ng}"
ng_rate = total_attempts.positive? ? (total_ng.to_f / total_attempts * 100).round(1) : 0.0
puts "ng率:       #{ng_rate}%"
puts "-" * 60
puts "違反種別の内訳（降順）:"
violation_counts.sort_by { |_, count| -count }.each do |category, count|
  puts "  #{category}: #{count}件"
end
puts "=" * 60
