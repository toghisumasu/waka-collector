#!/usr/bin/env ruby
# frozen_string_literal: true

# dryrun_hyakuin.rb — 独吟百韻ドライラン
#
# 使用法:
#   bundle exec ruby script/dryrun_hyakuin.rb
#   nohup bundle exec ruby script/dryrun_hyakuin.rb &
#
# 出力: log/dryrun_hyakuin_YYYYMMDD.log（追記）

require "json"
require_relative "../app/services/shikimoku_checker"
require_relative "../app/services/bui_dictionary"
require_relative "../app/services/ollama_client"

# KuValidator は Rails.root に依存するため、フルRails環境を起動しないこの
# スタンドアロンスクリプトでは軽量スタブを用意してから読み込む（其の三十 Step A）。
unless defined?(Rails)
  require "pathname"
  module Rails
    def self.root
      Pathname.new(File.expand_path("..", __dir__))
    end
  end
end
require_relative "../app/services/ku_validator"

# ─────────────────────────────────────────────────────────────
#  定数
# ─────────────────────────────────────────────────────────────

HAKKU = {
  word:       "東風ふかば匂いおこせよ梅の花",
  bui:        ["花", "植物"],
  season:     "春",
  verse_type: :chouku,
  tsuki:      false,
  hana:       false
}.freeze

TOTAL_VERSES = 100
MAX_RETRY    = 5

BUI_EXAMPLE = {
  "降物" => "雨・雪・露・霜・時雨・霰",
  "聳物" => "霞・霧・雲・煙",
  "光物" => "月・日・星",
  "花"   => "梅・桜・菊・山吹",
  "草"   => "萩・薄・若草",
  "木"   => "柳・松・冬木立",
  "植物" => "草木・花全般",
  "鳥"   => "鶯・雁・鴨・千鳥",
  "虫"   => "蛍・蟋蟀・蝶",
  "獣"   => "鹿・狐",
  "動物" => "鳥・虫・獣全般",
  "水辺" => "川・海・池・渚",
  "山類" => "山・峰・嶺・谷",
  "時分" => "夜・朝・夕・暮れ",
  "居所" => "宿・庵・垣根",
  "衣裳" => "袖・衣・砧",
  "恋"   => "恋・涙・逢う",
  "旅"   => "旅・旅人・行く",
  "名所" => "名所・歌枕",
  "神祇" => "神・祈り・社",
  "釈教" => "仏・法・寺",
  "述懐" => "述懐・感慨",
  "人倫" => "人・君・誰"
}.freeze

SEASON_KIGO = {
  "春" => %w[霞 梅 桜 鶯 柳 蛙 燕 朧 若草 菜の花 山吹 すみれ よもぎ わらび],
  "夏" => %w[郭公 ほととぎす 蛍 五月雨 蓮 卯の花 青葉 緑 さみだれ あやめ しょうぶ],
  "秋" => %w[月 紅葉 もみじ 露 雁 鹿 萩 菊 嵐 時雨 霧 おみなえし ききょう],
  "冬" => %w[雪 霜 氷 枯 千鳥 鷺 みぞれ かれの]
}.freeze

# ─────────────────────────────────────────────────────────────
#  ユーティリティ
# ─────────────────────────────────────────────────────────────

def verse_type_ja(vt)
  vt == :chouku ? "長句(5-7-5)" : "短句(7-7)"
end

def timestamp
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end

# ─────────────────────────────────────────────────────────────
#  B層: filter_pool — next_constraints からプロンプト制約を組み立てる
# ─────────────────────────────────────────────────────────────

def filter_pool(constraints)
  forbidden_bui   = constraints[:forbidden_bui] || []
  season_hint     = constraints[:season_hint]   || {}
  verse_type      = constraints[:verse_type]    || :tanku
  current_season  = season_hint[:current]

  # must_switch: 当季の季語一覧も禁止対象に加える（プロンプト強制用）
  forbidden_seasons = []
  forbidden_kigo    = []
  if season_hint[:must_switch] && current_season
    forbidden_seasons << current_season
    forbidden_kigo = SEASON_KIGO[current_season] || []
  end

  season_instruction = if season_hint[:must_switch]
    alt = (%w[春 夏 秋 冬 雑] - forbidden_seasons).join("・")
    "【季の転換】必ず#{forbidden_seasons.join('・')}以外の季にすること。選択肢：#{alt}"
  elsif season_hint[:must_continue]
    "★必ず#{current_season}の季を継続すること（残り#{[0, (3 - season_hint[:count])].max}句以上は続けよ）"
  elsif current_season
    "現在の季：#{current_season}（継続または転換、どちらでも可）"
  else
    "季は自由（雑・春・夏・秋・冬から選べ）"
  end

  kinshi_line = if forbidden_bui.any?
    desc = forbidden_bui.map { |b| BUI_EXAMPLE[b] || b }.join("・")
    "禁止部立（これらの語は避けよ）: #{desc}"
  else
    ""
  end

  {
    verse_type:         verse_type,
    season_instruction: season_instruction,
    kinshi_line:        kinshi_line,
    forbidden_bui:      forbidden_bui,
    forbidden_seasons:  forbidden_seasons,
    forbidden_kigo:     forbidden_kigo,
    season_hint:        season_hint
  }
