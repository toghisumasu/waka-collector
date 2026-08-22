# frozen_string_literal: true

# observe_waka_extraction.rb — 其の七十六 Phase A：:waka_extraction方式のレイテンシ・コスト観測
#
# 使用法:
#   bundle exec rails runner script/observe_waka_extraction.rb            # 10句（Phase Aの既定）
#   bundle exec rails runner script/observe_waka_extraction.rb 5 smoke    # 5句・タグsmoke
#   bundle exec rails runner script/observe_waka_extraction.rb 100 run1   # Phase B（100句）想定
#
# script/observe_production_hyakuin.rb（其の三十九）の構造をそのまま踏襲し、
# 次の2点だけを変えた観測専用スクリプト。app/配下は一切改修しない（差分0行）。
#
#   1. RengaGeneratorへ渡すconstraintsに generation_strategy: :waka_extraction を追加する。
#      これによりStepwiseWakaGenerator（Step1自由詠み→1.5音数調整→2内容判定→
#      3形式整形→4機械抽出）へ委譲される。
#   2. OllamaClient.generate / .chat をスクリプト側でモンキーパッチ（singleton_classへ
#      prepend）し、1呼び出しごとの所要秒数・プロンプト種別・タイムアウト超過を記録する。
#      app/services/ollama_client.rb 自体には手を触れない。
#
# ■ 計測の背景（其の七十六 Phase A の目的）
# :waka_extraction は多段構成のため、1句あたりのOllama呼び出し回数が:directより
# 大幅に多くなり得る。定数から計算した最悪ケースは以下の通り：
#
#   Step1（MAX_CONTENT_RETRIES=3） + Step1.5（MAX_LENGTH_ADJUST_ATTEMPTS=3）
#   + Step3（MAX_REWRITE_ATTEMPTS=5） = 11回
#   × MAX_DRAFT_ATTEMPTS=5          = 55回 / generate_tsugeku 1回
#   × MAX_RETRY=5（本スクリプト）     = 275回 / 句
#
# :direct方式は同条件で最大25回/句なので、最悪で約11倍。実測でどこに収まるかを
# 確認するのが本スクリプトの主目的である。
#
# ■ タイムアウトについて
# 依頼書には「既存300秒設定」とあるが、StepwiseWakaGeneratorの3つのOllama呼び出しは
# いずれも timeout: 180 固定である（stepwise_waka_generator.rb の Step1/1.5/3）。
# 300秒はOllamaClient.generateのデフォルト値で、:waka_extraction経路では使われない
# （forced_zatsuレスキューのOllamaClient.chatのみ300秒）。したがって本スクリプトでは
#   ・1呼び出し180秒超過（=Net::ReadTimeout→RuntimeError化）… 実際の障害点
#   ・1句あたり累積300秒超過                              … 依頼書の参考線
# の両方を記録する。
#
# 出力:
#   log/observation_sono76_<タグ_><実行日>.jsonl        … 試行ごとのJSON Lines（其の三十九と同形式＋時間欄）
#   log/observation_sono76_calls_<タグ_><実行日>.jsonl  … Ollama呼び出し1回ごとのJSON Lines
#   ＋標準出力サマリー（レイテンシ統計を含む）

require "json"

TOTAL_VERSES = (ARGV[0].presence || 10).to_i
RUN_TAG      = ARGV[1].presence
TAG_SUFFIX   = RUN_TAG ? "#{RUN_TAG}_" : ""

MAX_RETRY               = 5   # observe_production_hyakuin.rbと同じ閾値（:directとの比較可能性のため変更しない）
FORCED_ZATSU_MORA_RETRY = 3
TOTAL_ATTEMPT_CAP       = 500

# 1呼び出しの実測値がこれを超えたらタイムアウト相当として集計する（Stepwise側の設定値）
STEP_CALL_TIMEOUT   = 180
# 依頼書の参考線：1句あたりの累積所要時間
VERSE_TIME_REFERENCE = 300

