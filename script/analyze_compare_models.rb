# frozen_string_literal: true
# 依頼書M-2 Phase1: script/compare_models.rb（依頼書M）が出力した既存CSVを
# 追加列で再分析する。生成の再実行は行わない（既存CSVの読み取りのみ）。
#
# 実行: bin/rails runner script/analyze_compare_models.rb [CSVパス]
#   （省略時は tmp/compare_models_*.csv のうち最新（ファイル名の日時が最大）を使う）
#
# 追加列:
#   maeku_text    … 前句本文（MAEKU_LOOKUP、compare_models.rbのMAEKU_SETを複製）
#   overlap       … 前句⇄付句の内容語Jaccard重複率。
#                   script/measure_minase_distance.rbのnon_overlap_rate計算を
#                   そのまま再利用し、overlap = 1.0 - non_overlap_rate として使う。
#   partial_echo  … overlapが「水無瀬三吟99ペアの実測非重複率の最小値」を
#                   下回れば真。閾値の根拠はNON_OVERLAP_MIN_BASIS参照。
#   maeku_bui     … 前句のbui（BuiDictionary#detect_all）
#   bui_distance  … maeku_bui⇄付句bui（既存CSVのbui列）のJaccard距離。
#                   script/measure_bui_distance.rbのbui_jaccard_distanceを再利用。
#                   （Phase0確認事項: どちらか一方だけが空集合の場合も
#                   通常の1.0-交差/和集合の式で計算され、nil化はしない。
#                   bui未検出0件の行はdeflock/echo等と紛れる可能性があるため、
#                   failure_type列で別途区別できるようにしている）
#   failure_type  … timeout > error > empty > echo > mora_ng > shikimoku_ng >
#                   partial_echo > ok の優先順で1行1分類。
#
# eval_ms/load_ms/eval_count の補正（依頼書M-2 Phase1 (A)指示）:
#   - Phase0で確認した$LAST_RESPONSE_META汚染バグ（timeout発生時、Ollama応答
#     パース前に例外が飛ぶため直前の別呼び出しの値が残る）を踏まえ、
#     raw列に「タイムアウトしました」を含む行はeval_ms/load_ms/eval_countを
#     すべてnilに補正する。
#   - 成功行も、RengaGenerator/StepwiseWakaGeneratorの内部リトライ
#     （5×5等）が複数回Ollamaを呼び出すうちの「最後の1回分」のみを反映する
#     値であり、生成1回あたりの累積実処理時間ではない（このスクリプトの
#     出力にコメントとして明記するのみで、値そのものへの補正はしない）。
#     累積の壁時計時間は script/measure_compare_walltime.rb で別途計測する。
#
# deflock_hits列は追加しない。理由:
#   log/stepwise_steps_*.jsonlのStepwiseStepLogger記録には呼び出しモデル名が
#   記録されておらず（batch/verse_no/attemptのみ）、compare_models.rbの
#   $COMPARE_MODEL上書きがログ側に反映されないため、qwen3:14bとbonsai2-waka
#   のどちらの試行かをログ単体から判別できない。さらに実際にログを調査した
#   ところ、30通り（前句10×trial3）のうち8通りで「draft_attempt=1から始まる
#   generate()呼び出し」が期待される2回（モデル2つ×1回）ではなく3〜5回
#   検出された（過去の中断・再実行の残骸が同一batch名で混在していると
#   推測される）。個別行への割り当てを行うと誤帰属のリスクが高いため、
#   本スクリプトでは per-row のdeflock_hits列を設けず、末尾の集計サマリで
#   「両モデル合算・全batch=compare_models記録に対するdeflock率」のみを
#   参考値として表示する（モデル別に分解できない点を明記する）。
#
# app/配下は無変更。DB書き込みなし。既存CSVの上書きなし（新規ファイルに出力）。

require "csv"
require "natto"
require "json"

# ─────────────────────────────────────────────────────────
# 前句セット（script/compare_models.rb MAEKU_SETの複製、参照用）
# ─────────────────────────────────────────────────────────
MAEKU_SET = [
  { no: 1,  text: "雪ながら山本かすむ夕べかな" },
  { no: 5,  text: "月や猶霧わたる夜に残るらん" },
  { no: 17, text: "はるゝまも袖は時雨の旅衣" },
  { no: 11, text: "今更にひとり有る身をおもふなよ" },
  { no: 21, text: "見しはみな古郷人の跡もうし" },
  { no: 2,  text: "行く水とほく梅にほふ里" },
  { no: 6,  text: "霜おく野はら秋は暮れけり" },
  { no: 32, text: "たのむもはかなつま木とる山" },
  { no: 4,  text: "舟さす音もしるきあけがた" },
  { no: 8,  text: "かきねをとへばあらはなるみち" },
].freeze
MAEKU_LOOKUP = MAEKU_SET.each_with_object({}) { |m, h| h[m[:no]] = m[:text] }.freeze

