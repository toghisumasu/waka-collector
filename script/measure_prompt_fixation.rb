# frozen_string_literal: true

# 其の七十七: 初回生成プロンプト（Step1）とforced_zatsuレスキュープロンプトの
# 「固着度」を同条件で比較する測定スクリプト（read-only、app/へは無改修）。
#
# 目的: どちらのプロンプトが柔軟さ（出力の多様性）を持っているかを数値で比較する。
# 其の七十六 Phase Aでは Step1側に「gaze_path丸写し」、レスキュー側に
# 「末尾『静けさを呼ぶ』の連続」という、いずれも固着と見える現象が観測されたが、
# 両者を同一条件で並べて測ったことがなかった。
#
# 使い方:
#   bundle exec rails runner script/measure_prompt_fixation.rb [試行数]
#
# 測定条件:
#   S1_varseed … Step1プロンプト（:abstract既定）。seedをプールから毎回抽出、
#                ペルソナは自動選択（本番と同じ挙動）
#   S1_fixseed … Step1プロンプト。seed・ペルソナを固定し、プロンプト自身が
#                持つ多様性のみを見る（seedという変動源を除去）
#   S1_literal … 其の七十四方式（gaze_mode: :literal）。seed・ペルソナ固定
#   RESCUE     … forced_zatsuレスキュープロンプト（script/observe_waka_extraction.rb:174）。
#                前句・trigger_labelsを固定。「全く新しい言葉で」と指示するだけで
#                使用不可リストを持たない版
#   RESCUE_ban … 上に app/services/renga_generator.rb:452（:direct方式のSocratic
#                レスキュー）と同じ「これまでの候補（使用不可）」リストを足した版。
#                RESCUE条件の出力12件をそのまま使用不可として与える。
#                使用不可リストの有無が固着度に効くかを見る
#
# 条件の指定: ARGV[1]にカンマ区切りで条件名を渡すと、その条件のみ実行する。
#   例) bundle exec rails runner script/measure_prompt_fixation.rb 12 RESCUE,RESCUE_ban
#
# 温度: Step1は temperature: 0.6 を明示指定。レスキューはOllamaClient.chatが
#   温度を渡さずモデル既定値を使うが、qwen3:8bの既定は 0.6 で一致する
#   （ollama show qwen3:8b --parameters で確認済み）。よって温度は交絡しない。
#
# 交絡として残る差（結果の解釈時に必ず考慮すること）:
#   - 目標音数: Step1は「三十一音程度」の自由詠み、レスキューは14音ちょうど。
#     短い方が語を選ぶ余地が少なく、固着度が高く出やすい方向のバイアスがある。
#   - API: Step1は generate、レスキューは chat（多ターン）。
#   - 入力の変動源: Step1はseed語・季語指定・視座（距離帯）が毎回変わり得る。
#     レスキューはtrigger_labelsのみで、本測定では固定した。

require "natto"

N       = (ARGV[0] || 12).to_i
ONLY    = ARGV[1].to_s.split(",").map(&:strip).reject(&:empty?)
MAEKU   = "へたてける人の心のうきはしを"
TRIGGER = ["句去:月", "句数:秋"]
THRESHOLD = 5
TARGET_VT = :tanku
SRAND_SEED = 20260730

def content_words(nm, text)
  words = []
  nm.parse(text.to_s) do |m|
    next if m.is_eos?

    pos = m.feature.split(",")[0]
    words << m.surface if %w[名詞 動詞 形容詞].include?(pos)
  end
  words
end

def jaccard(a, b)
  sa = a.to_set
  sb = b.to_set
  return 0.0 if sa.empty? && sb.empty?

  (sa & sb).size.to_f / (sa | sb).size
end

def mean_pairwise_jaccard(word_lists)
  pairs = word_lists.combination(2).to_a
  return 0.0 if pairs.empty?

  pairs.sum { |a, b| jaccard(a, b) } / pairs.size
end

# 同じ冒頭/末尾を共有する出力の最大グループ人数（固着の直接的な指標）
def max_shared_group(texts, len, from: :head)
  keys = texts.reject { |t| t.to_s.length < len }.map do |t|
    from == :head ? t[0, len] : t[-len, len]
  end
  return 0 if keys.empty?

  keys.tally.values.max
end

def summarize(label, outputs, nm)
  valid = outputs.reject { |o| o.to_s.strip.empty? }
  return puts("#{label}: 有効出力なし") if valid.empty?

  lists = valid.map { |t| content_words(nm, t) }
  tokens = lists.flatten
  distinct_ratio = valid.uniq.size.to_f / valid.size
  ttr = tokens.empty? ? 0.0 : tokens.uniq.size.to_f / tokens.size

  puts format("  %-11s n=%-3d 異なり率=%.2f  冒頭6字最大一致=%d/%d  末尾5字最大一致=%d/%d  " \
              "語彙Jaccard(平均)=%.3f  内容語TTR=%.2f  平均文字数=%.1f",
              label, valid.size, distinct_ratio,
              max_shared_group(valid, 6, from: :head), valid.size,
              max_shared_group(valid, 5, from: :tail), valid.size,
              mean_pairwise_jaccard(lists), ttr,
              valid.sum(&:length).to_f / valid.size)

  freq = tokens.tally.sort_by { |w, c| [-c, w] }.first(6)
  puts "               頻出内容語: #{freq.map { |w, c| "#{w}(#{c})" }.join(' ')}"