RUN_DATE   = Time.zone.now.strftime("%Y%m%d")
BATCH_NAME = "sono76_#{TAG_SUFFIX}#{RUN_DATE}"
LOG_PATH   = Rails.root.join("log", "observation_sono76_#{TAG_SUFFIX}#{RUN_DATE}.jsonl")
CALL_LOG_PATH = Rails.root.join("log", "observation_sono76_calls_#{TAG_SUFFIX}#{RUN_DATE}.jsonl")

# ---------------------------------------------------------------------------
# Ollama呼び出しの計装（app/無改修。本スクリプトのプロセス内でのみ有効）
# ---------------------------------------------------------------------------
module OllamaProbe
  CURRENT = { verse_no: 0, attempt: 0 }
  CALLS   = []

  class << self
    attr_accessor :sink

    # プロンプト本文の見出しから、どのStepの呼び出しかを判別する。
    # StepwiseWakaGeneratorの各build_*_promptが持つ固有の見出しを目印にする
    # （プロンプト側の文言に依存するので、変更されたら"unknown"に落ちるだけ）。
    def kind_of_prompt(prompt)
      s = prompt.to_s
      return "step1_free_verse"    if s.include?("【ペルソナ】")
      return "step1_5_length"      if s.include?("【下書き】")
      return "step3_mora_rewrite"  if s.include?("【書き換え対象】")

      "direct_or_other"
    end

    def record(api, kind, timeout)
      t0     = Time.now
      ok     = true
      errmsg = nil
      begin
        yield
      rescue StandardError => e
        ok     = false
        errmsg = "#{e.class}: #{e.message}"
        raise
      ensure
        entry = {
          verse_no: CURRENT[:verse_no], attempt: CURRENT[:attempt],
          api: api, kind: kind, timeout_setting: timeout,
          elapsed: (Time.now - t0).round(2), ok: ok, error: errmsg
        }
        CALLS << entry
        if sink
          sink.puts(entry.to_json)
          sink.flush
        end
      end
    end

    # 指定範囲の呼び出し記録を集計する
    def stats_for(entries)
      times = entries.map { |e| e[:elapsed] }
      {
        count: entries.size,
        total: times.sum.round(1),
        max:   times.max&.round(1),
        avg:   times.any? ? (times.sum / times.size).round(1) : nil
      }
    end
  end

  # OllamaClient.generate / .chat をラップする。引数はzsuperでそのまま透過させる。
  def generate(prompt, timeout: 300, think: true, temperature: nil, model: OllamaClient::MODEL)
    OllamaProbe.record("generate", OllamaProbe.kind_of_prompt(prompt), timeout) { super }
  end

  def chat(messages, timeout: 300, think: false)
    OllamaProbe.record("chat", "forced_zatsu", timeout) { super }
  end
end
OllamaClient.singleton_class.prepend(OllamaProbe)

# ---------------------------------------------------------------------------
# 以下、observe_production_hyakuin.rbと同一のヘルパー（判定ロジックは変更しない）
# ---------------------------------------------------------------------------
controller = RengasController.new

log_file      = File.open(LOG_PATH, "a")
call_log_file = File.open(CALL_LOG_PATH, "a")
OllamaProbe.sink = call_log_file

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
  else "句去"
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

def forced_zatsu_messages(maeku, target_mora, trigger_labels, threshold)
  reasons = trigger_labels.any? ? trigger_labels.uniq.join("、") : "同じ問題の繰り返し"
  [
    { role: "user", content: "あなたはいま、同じ前句に対して#{threshold}回試みても句が定まりません" \
                              "（原因：#{reasons}）。行き詰まっていることを認識してください。" },
    { role: "assistant", content: "はい、行き詰まっています。同じ前句に対して同じような問題を繰り返しており、" \
                                   "局面を打開する必要があります。" },
    { role: "user", content: "連歌では、季語（春・夏・秋・冬の語）を使う句と、季語を使わない" \
                              "「雑（ぞう）」の句があります。雑の句は季節に縛られず自由に詠めます。" \
                              "局面打開には雑の句が有効なことがあります。理解できましたか？" },
    { role: "assistant", content: "はい、理解しました。雑の句とは季語を含まない句で、季節に縛られず" \
                                   "詠むことができます。" },
    { role: "user", content: "では局面打開のため、雑の句として全く新しい言葉で#{target_mora}音の" \
                              "付け句を詠んでください。\n前句：#{maeku}\n" \
                              "#{target_mora}音を一行だけ出力してください。説明不要。" }
  ]