# 水無瀬三吟99ペアの実測非重複率 最小値（script/measure_minase_distance.rb実行結果）。
# 最小ペア: pair37 君を置きてあかずも誰をおもふらん／そのおもかげにたるだになし
#           （共有内容語「おも」1語、和集合9語 → non_overlap=1-1/9=0.888889）。
# 実際に許容された古典連歌99ペア中、この値を下回る重複は観測されていない
# （史上最大重複率=0.111111）ため、これを下回る非重複率（＝これを超える重複率）を
# partial_echoの閾値とする。
NON_OVERLAP_MIN_BASIS = 0.888889

CONTENT_POS_IPADIC = %w[名詞 動詞 形容詞 副詞].freeze

def build_mecab
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end

NM       = build_mecab
BUI_DICT = BuiDictionary.new

def extract_content_words(text)
  words = []
  NM.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos? || node.surface.empty?
    pos = node.feature.split(",").first
    words << node.surface if CONTENT_POS_IPADIC.include?(pos)
  end
  words
end

# script/measure_bui_distance.rb と同一の式。
def bui_jaccard_distance(set_a, set_b)
  return 1.0 if set_a.empty? && set_b.empty?
  intersection = (set_a & set_b).size
  union = (set_a | set_b).size
  1.0 - intersection.to_f / union
end

def overlap_rate(maeku_text, tsukeku_text)
  maeku_words   = extract_content_words(maeku_text)
  tsukeku_words = extract_content_words(tsukeku_text)
  shared = (maeku_words & tsukeku_words).uniq
  union  = (maeku_words | tsukeku_words).uniq
  return 0.0 if union.empty?

  non_overlap = 1.0 - (shared.size.to_f / union.size)
  1.0 - non_overlap
end

def classify_failure_type(raw, tsukeku, echo, mora_ok, shikimoku_ok, partial_echo)
  return "timeout" if raw.to_s.include?("タイムアウトしました")
  return "error"   if tsukeku.blank? && raw.to_s.include?("エラー")
  return "empty"   if tsukeku.blank?
  return "echo"         if echo == "true"
  return "mora_ng"      if mora_ok == "false"
  return "shikimoku_ng" if shikimoku_ok == "false"
  return "partial_echo" if partial_echo

  "ok"
end

# ─────────────────────────────────────────────────────────
# 入力CSVの選定
# ─────────────────────────────────────────────────────────
in_path = ARGV[0] || Dir.glob(Rails.root.join("tmp", "compare_models_*.csv")).max
abort "入力CSVが見つかりません（tmp/compare_models_*.csv）" unless in_path && File.exist?(in_path)

puts "入力: #{in_path}"
rows = CSV.read(in_path, headers: true)
puts "読み込み: #{rows.size}行"

out_rows = []
rows.each do |row|
  maeku_no = row["maeku_no"].to_i
  maeku_text = MAEKU_LOOKUP.fetch(maeku_no) { "" }
  tsukeku    = row["tsukeku"].to_s
  raw        = row["raw"].to_s
  is_timeout = raw.include?("タイムアウトしました")

  overlap      = tsukeku.present? ? overlap_rate(maeku_text, tsukeku).round(6) : nil
  partial_echo = tsukeku.present? && (1.0 - overlap) < NON_OVERLAP_MIN_BASIS

  maeku_bui      = BUI_DICT.detect_all(maeku_text, NM)
  generated_bui  = row["bui"].to_s.split(",").reject(&:empty?)
  bui_distance   = bui_jaccard_distance(maeku_bui, generated_bui).round(6)

  failure_type = classify_failure_type(raw, tsukeku, row["echo"], row["mora_ok"], row["shikimoku_ok"], partial_echo)

  eval_ms    = is_timeout ? nil : row["eval_ms"]
  load_ms    = is_timeout ? nil : row["load_ms"]
  eval_count = is_timeout ? nil : row["eval_count"]

  out_rows << row.to_h.merge(
    "maeku_text"   => maeku_text,
    "overlap"      => overlap,
    "partial_echo" => partial_echo,
    "maeku_bui"    => maeku_bui.join(","),
    "bui_distance" => bui_distance,
    "failure_type" => failure_type,
    "eval_ms"      => eval_ms,
    "load_ms"      => load_ms,
    "eval_count"   => eval_count
  )