end

# ─────────────────────────────────────────────────────────────
#  C層: プロンプト構築とOllama生成
# ─────────────────────────────────────────────────────────────

def build_prompt(maeku_word, pool_params, verse_no, feedback: nil)
  vt               = pool_params[:verse_type]
  mora_desc        = vt == :chouku ? "17音（五七五）" : "14音（七七）"
  forbidden_seasons = pool_params[:forbidden_seasons] || []
  forbidden_kigo    = pool_params[:forbidden_kigo]    || []

  # must_switch 時は別の季からkigoを提示してLLMを誘導する
  hint_season = if forbidden_seasons.any?
    (%w[春 夏 秋 冬] - forbidden_seasons).sample
  else
    pool_params[:season_hint][:current]
  end

  kigo_list = SEASON_KIGO[hint_season]
                &.reject { |w| maeku_word.include?(w) || forbidden_kigo.include?(w) }
                &.first(3)
                &.join("・")

  kigo_line = if kigo_list && !kigo_list.empty?
    "参考季語（#{hint_season}）：#{kigo_list}"
  else
    ""
  end

  # 禁止季を強調ブロックとしてプロンプト冒頭に差し込む
  forbidden_season_block = if forbidden_seasons.any?
    kigo_ex = forbidden_kigo.first(5).join("・")
    "【絶対禁止】season フィールドに「#{forbidden_seasons.join('・')}」を入れてはならない。\n" \
    "「#{kigo_ex}」等の語を含む句も禁止。違反した場合は採点外とする。\n"
  else
    ""
  end

  feedback_line = feedback ? "前回「#{feedback[:ku]}」は#{feedback[:issue]}。#{feedback[:message]}\n" : ""

  <<~PROMPT
    あなたは連歌師（れんがし）です。次の句（前句）に付く「付句（つけく）」を一句作れ。

    前句：#{maeku_word}
    句番号：#{verse_no}句目
    句型：#{mora_desc}の付句を作れ
    #{forbidden_season_block}#{pool_params[:season_instruction]}
    #{kigo_line}
    #{pool_params[:kinshi_line]}
    #{feedback_line}
    【出力形式】
    以下のJSONのみを出力せよ。前後の説明文・コードブロック不要。
    {"ku":"付句の本文","mora":音数,"season":"春か夏か秋か冬か雑","bui":["部立1","部立2"],"tsuki":false,"hana":false}

    bui に指定できる部立（複数可）:
    降物・聳物・光物・花・草・木・植物・鳥・虫・獣・動物・水辺・山類・時分・居所・衣裳・恋・旅・名所・神祇・釈教・述懐・人倫
    tsuki は月を詠み込んだとき true、hana は桜の花を詠み込んだとき true

    JSON:
  PROMPT
end

def parse_candidate(raw)
  json_str = raw.to_s.match(/\{[^{}]*\}/m)&.to_s
  return nil unless json_str
  parsed = JSON.parse(json_str)
  {
    word:       parsed["ku"].to_s.strip,
    bui:        Array(parsed["bui"]),
    season:     parsed["season"],
    verse_type: nil,  # 後で設定
    tsuki:      parsed["tsuki"] == true,
    hana:       parsed["hana"]  == true,
    mora:       parsed["mora"].to_i
  }
rescue JSON::ParserError
  nil
end

# ─────────────────────────────────────────────────────────────
#  ログ
# ─────────────────────────────────────────────────────────────

def log_attempt(logfile, verse_no:, attempt:, history_size:, reason:, candidate: nil, violation_types: [])
  entry = {
    ts:              timestamp,
    verse_no:        verse_no,
    attempt:         attempt,
    history_size:    history_size,
    reason:          reason,
    violation_types: violation_types,
    candidate:       candidate && {
      word:    candidate[:word],
      bui:     candidate[:bui],
      raw_bui: candidate[:raw_bui], # 正規化前の自己申告そのまま（其の二十八）
      season:  candidate[:season],
      seed_id: nil # このスクリプトにはseed_pool概念がない（RengaGenerator固有）
    }
  }
  File.open(logfile, "a") { |f| f.puts(entry.to_json) }
end