end

def forced_zatsu_candidates(maeku, target_vt, trigger_labels, threshold, max_sub_retry)
  target_mora = (target_vt == :chouku) ? 17 : 14
  results = []
  max_sub_retry.times do
    begin
      raw = OllamaClient.chat(forced_zatsu_messages(maeku, target_mora, trigger_labels, threshold),
                              think: false, timeout: 300)
    rescue RuntimeError, Net::ReadTimeout => conn_err
      results << { text: "", mora_check: { result: "ng", mora: 0, message: "接続エラー: #{conn_err.message}" },
                   connection_error: true }
      next
    end
    text = raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
    mora_check = text.blank? ? { result: "ng", mora: 0, message: "句が生成されませんでした" } :
                                KuValidator.new(text, type: target_vt).validate
    results << { text: text, mora_check: mora_check }
    break if mora_check[:result] != "ng"
  end
  results
end

class RetryExhausted < StandardError; end

nm       = controller.send(:build_mecab)
bui_dict = BuiDictionary.new

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
puts "其の七十六 Phase A :waka_extraction観測開始（目標#{TOTAL_VERSES}句#{RUN_TAG ? "、タグ=#{RUN_TAG}" : ""}）"
puts "発句: #{hakku_text}（Waka##{hakku_waka.id}）"
puts "ログ: #{LOG_PATH}"
puts "呼出ログ: #{CALL_LOG_PATH}"
puts "=" * 60

maeku                   = hakku_text
previous_renga_id       = nil
total_attempts          = 0
total_ng                = 0
violation_counts        = Hash.new(0)
forced_zatsu_creates    = 0
forced_zatsu_mora_ng_ct = 0
verse_metrics           = []  # 1句ごとの所要時間・呼び出し回数
run_started_at          = Time.now

