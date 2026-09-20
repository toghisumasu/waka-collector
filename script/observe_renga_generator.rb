# 依頼書C-実走: RengaGenerator（本番:direct方式）を直接100句連続生成させ、
# C-1（絶対禁止ブロック）・C-2（example展開）を実際に経由した状態で
# 季節分布・FORCED句数を観測する。
#
# dryrun_hyakuin.rbはapp/services/renga_generator.rbをrequireせず独自の
# build_prompt/OllamaClient.chatフローを持つため、C-1/C-2の効果測定には
# 使えない（別コードパス）。本スクリプトはRengaGenerationServiceの呼び出し
# パターン（RengaGenerator.new → generate_tsugeku → ShikimokuChecker post-hoc検証）
# をDBへの実書き込みなしにインメモリで再現する。
#
# 【dryrun_hyakuin.rbとの既知の相違点（FORCED定義）】
# dryrun_hyakuin.rbは1句につきMAX_RETRY回、build_prompt側にshikimoku違反の
# feedbackを直接注入しながらリトライする。RengaGeneratorは公開APIが
# generate_tsugeku一つのみで、内部25試行ループはmora/echo/反復のみを見ており
# ShikimokuChecker違反はケアしない（本番RengaGenerationServiceも同様、
# 違反時はShikimokuNgを投げて人間の再操作に委ねるのみでfeedback付き
# リトライは行わない）。本スクリプトの外側MAX_RETRYループは「人間が
# 再生成ボタンをMAX_RETRY回押した場合」に相当するfreshな再呼び出しであり、
# dryrun_hyakuin.rbのfeedback付きリトライとは中身が異なる。FORCED句数の
# 単純比較は目安に留めること（[[forced_metric_mismatch]]と同種の注意）。
#
# 実行: bin/rails runner script/observe_renga_generator.rb
# コード変更・コミットなし。使い捨て観測スクリプト。

require "natto"

HAKKU_TEXT = "東風ふかば匂いおこせよ梅の花"
TOTAL_VERSES = (ENV["OBSERVE_RG_TOTAL"] || 100).to_i
MAX_RETRY    = 5

def timestamp
  Time.now.strftime("%Y-%m-%d %H:%M:%S")
end

# RengaGenerationService#season_from_text / #shimo_kigo? の複製（観測専用、
# 本番コードは無変更）。
def season_from_text(text, nm:)
  return nil if text.blank?
  key = RengaGenerator::SEASON_WORDS.find do |_, words|
    words.any? { |w| w == "しも" ? shimo_kigo?(text, nm) : text.include?(w) }
  end&.first
  key ? RengaGenerator::SEASON_JP[key] : nil
end

def shimo_kigo?(text, nm)
  return false unless text.include?("しも")
  nm.parse(text.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos?
    return true if node.surface == "しも" && node.feature.split(",")[0] == "名詞"
  end
  false
end

def sanitize_generated_phrase(text)
  text.to_s.gsub(/[、\s　]/, "")
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

  line = "[#{timestamp}] #{no_str} | #{candidate[:word]} | #{vt_str} | #{candidate[:season] || '雑'} | #{bui_str} | #{vi_str} | #{candidate[:text]}"
  puts line
  $stdout.flush
  File.open(logfile, "a") { |f| f.puts(line) }
end

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue => e
  Rails.logger.warn "ユーザー辞書なし: #{e.message}"
  Natto::MeCab.new
end

log_dir = Rails.root.join("log")
Dir.mkdir(log_dir) unless Dir.exist?(log_dir)
logfile = log_dir.join("observe_rg_#{Time.now.strftime('%Y%m%d')}.log").to_s

puts "=" * 60
puts "RengaGenerator直接観測 開始（モデル: #{OllamaClient::MODEL}）"
puts "ログ: #{logfile}"
puts "=" * 60

nm       = build_mecab
bui_dict = BuiDictionary.new
checker  = ShikimokuChecker.new

hakku_word = bui_dict.detect_word(HAKKU_TEXT, nm)
hakku = {
  bui:        bui_dict.detect_all(HAKKU_TEXT, nm),
  season:     season_from_text(HAKKU_TEXT, nm: nm),
  verse_type: :chouku,
  word:       hakku_word,
  text:       HAKKU_TEXT,
  plant_type: bui_dict.plant_type(hakku_word)
}
history     = [hakku]
verse_texts = [HAKKU_TEXT]
log_line(logfile, 1, hakku, [])

(2..TOTAL_VERSES).each do |verse_no|
  next_constraints = checker.next_constraints(history)
  target_vt        = next_constraints[:verse_type]
  maeku_text       = history.last[:text]

  best_candidate  = nil
  best_violations = nil

  MAX_RETRY.times do |attempt|
    generator = RengaGenerator.new(
      maeku_text, [], target_vt,
      constraints: {
        verse_history:           verse_texts,
        forbidden_bui:           next_constraints[:forbidden_bui],
        season_hint:             next_constraints[:season_hint],
        forbidden_nanaku_words:  next_constraints[:forbidden_nanaku_words],
        verse_no:                verse_no,
        batch_name:              "observe_rg",
        generation_strategy:     :direct
      }
    )

    tsugeku = sanitize_generated_phrase(generator.generate_tsugeku)
    if tsugeku.blank?
      puts "  [#{verse_no}句目 attempt#{attempt + 1}] 生成失敗（空句）"
      next
    end

    word = bui_dict.detect_word(tsugeku, nm)
    candidate = {
      bui:        bui_dict.detect_all(tsugeku, nm),
      season:     season_from_text(tsugeku, nm: nm),
      verse_type: target_vt,
      word:       word,
      text:       tsugeku,
      plant_type: bui_dict.plant_type(word)
    }

    violations   = checker.all_violations(history, candidate, bui_dict: bui_dict)
    violations  += checker.ichiza_violations(history, candidate)
    violations  += checker.chotan_violations(history, candidate)

    best_candidate  = candidate
    best_violations = violations

    break if violations.empty?
  end

  if best_candidate.nil?
    placeholder = { bui: [], season: nil, verse_type: target_vt, word: "(生成失敗)", text: "(生成失敗)", plant_type: nil }
    log_line(logfile, verse_no, placeholder, [{ type: :generation_failed }], forced: true)
    history << placeholder
    verse_texts << placeholder[:text]
    next
  end

  forced = best_violations.any?
  log_line(logfile, verse_no, best_candidate, best_violations, forced: forced)
  history << best_candidate
  verse_texts << best_candidate[:text]
end

puts "=" * 60
puts "RengaGenerator直接観測 完了"
puts "ログ: #{logfile}"
puts "=" * 60