def log_line(logfile, verse_no, candidate, violations, forced: false)
  no_str  = format("%03d", verse_no)
  bui_str = candidate[:bui].join(",")
  vt_str  = candidate[:verse_type] == :chouku ? "長" : "短"
  vi_str  = if violations.empty?
    forced ? "FORCED(no-valid)" : "OK"
  else
    labels = violations.map { |v| ShikimokuChecker.describe(v) }.join(" / ")
    forced ? "FORCED: #{labels}" : "VIOLATION: #{labels}"
  end

  line = "[#{timestamp}] #{no_str} | #{candidate[:word]} | #{vt_str} | #{candidate[:season] || '雑'} | #{bui_str} | #{vi_str}"
  puts line
  $stdout.flush
  File.open(logfile, "a") { |f| f.puts(line) }
end

# ─────────────────────────────────────────────────────────────
#  事前チェック: ollama list で qwen3:8b 確認
# ─────────────────────────────────────────────────────────────

def check_ollama_model
  result = `ollama list 2>&1`
  unless result.include?("qwen3:8b")
    puts "ERROR: qwen3:8b が ollama に見つかりません。"
    puts "  ollama pull qwen3:8b を実行してください。"
    puts "--- ollama list 出力 ---"
    puts result
    exit 1
  end
  puts "OK: qwen3:8b 確認済み"
end

# ─────────────────────────────────────────────────────────────
#  メインループ
# ─────────────────────────────────────────────────────────────

check_ollama_model

log_dir  = File.expand_path("../log", __dir__)
Dir.mkdir(log_dir) unless Dir.exist?(log_dir)
logfile  = File.join(log_dir, "dryrun_hyakuin_#{Time.now.strftime('%Y%m%d')}.log")
attempts_logfile = File.join(log_dir, "generation_attempts.log")
checker  = ShikimokuChecker.new
bui_dict = BuiDictionary.new

# 其の二十八の季語所属ng調査で判明した①②対策：
# ShikimokuChecker が認識する正規カテゴリ（kuzari_rules.yml + 時分/人倫）に
# 一致しないbui自己申告を、bui_dictionary.yml の primary_bui で正規化する。
# ShikimokuChecker自体は無変更（純粋関数性を維持）、呼び出し側で正規化する。
valid_bui_categories = (checker.rules.keys + %w[時分 人倫]).uniq

normalize_candidate_bui = lambda do |tags|
  Array(tags).map { |t| bui_dict.normalize_bui(t, valid_bui_categories) }
end

puts "=" * 60
puts "独吟百韻ドライラン開始"
puts "ログ: #{logfile}"
puts "=" * 60

initial_verse = HAKKU.dup
initial_verse[:bui] = normalize_candidate_bui.call(initial_verse[:bui])
history = [initial_verse]
log_line(logfile, 1, HAKKU, [])