catch(:attempt_cap_reached) do
  (1..TOTAL_VERSES).each do |verse_no|
    verse_started_at   = Time.now
    call_index_at_start = OllamaProbe::CALLS.size
    OllamaProbe::CURRENT[:verse_no] = verse_no
    OllamaProbe::CURRENT[:attempt]  = 0

    stage = "verse_start"
    maeku_mora      = KuValidator.new(maeku).count_mora
    maeku_type      = KuValidator.nearest_verse_type(maeku_mora)
    next_verse_type = (maeku_type == :chouku) ? :tanku : :chouku

    stage = "KuValidator(前句)"
    maeku_check = KuValidator.new(maeku, type: maeku_type).validate
    trigger_labels = []
    if maeku_check[:result] == "ng"
      note = "前句forced_zatsu由来ng:#{maeku_check[:message]}"
      trigger_labels << note
      log_line(log_file, {
        verse_no: verse_no, attempt: 0, text: maeku, mora_result: "ng",
        shikimoku_result: nil, violations: [note], action: "maeku_ng_continue"
      })
    end

    attempt_no   = 0
    final_text   = nil
    final_action = nil

    stage   = "build_verse_history"
    history = controller.send(:build_verse_history, previous_renga_id, maeku, maeku_type, nm: nm, bui_dict: bui_dict)
    checker = ShikimokuChecker.new

    stage            = "next_constraints"
    next_constraints = checker.next_constraints(history)
    controller.send(:log_season_hint, next_constraints, verse_no: verse_no)

    stage             = "fetch_used_waka_ids"
    used_waka_ids     = controller.send(:fetch_used_waka_ids, previous_renga_id)
    used_seed_waka_id = nil

    begin
      MAX_RETRY.times do |i|
        attempt_no = i + 1
        OllamaProbe::CURRENT[:attempt] = attempt_no
        total_attempts += 1
        throw :attempt_cap_reached if total_attempts > TOTAL_ATTEMPT_CAP

        attempt_started_at   = Time.now
        attempt_calls_before = OllamaProbe::CALLS.size

        verse_history = controller.send(:fetch_verse_history, previous_renga_id)
        begin
          generator = RengaGenerator.new(
            maeku, [], next_verse_type,
            constraints: {
              verse_history: verse_history,
              forbidden_bui: next_constraints[:forbidden_bui],
              season_hint:   next_constraints[:season_hint],
              used_waka_ids: used_waka_ids,
              # ここが本スクリプトの唯一の本質的な差分（其の七十六 Phase A）
              generation_strategy: :waka_extraction,
              # 其の七十八 Phase2: stepwise_stepsログのverse_noをnullにしないための紐付け
              log_context: { batch: BATCH_NAME, verse_no: verse_no, attempt: attempt_no }
            }
          )
          tsugeku = generator.generate_tsugeku
        rescue RuntimeError, Net::ReadTimeout => conn_err
          total_ng += 1
          label = "接続タイムアウト:#{conn_err.message}"
          trigger_labels << label
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: "", mora_result: nil,
            shikimoku_result: nil, violations: [label], action: action,
            attempt_elapsed: (Time.now - attempt_started_at).round(2),
            attempt_calls: OllamaProbe::CALLS.size - attempt_calls_before
          })
          raise RetryExhausted, "Ollama接続エラーが解消しませんでした（#{conn_err.message}）" if attempt_no == MAX_RETRY
          next
        end

        attempt_elapsed = (Time.now - attempt_started_at).round(2)
        attempt_calls   = OllamaProbe::CALLS.size - attempt_calls_before

        if tsugeku.blank?
          total_ng += 1
          trigger_labels << "生成失敗"
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku.to_s, mora_result: "ng",
            shikimoku_result: nil, violations: ["生成失敗"], action: action,
            attempt_elapsed: attempt_elapsed, attempt_calls: attempt_calls
          })
          raise RetryExhausted, "句が生成できませんでした" if attempt_no == MAX_RETRY
          next
        end

        stage = "KuValidator(付句)"
        mora_check = KuValidator.new(tsugeku, type: next_verse_type).validate
        if mora_check[:result] == "ng"
          total_ng += 1
          label = "モーラng(#{mora_check[:mora]}音)"
          trigger_labels << label
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: "ng",
            shikimoku_result: nil, violations: [label], action: action,
            attempt_elapsed: attempt_elapsed, attempt_calls: attempt_calls
          })
          raise RetryExhausted, "モーラ判定ngが解消しませんでした" if attempt_no == MAX_RETRY
          next
        end

        stage = "bui_dict/season_from_text"
        tsugeku_word = bui_dict.detect_word(tsugeku, nm)
        candidate = {
          bui:        bui_dict.detect_all(tsugeku, nm),
          season:     controller.send(:season_from_text, tsugeku),
          verse_type: next_verse_type,
          word:       tsugeku_word,
          text:       tsugeku,
          plant_type: bui_dict.plant_type(tsugeku_word)
        }

        stage = "ShikimokuChecker"
        violations = checker.all_violations(history, candidate, bui_dict: bui_dict)
        violations += checker.ichiza_violations(history, candidate)
        violations += checker.chotan_violations(history, candidate)

        if violations.any?
          total_ng += 1
          labels = violations.map { |v| violation_label(v) }
          violations.each { |v| violation_counts[violation_category(v)] += 1 }
          trigger_labels.concat(labels)
          action = (attempt_no == MAX_RETRY) ? "exhausted" : "retry"
          log_line(log_file, {
            verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: mora_check[:result],
            shikimoku_result: "ng", violations: labels, action: action,
            attempt_elapsed: attempt_elapsed, attempt_calls: attempt_calls
          })
          raise RetryExhausted, "式目ngが解消しませんでした" if attempt_no == MAX_RETRY
          next
        end

        final_text        = tsugeku
        final_action      = "create"
        used_seed_waka_id = generator.used_seed_waka_id
        log_line(log_file, {
          verse_no: verse_no, attempt: attempt_no, text: tsugeku, mora_result: mora_check[:result],
          shikimoku_result: "ok", violations: [], action: "create",
          attempt_elapsed: attempt_elapsed, attempt_calls: attempt_calls
        })
        break
      end
    rescue RetryExhausted => e
      puts "  #{verse_no}句目: #{e.message}（#{MAX_RETRY}回試行）→ forced_zatsuへエスカレーション"
      stage = "forced_zatsu_candidates"
      fz_results = forced_zatsu_candidates(
        maeku, next_verse_type, trigger_labels, MAX_RETRY, FORCED_ZATSU_MORA_RETRY
      )
      fz_results.each_with_index do |r, idx|
        total_attempts += 1
        attempt_no     += 1
        OllamaProbe::CURRENT[:attempt] = attempt_no
        throw :attempt_cap_reached if total_attempts > TOTAL_ATTEMPT_CAP

        is_last = (idx == fz_results.size - 1)
        total_ng += 1 if r[:mora_check][:result] == "ng"

        fz_action =
          if !is_last
            "forced_zatsu"
          elsif r[:mora_check][:result] == "ng"
            "forced_zatsu_mora_ng"
          else
            "forced_zatsu_create"
          end

        log_violations = trigger_labels.uniq
        log_violations += [r[:mora_check][:message]] if r[:connection_error]

        log_line(log_file, {
          verse_no: verse_no, attempt: attempt_no, text: r[:text],
          mora_result: r[:mora_check][:result], shikimoku_result: "skipped",
          violations: log_violations, action: fz_action
        })

        next unless is_last

        final_text   = r[:text]
        final_action = fz_action
        forced_zatsu_creates    += 1 if fz_action == "forced_zatsu_create"
        forced_zatsu_mora_ng_ct += 1 if fz_action == "forced_zatsu_mora_ng"
      end
    end

    if final_text.blank?
      raise "verse_no=#{verse_no}: forced_zatsuを含め#{MAX_RETRY + FORCED_ZATSU_MORA_RETRY}回の試行すべてで" \
            "有効な句を得られませんでした（直前の原因: #{trigger_labels.last}）"
    end

    style_result =
      if final_action == "create"
        { "result" => "ok", "issues" => [], "breakdown" => [] }
      else
        { "result" => final_action, "issues" => trigger_labels.uniq, "breakdown" => [] }
      end

    stage = "Renga.create!"
    renga = Renga.create!(
      maeku:              maeku,
      tsugeku:            final_text,
      maeku_author:       "観測スクリプト",
      tsugeku_author:     "メンタムさん",
      generated_by_model: OllamaClient::MODEL,
      style_check_result: style_result,
      honka_reference:    [used_seed_waka_id].compact,
      previous_renga_id:  previous_renga_id,
      observation_batch:  BATCH_NAME
    )

    verse_calls   = OllamaProbe::CALLS[call_index_at_start..] || []
    verse_elapsed = (Time.now - verse_started_at).round(1)
    verse_metrics << {
      verse_no: verse_no, action: final_action, attempts: attempt_no,
      elapsed: verse_elapsed, calls: verse_calls.size,
      max_call: verse_calls.map { |c| c[:elapsed] }.max,
      timeout_calls: verse_calls.count { |c| !c[:ok] }
    }

    puts "  #{verse_no}/#{TOTAL_VERSES}句目 #{final_action}（attempt#{attempt_no}・" \
         "#{verse_elapsed}秒・Ollama#{verse_calls.size}回）: #{final_text}"

    previous_renga_id = renga.id
    maeku             = final_text
  rescue StandardError => e
    warn "[observe_waka_extraction] verse_no=#{verse_no} stage=#{stage} #{e.class}: #{e.message}"
    warn e.backtrace.first(10).join("\n") if e.backtrace
    log_line(log_file, {
      verse_no: verse_no, attempt: attempt_no, text: nil, mora_result: nil,
      shikimoku_result: nil, violations: ["#{stage}: #{e.class}: #{e.message}"], action: "error"
    })
    raise
  end