end

# ---------------------------------------------------------------- 準備
rg   = RengaGenerator.new(MAEKU, [], :chouku, constraints: {})
nm   = rg.send(:build_mecab)
pool = Rails.cache.fetch("seed_pool_v2", expires_in: 1.hour) { rg.send(:build_seed_pool, nm) }
srand(SRAND_SEED)
var_seeds = pool.sample(N)
fix_seed  = var_seeds.first
bui       = BuiDictionary.new

puts "測定: 初回生成プロンプト vs forced_zatsuレスキュープロンプト"
puts "前句: #{MAEKU}"
puts "試行数: #{N}／条件   seed pool: #{pool.size}件   固定seed: #{fix_seed[:surface]}"
puts "温度: 両者0.6（Step1は明示指定、レスキューはqwen3:8b既定値）"
puts

def step1_once(maeku, seed, persona, mode, nm, bui, idx)
  g = StepwiseWakaGenerator.new(
    maeku, :chouku,
    constraints: { gaze_mode: mode,
                   log_context: { batch: "sono77_fixation_#{mode}", verse_no: idx, attempt: 1 } },
    pool: [seed], nm: nm, bui_dict: bui
  )
  g.instance_variable_set(:@draft_attempt, 1)
  g.instance_variable_set(:@current_seed, seed)
  g.instance_variable_set(:@current_persona, persona)
  g.send(:generate_free_verse, seed, persona).to_s
rescue RuntimeError, Net::ReadTimeout => e
  warn "  [skip] #{e.class}: #{e.message}"
  ""
end

# ---------------------------------------------------------------- 収集
results = {}
run = ->(label) { ONLY.empty? || ONLY.include?(label) }

if run.call("S1_varseed")
  results["S1_varseed"] = N.times.map do |i|
    step1_once(MAEKU, var_seeds[i], WakaPersona.resolve(nil, MAEKU), :abstract, nm, bui, i + 1)
  end
end

youth = WakaPersona::PERSONAS[:youth]
if run.call("S1_fixseed")
  results["S1_fixseed"] = N.times.map do |i|
    step1_once(MAEKU, fix_seed, youth, :abstract, nm, bui, i + 1)
  end
end

if run.call("S1_literal")
  results["S1_literal"] = N.times.map do |i|
    step1_once(MAEKU, fix_seed, youth, :literal, nm, bui, i + 1)
  end
end

# レスキューは観測スクリプトの実装をそのまま再現する（script/observe_waka_extraction.rb:174）
def rescue_messages(maeku, target_mora, trigger_labels, threshold)
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

# app/services/renga_generator.rb:452 と同じ「使用不可」リスト付きの最終ターンへ差し替える。
def rescue_messages_with_banlist(maeku, target_mora, trigger_labels, threshold, past_words)
  msgs = rescue_messages(maeku, target_mora, trigger_labels, threshold)
  msgs[-1] = { role: "user",
               content: "では局面打開のため、雑の句として、これまでの候補にない語を用いて" \
                        "#{target_mora}音の付け句を詠んでください。\n" \
                        "前句：#{maeku}\n" \
                        "これまでの候補（使用不可）：#{past_words.join('、')}\n" \
                        "#{target_mora}音を一行だけ出力してください。説明不要。" }
  msgs
end

def chat_once(messages)
  raw = OllamaClient.chat(messages, think: false, timeout: 300)
  raw.to_s.strip.lines.map(&:strip).reject(&:empty?).first.to_s
rescue RuntimeError, Net::ReadTimeout => e
  warn "  [skip] #{e.class}: #{e.message}"
  ""
end

target_mora = (TARGET_VT == :chouku) ? 17 : 14

if run.call("RESCUE") || run.call("RESCUE_ban")
  results["RESCUE"] = N.times.map do
    chat_once(rescue_messages(MAEKU, target_mora, TRIGGER, THRESHOLD))
  end
end

if run.call("RESCUE_ban")
  # 使用不可リストはRESCUE条件の出力（＝そのプロンプトが固着した句）を固定で与える。
  # 全試行で同一リストなのでRESCUEと直接比較できる。
  past = results["RESCUE"].reject { |t| t.to_s.strip.empty? }
  results["RESCUE_ban"] = N.times.map do
    chat_once(rescue_messages_with_banlist(MAEKU, target_mora, TRIGGER, THRESHOLD, past))
  end
end

# ---------------------------------------------------------------- 出力
results.each do |label, outputs|
  puts "===== #{label} ====="
  outputs.each_with_index { |o, i| puts format("  %2d. %s", i + 1, o) }
  puts
end

puts "===== 固着度サマリー（異なり率・TTRは高いほど柔軟、最大一致・Jaccardは高いほど固着）====="
results.each { |label, outputs| summarize(label, outputs, nm) }