(2..TOTAL_VERSES).each do |verse_no|
  constraints  = checker.next_constraints(history)
  pool_params  = filter_pool(constraints)

  target_vt    = constraints[:verse_type]
  target_mora  = target_vt == :chouku ? 17 : 14

  best_candidate    = nil
  best_violations   = nil
  best_mora_diff    = nil
  feedback          = nil
  banned_words      = []
  duplicate_streak  = 0

  MAX_RETRY.times do |attempt|
    temperature = attempt >= 3 ? 0.8 : nil

    begin
      prompt = build_prompt(history.last[:word], pool_params, verse_no, feedback: feedback)
      raw    = OllamaClient.generate(prompt, think: false, timeout: 300,
                                     temperature: temperature)
    rescue => e
      puts "  [#{verse_no}句目 attempt#{attempt + 1}] Ollama接続エラー: #{e.message}"
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "ollama_error")
      next
    end

    candidate = parse_candidate(raw)
    if candidate.nil?
      feedback = { ku: "(解析失敗)", issue: "JSON解析エラー", message: "正しいJSON形式で出力せよ" }
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "json_parse_error")
      next
    end

    # bui自己申告の正規化（ログには正規化前のraw_buiも残し、以降の判定・historyには
    # 正規化後のbuiを使う。generation_attempts.log の raw_bui は将来の
    # analyze_kigo_membership.rb 再実行で③（真に未知）の推移を監視するために残す）
    candidate[:raw_bui] = candidate[:bui].dup
    candidate[:bui]      = normalize_candidate_bui.call(candidate[:bui])

    # 重複句リジェクト（historyに同一wordが存在する場合は即却下）
    if history.any? { |v| v[:word] == candidate[:word] }
      banned_words << candidate[:word] unless banned_words.include?(candidate[:word])
      duplicate_streak += 1

      banned_list = banned_words.map { |w| "「#{w}」" }.join("・")
      message = "以下は出力禁止（既出につき再使用不可）: #{banned_list}。全く別の語・情景で新たに詠め"

      # duplicate_verse固着（同一文言の連続再出力）に対する機械的救済：
      # 季語ヒントを強制的に変えるのではなく、「季から離れて雑（無季）で詠み直す」
      # という連歌本来の技法をfeedbackで指示する（季を強制しない＝季語ヒントの上書きは行わない）
      if duplicate_streak >= 2
        puts "  [#{verse_no}句目 attempt#{attempt + 1}] duplicate_verse固着検知 → 雑（無季）への詠み直しを指示"
        message           = "#{message}。季語にとらわれず、無季（雑）の句として、季節を離れた情景・心情・人事を詠んでください"
        duplicate_streak  = 0
      end

      feedback = { ku: candidate[:word], issue: "重複句", message: message }

      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "duplicate_verse", candidate: candidate)
      next
    end

    # 禁止季リジェクト（LLMがJSONに誤記入した場合の防衛ライン）
    if pool_params[:forbidden_seasons].include?(candidate[:season])
      feedback = { ku: candidate[:word], issue: "禁止季（#{candidate[:season]}）",
                   message: "#{pool_params[:forbidden_seasons].join('・')}以外の季にすること" }
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "forbidden_season", candidate: candidate)
      next
    end

    candidate[:verse_type] = target_vt

    mora_check = KuValidator.new(candidate[:word], type: target_vt).validate

    if mora_check[:result] == "ng"
      issue   = mora_check[:mora] > target_mora ? "字余り(#{mora_check[:mora]}音)" : "字足らず(#{mora_check[:mora]}音)"
      # 其の三十 Step B-1: 「もっと短く/長く」という曖昧な方向指示だけでなく、
      # 目標モーラ数を明示することでLLMが具体的な調整量を把握できるようにする
      message = mora_check[:mora] > target_mora ? "#{target_mora}音になるよう、もっと短くしてください" : "#{target_mora}音になるよう、もっと長くしてください"
      feedback = { ku: candidate[:word], issue: issue, message: message }
      # 其の三十 Step B-1補足修正: mora_errorが複数回連続した際、best_candidateが
      # 1投目のまま固定され、後続attemptでモーラ数が目標に近づいても
      # FORCED採用結果に反映されない不具合を修正。目標モーラ数との差が
      # それまでのmora_errorフォールバックより縮まった場合のみ更新する
      # （mora検査を通過した候補が既にbest_candidateになっている場合は上書きしない）
      diff = (mora_check[:mora] - target_mora).abs
      if best_violations.nil? ||
         (best_violations.first && best_violations.first[:type] == :mora_error && diff < best_mora_diff)
        best_candidate  = candidate
        best_violations = [{ type: :mora_error, desc: mora_check[:message] }]
        best_mora_diff  = diff
      end
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "mora_error", candidate: candidate)
      next
    elsif mora_check[:result] == "warning"
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "mora_warning", candidate: candidate)
    end

    violations   = checker.all_violations(history, candidate, bui_dict: bui_dict)
    ichiza_viols = checker.ichiza_violations(history, candidate)
    all_viols    = violations + ichiza_viols

    best_candidate  = candidate
    best_violations = all_viols

    if all_viols.empty?
      feedback = nil
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "ok", candidate: candidate)
      break
    elsif ichiza_viols.any?
      used    = ichiza_viols.map { |v| "「#{v[:word]}」(#{v[:first_pos]}句目既出)" }.join("・")
      feedback = { ku: candidate[:word], issue: "一座一句物違反",
                   message: "以下は一座一句物につき再使用不可: #{used}。別の語で詠め" }
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: "ichiza_duplicate", candidate: candidate,
                  violation_types: all_viols.map { |v| v[:type] }.uniq)
    else
      desc    = violations.map { |v| ShikimokuChecker.describe(v) }.join("; ")
      feedback = { ku: candidate[:word], issue: "式目違反", message: "式目違反を避けよ: #{desc}" }
      log_attempt(attempts_logfile, verse_no: verse_no, attempt: attempt + 1,
                  history_size: history.size, reason: violations.first[:type] || "kuzari_violation",
                  candidate: candidate,
                  violation_types: all_viols.map { |v| v[:type] || "kuzari_violation" }.uniq)
    end
  end

  if best_candidate.nil?
    placeholder = {
      word: "(生成失敗)", bui: [], season: nil,
      verse_type: target_vt, tsuki: false, hana: false
    }
    log_line(logfile, verse_no, placeholder, [{ type: :generation_failed }], forced: true)
    history << placeholder
    next
  end

  forced = !(best_violations&.empty?)
  log_line(logfile, verse_no, best_candidate, best_violations || [], forced: forced)
  history << best_candidate
end

puts "=" * 60
puts "独吟百韻ドライラン完了"
puts "ログ: #{logfile}"
puts "=" * 60