end

run_elapsed = (Time.now - run_started_at).round(1)
log_file.close
call_log_file.close

# ---------------------------------------------------------------------------
# サマリー
# ---------------------------------------------------------------------------
puts "=" * 60
puts "観測完了（総所要 #{run_elapsed}秒 / #{(run_elapsed / 60).round(1)}分）"
puts "総試行回数: #{total_attempts}"
puts "総ng回数:   #{total_ng}"
ng_rate = total_attempts.positive? ? (total_ng.to_f / total_attempts * 100).round(1) : 0.0
puts "ng率:       #{ng_rate}%"
puts "forced_zatsu採用: #{forced_zatsu_creates}句（うちモーラng許容: #{forced_zatsu_mora_ng_ct}句）"

puts "-" * 60
puts "【レイテンシ：1句あたり】"
if verse_metrics.any?
  elapsed_list = verse_metrics.map { |m| m[:elapsed] }
  calls_list   = verse_metrics.map { |m| m[:calls] }
  puts "  完了句数:            #{verse_metrics.size}句"
  puts "  1句あたり平均:        #{(elapsed_list.sum / elapsed_list.size).round(1)}秒"
  puts "  1句あたり最大:        #{elapsed_list.max}秒（verse_no=#{verse_metrics.max_by { |m| m[:elapsed] }[:verse_no]}）"
  puts "  1句あたり最小:        #{elapsed_list.min}秒"
  puts "  Ollama呼出 平均:      #{(calls_list.sum.to_f / calls_list.size).round(1)}回/句"
  puts "  Ollama呼出 最大:      #{calls_list.max}回/句（verse_no=#{verse_metrics.max_by { |m| m[:calls] }[:verse_no]}）"
  over_ref = verse_metrics.select { |m| m[:elapsed] > VERSE_TIME_REFERENCE }
  puts "  #{VERSE_TIME_REFERENCE}秒（依頼書の参考線）超過: #{over_ref.size}句" \
       "#{over_ref.any? ? "（verse_no=#{over_ref.map { |m| m[:verse_no] }.join(',')}）" : ""}"