end

# ─────────────────────────────────────────────────────────
# 出力
# ─────────────────────────────────────────────────────────
out_path = Rails.root.join("tmp", "analyze_compare_models_#{Time.now.strftime('%Y%m%d_%H%M')}.csv")
headers = out_rows.first.keys
CSV.open(out_path, "w") do |csv|
  csv << headers
  out_rows.each { |r| csv << r.values_at(*headers) }
end
puts "出力: #{out_path}（#{out_rows.size}行）"

# ─────────────────────────────────────────────────────────
# 集計サマリ
# ─────────────────────────────────────────────────────────
puts "\n" + "=" * 70
puts "【failure_type分布】モデル×戦略ごと"
out_rows.group_by { |r| [r["model"], r["strategy"]] }.each do |(model, strategy), group|
  n = group.size
  dist = group.group_by { |r| r["failure_type"] }.transform_values(&:size)
  dist_str = dist.sort_by { |_, c| -c }.map { |k, c| "#{k}=#{c}(#{(100.0*c/n).round(1)}%)" }.join(" ")
  puts "  #{model} / #{strategy} (n=#{n}): #{dist_str}"
end

puts "\n【overlap・partial_echo】モデル×戦略ごと（tsukeku非空行のみ）"
out_rows.group_by { |r| [r["model"], r["strategy"]] }.each do |(model, strategy), group|
  valid = group.reject { |r| r["overlap"].nil? || r["overlap"] == "" }
  next if valid.empty?

  overlaps = valid.map { |r| r["overlap"].to_f }
  pe_rate  = (100.0 * valid.count { |r| r["partial_echo"].to_s == "true" } / valid.size).round(1)
  puts "  #{model} / #{strategy} (n=#{valid.size}): overlap平均=#{(overlaps.sum/overlaps.size).round(4)} " \
       "partial_echo率=#{pe_rate}%"
end

puts "\n【bui_distance】モデル×戦略ごと"
out_rows.group_by { |r| [r["model"], r["strategy"]] }.each do |(model, strategy), group|
  dists = group.map { |r| r["bui_distance"].to_f }
  puts "  #{model} / #{strategy} (n=#{dists.size}): 平均=#{(dists.sum/dists.size).round(4)}"
end

puts "\n【eval_ms（timeout行は補正済みnil、成功行は最終呼び出し1回分のみ）】"
out_rows.group_by { |r| [r["model"], r["strategy"]] }.each do |(model, strategy), group|
  vals = group.filter_map { |r| r["eval_ms"] && r["eval_ms"] != "" ? r["eval_ms"].to_f : nil }
  next if vals.empty?

  puts "  #{model} / #{strategy}: n=#{vals.size}（timeout除外後） 平均=#{(vals.sum/vals.size).round(1)}ms"
end

# ─────────────────────────────────────────────────────────
# deflock参考値（モデル別に分解不可、集計のみ。詳細は本ファイル冒頭コメント参照）
# ─────────────────────────────────────────────────────────
puts "\n" + "=" * 70
puts "【deflock参考値（両モデル合算、per-row非対応の理由は本ファイル冒頭コメント参照）】"
step3_records = []
Dir.glob(Rails.root.join("log", "stepwise_steps_*.jsonl")).each do |path|
  File.foreach(path) do |line|
    next unless line.include?('"batch":"compare_models"')

    rec = JSON.parse(line)
    step3_records << rec if rec["batch"] == "compare_models" && rec["step"] == "step3"
  end
end
if step3_records.empty?
  puts "  対象ログが見つかりません（log/stepwise_steps_*.jsonl、batch=compare_models）"
else
  a1 = step3_records.count { |r| r["rewrite_attempt"] == 1 }
  a5 = step3_records.count { |r| r["rewrite_attempt"] == 5 }
  rate = a1.positive? ? (100.0 * a5 / a1).round(1) : 0.0
  puts "  step3総記録=#{step3_records.size} rewrite_attempt=1到達=#{a1} rewrite_attempt=5到達=#{a5} " \
       "deflock率=#{rate}%（注: batch=compare_modelsの全ログには過去の中断分の残骸が" \
       "混在している可能性があり、正確なモデル別内訳ではない参考値）"
end