else
  puts "  （完了句なし）"
end

puts "-" * 60
puts "【レイテンシ：Ollama呼び出し単位】"
all_calls = OllamaProbe::CALLS
st = OllamaProbe.stats_for(all_calls)
puts "  総呼び出し回数: #{st[:count]}回 / 合計#{st[:total]}秒（平均#{st[:avg]}秒・最大#{st[:max]}秒）"
puts "  Step種別ごとの内訳:"
all_calls.group_by { |c| c[:kind] }.sort_by { |_, v| -v.size }.each do |kind, entries|
  s = OllamaProbe.stats_for(entries)
  puts "    #{kind.ljust(18)} #{s[:count].to_s.rjust(4)}回  平均#{s[:avg]}秒  最大#{s[:max]}秒  合計#{s[:total]}秒"
end

failed_calls = all_calls.reject { |c| c[:ok] }
puts "-" * 60
puts "【タイムアウト超過】"
puts "  Stepwise側の1呼び出し上限は#{STEP_CALL_TIMEOUT}秒（stepwise_waka_generator.rb）"
puts "  失敗した呼び出し: #{failed_calls.size}回"
failed_calls.first(20).each do |c|
  puts "    verse_no=#{c[:verse_no]} attempt=#{c[:attempt]} #{c[:kind]} " \
       "#{c[:elapsed]}秒（設定#{c[:timeout_setting]}秒）: #{c[:error]}"
end
slow_calls = all_calls.select { |c| c[:elapsed] >= STEP_CALL_TIMEOUT * 0.8 && c[:ok] }
puts "  上限の8割（#{(STEP_CALL_TIMEOUT * 0.8).round}秒）以上かかった成功呼び出し: #{slow_calls.size}回"

puts "-" * 60
puts "違反種別の内訳（降順）:"
violation_counts.sort_by { |_, count| -count }.each do |category, count|
  puts "  #{category}: #{count}件"
end
puts "=" * 60
