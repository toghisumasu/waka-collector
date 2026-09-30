# frozen_string_literal: true
# 依頼書S-0b: 軸別呼び出しによる qwen3:8b スコアリング（S-0 の切り分け実験）
#
# S-0 は3軸を1回の呼び出しで同時に出させ、「2/3/4」に約75%固着した。本スクリプトは変数を1つだけ変える:
# 「1ペア×1軸×1試行」を1呼び出しとして、軸ごとに別々に呼ぶ。それ以外（尺度の文言・パラメータ・パース規則・
# ペア規則）はS-0（script/score_minase_pairs_qwen8b.rb）と同一。
#
# 実行（本番）: WAKA_OLLAMA_MODEL=qwen3:8b bin/rails runner script/score_minase_pairs_qwen8b_split.rb
# 実行（試験）: WAKA_OLLAMA_MODEL=qwen3:8b TRIAL_PAIRS=1,32,50,71 bin/rails runner script/score_minase_pairs_qwen8b_split.rb
#   試験は指定ペアだけを3軸×3試行で採点し、tmp/minase_qwen8b_split_trial_raw.csv にだけ書く
#
# app/・S-0のスクリプト/出力・盲検シートは変更しない。判定・閾値決定・本番配線はしない。記述統計のみ。
#
# 測定条件（S-0と同一）:
# ・/api/generate、stream:false、think:false（APIパラメータ）、options: {temperature 0.3, num_predict 60}
# ・repeat_penalty / top_p / top_k / seed / format は送らない
# ・各呼び出しは独立した単発リクエスト。渡すのは前句・付句の本文のみ（折・季・bui・型のヒントなし）
# ・パース: 最初の {...} を抜き出し、指定キーの値が1〜5の整数か確認。失敗は1回だけ再試行、それでも失敗ならparse_ok=false
# ・呼び出し順: 試行 → ペア → 軸

require "csv"
require "json"
require "net/http"
require "set"

MODEL         = ENV["WAKA_OLLAMA_MODEL"].to_s
BASE_URL      = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
TEMPERATURE   = 0.3
NUM_PREDICT   = 60
TRIALS        = 3
HTTP_TIMEOUT  = 120
MAX_CONSEC_ERRORS = 5
TRIAL_PAIRS   = ENV["TRIAL_PAIRS"].to_s.split(",").map(&:to_i)
TRIAL_MODE    = !TRIAL_PAIRS.empty?
TRIAL_STOP_FAILS = 4 # 3ペア確認の停止基準: 最終parse失敗が 4/36 以上、または n のオウム返しが1件でも
TRIAL_EXPECTED_CALLS = 36

AXES = [
  { key: "season_gap",   definition: "季節感の離れ" },
  { key: "material_gap", definition: "句材（題材）の離れ" },
  { key: "scene_gap",    definition: "情景の離れ" }
].freeze
AXIS_KEYS = AXES.map { |a| a[:key] }.freeze

PROMPT_TEMPLATE = <<~PROMPT.freeze
  あなたは連歌の付合を評価する。次の前句と付句を読み、「{axis_def}」を1〜5の整数で評価せよ。
  1 = ほぼ同じ・非常に近い、5 = まったく異なる・非常に遠い。

  JSONのみを出力せよ。説明は不要。
  {"{key}": n}

  前句：{maeku}
  付句：{tsukeku}
PROMPT

TMP          = Rails.root.join("tmp")
RAW_PATH     = TMP.join("minase_qwen8b_split_raw.csv")
SUMMARY_PATH = TMP.join("minase_qwen8b_split_summary.csv")
TRIAL_PATH   = TMP.join("minase_qwen8b_split_trial_raw.csv")
BUI_PATH     = TMP.join("minase_bui_distance_report.csv")
S0_RAW_PATH     = TMP.join("minase_qwen8b_score_raw.csv")
S0_SUMMARY_PATH = TMP.join("minase_qwen8b_score_summary.csv")

abort "WAKA_OLLAMA_MODEL が未指定です（例: WAKA_OLLAMA_MODEL=qwen3:8b）" if MODEL.empty?

RESPONSE_MODELS = Set.new

def axis_prompt(axis, maeku: "{maeku}", tsukeku: "{tsukeku}")
  PROMPT_TEMPLATE.gsub("{axis_def}") { axis[:definition] }.gsub("{key}") { axis[:key] }
                 .gsub("{maeku}") { maeku }.gsub("{tsukeku}") { tsukeku }
end

def load_verses
  verses = {}
  File.foreach(Rails.root.join("docs", "minase_sangin_hyakuin.md")) do |line|
    next unless line.start_with?("|")
    cols = line.split("|").map(&:strip)
    next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
    no = cols[1].to_i
    next unless no.between?(1, 100) && cols[4] && !cols[4].empty?
    verses[no] = { text: cols[4], season: cols[5].to_s }
  end
  raise "水無瀬三吟100句が読み込めません（#{verses.size}句）" unless verses.size == 100
  verses
end

def build_pairs(verses)
  (1..99).map { |no| { pair_no: no, maeku: verses[no][:text], tsukeku: verses[no + 1][:text] } }
end

def call_ollama(prompt)
  uri  = URI("#{BASE_URL}/api/generate")
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = HTTP_TIMEOUT
  req = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
  req.body = { model: MODEL, prompt: prompt, stream: false, think: false,
               options: { temperature: TEMPERATURE, num_predict: NUM_PREDICT } }.to_json
  res = http.request(req)
  raise "HTTP #{res.code}: #{res.body.to_s[0, 200]}" unless res.is_a?(Net::HTTPSuccess)
  body = JSON.parse(res.body)
  RESPONSE_MODELS << body["model"].to_s
  body
end

# 最初の {...} を抜き出し、指定キーの値が1〜5の整数か確認する（<think></think>が先頭に付いても可）
def parse_gap(raw, key)
  body = raw.to_s.gsub(%r{<think>.*?</think>}m, "")
  json = body[/\{.*?\}/m]
  return nil unless json
  v = JSON.parse(json)[key]
  v.is_a?(Integer) && v.between?(1, 5) ? v : nil
rescue JSON::ParserError
  nil
end

# 1呼び出し（parse失敗は1回だけ再試行）。[gap|nil, raw_output, retried, error?]
def run_call(prompt, key)
  raw = nil
  2.times do |attempt|
    begin
      raw = call_ollama(prompt)["response"].to_s
    rescue StandardError => e
      raw = "ERROR: #{e.message}"
      return [nil, raw, attempt == 1, true] if attempt == 1
      next
    end
    gap = parse_gap(raw, key)
    return [gap, raw, attempt == 1, false] if gap
  end
  [nil, raw, true, raw.start_with?("ERROR:")]
end

def n_echo?(raw, key) = raw.to_s.match?(/"#{key}"\s*:\s*"?n"?\s*[,}]/)
def think_leak?(raw) = raw.to_s.include?("<think")

def median(a)
  s = a.sort
  s.size.odd? ? s[s.size / 2] : (s[s.size / 2 - 1] + s[s.size / 2]) / 2.0
end

def rank(values)
  sorted = values.each_with_index.sort_by { |v, _| v }
  ranks = Array.new(values.size)
  i = 0
  while i < sorted.size
    j = i
    j += 1 while j + 1 < sorted.size && sorted[j + 1][0] == sorted[i][0]
    avg = (i + j) / 2.0 + 1
    (i..j).each { |k| ranks[sorted[k][1]] = avg }
    i = j + 1
  end
  ranks
end

def spearman(xs, ys)
  return nil if xs.size < 3
  rx, ry = rank(xs), rank(ys)
  mx, my = rx.sum / rx.size, ry.sum / ry.size
  num = rx.zip(ry).sum { |a, b| (a - mx) * (b - my) }
  den = Math.sqrt(rx.sum { |a| (a - mx)**2 } * ry.sum { |b| (b - my)**2 })
  den.zero? ? nil : num / den
end

# コメント行（# 始まり）はCSVのクォート処理を通さず生テキストで書く（読み手は # 始まりの行を読み飛ばす）
def write_csv_with_comments(path, comments)
  File.open(path, "w") { |f| comments.each { |c| f.puts(c) } }
  CSV.open(path, "a") { |csv| yield csv }
end

def rotate_existing(path)
  return unless File.exist?(path)
  n = 1
  n += 1 while File.exist?("#{path}.bak#{n}")
  File.rename(path, "#{path}.bak#{n}")
  puts "既存出力を退避: #{File.basename(path)} → #{File.basename(path)}.bak#{n}"
end

def header_comments
  version = begin
    JSON.parse(Net::HTTP.get(URI("#{BASE_URL}/api/version")))["version"]
  rescue StandardError
    "取得失敗"
  end
  head = begin
    `git -C #{Rails.root} rev-parse --short HEAD`.strip
  rescue StandardError
    "?"
  end
  cmd = "WAKA_OLLAMA_MODEL=#{MODEL}#{TRIAL_MODE ? " TRIAL_PAIRS=#{TRIAL_PAIRS.join(',')}" : ''} bin/rails runner script/score_minase_pairs_qwen8b_split.rb"
  lines = [
    "依頼書S-0b 水無瀬三吟 付合ペア qwen3:8b 軸別呼び出しスコアリング（raw・呼び出し単位。1ペア×1軸×1試行が1行）",
    "model: #{MODEL} / 応答のmodelフィールド: #{RESPONSE_MODELS.to_a.join(',')}",
    "temperature: #{TEMPERATURE}（options内） / num_predict: #{NUM_PREDICT}（options内） / think: false（APIパラメータ）",
    "repeat_penalty: 未送信（Modelfile既定） / top_p・top_k: 未送信（Modelfile既定） / seed: 未固定（再実行しても同じ値にならない） / format: 未使用",
    "trials_per_pair_axis: #{TRIALS} / parse失敗は1回だけ再試行（retried列） / http_timeout: #{HTTP_TIMEOUT}s / ollama: #{version} @ #{BASE_URL}",
    "command: #{cmd}",
    "read: CSV.read(path, headers: true, skip_lines: /\\A#/) — # 始まりの行はコメント（クォートなしの生テキスト）",
    "run_at: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %z')} / git HEAD: #{head}",
    "prompt（{maeku}{tsukeku}を本文に置換。軸ごとに定義行とキーだけが違う）:"
  ]
  AXES.each do |axis|
    lines << "[#{axis[:key]}]"
    axis_prompt(axis).lines.each { |l| lines << "  #{l.chomp}" }
  end
  lines.map { |l| "# #{l}" }
end

# ---- 採点 ----
def score_all(pairs)
  rows = []
  consec_errors = 0
  TRIALS.times do |t|
    pairs.each_with_index do |pair, idx|
      AXES.each do |axis|
        prompt = axis_prompt(axis, maeku: pair[:maeku], tsukeku: pair[:tsukeku])
        gap, raw, retried, errored = run_call(prompt, axis[:key])
        consec_errors = errored ? consec_errors + 1 : 0
        abort "Ollamaエラーが#{MAX_CONSEC_ERRORS}呼び出し連続しました。中断: #{raw}" if consec_errors >= MAX_CONSEC_ERRORS
        rows << { pair_no: pair[:pair_no], maeku: pair[:maeku], tsukeku: pair[:tsukeku], axis: axis[:key],
                  trial: t + 1, gap: gap, parse_ok: !gap.nil?, retried: retried, raw: raw }
        puts "  pair #{pair[:pair_no]} #{axis[:key]} trial #{t + 1}: #{gap || 'PARSE FAIL'}#{retried ? ' (retried)' : ''} | #{raw.to_s.gsub(/\s+/, ' ')[0, 80]}" if TRIAL_MODE
      end
      puts "trial #{t + 1}: #{idx + 1}/#{pairs.size} pairs done (#{Time.now.strftime('%H:%M:%S')})" if !TRIAL_MODE && ((idx + 1) % 10).zero?
    end
  end
  rows
end

def write_raw(path, rows)
  write_csv_with_comments(path, header_comments) do |csv|
    csv << %w[pair_no maeku tsukeku axis trial gap parse_ok retried raw_output]
    rows.each { |r| csv << [r[:pair_no], r[:maeku], r[:tsukeku], r[:axis], r[:trial], r[:gap], r[:parse_ok], r[:retried], r[:raw]] }
  end
end

def read_csv(path) = CSV.read(path, headers: true, skip_lines: /\A#/)

def build_summary(rows)
  bui = read_csv(BUI_PATH).to_h { |r| [r["pair_no"].to_i, r] }
  s0  = read_csv(S0_SUMMARY_PATH).to_h { |r| [r["pair_no"].to_i, r] }
  rows.group_by { |r| r[:pair_no] }.sort.map do |pair_no, trs|
    b = bui.fetch(pair_no) { raise "bui距離レポートにpair_no #{pair_no} がありません" }
    z = s0.fetch(pair_no) { raise "S-0 summaryにpair_no #{pair_no} がありません" }
    raise "pair_no #{pair_no} の本文がbui距離レポートと一致しません" unless b["maeku_text"] == trs.first[:maeku] && b["tsugeku_text"] == trs.first[:tsukeku]
    raise "pair_no #{pair_no} の本文がS-0 summaryと一致しません" unless z["maeku"] == trs.first[:maeku] && z["tsukeku"] == trs.first[:tsukeku]
    stats = AXIS_KEYS.to_h do |k|
      vals = trs.select { |r| r[:axis] == k && r[:parse_ok] }.map { |r| r[:gap] }
      [k, vals.empty? ? { n: 0, med: nil, min: nil, max: nil } : { n: vals.size, med: median(vals), min: vals.min, max: vals.max }]
    end
    { pair_no: pair_no, ori: b["ori"], men: b["men"], maeku: trs.first[:maeku], tsukeku: trs.first[:tsukeku], stats: stats,
      bui_distance: b["bui_distance"].to_f, unstable: stats.values.any? { |s| s[:max] && s[:max] - s[:min] >= 2 },
      s0: AXIS_KEYS.to_h { |k| [k, z["#{k}_median"]&.to_f] } }
  end
end

def write_summary(summary)
  comment = "# 依頼書S-0b ペア単位の集計（rawとtmp/minase_bui_distance_report.csv・S-0 summaryから再生成可能）。中央値・最小・最大はparse成功呼び出しのみ（各軸最大3試行）。unstable=いずれかの軸で最大-最小>=2。s0_*=S-0の中央値"
  write_csv_with_comments(SUMMARY_PATH, [comment]) do |csv|
    csv << (%w[pair_no ori men maeku tsukeku] + AXIS_KEYS.flat_map { |k| %W[#{k}_n_ok #{k}_median #{k}_min #{k}_max] } +
            %w[bui_distance unstable s0_season s0_material s0_scene])
    summary.each do |s|
      csv << ([s[:pair_no], s[:ori], s[:men], s[:maeku], s[:tsukeku]] +
              AXIS_KEYS.flat_map { |k| [s[:stats][k][:n], s[:stats][k][:med], s[:stats][k][:min], s[:stats][k][:max]] } +
              [s[:bui_distance], s[:unstable]] + AXIS_KEYS.map { |k| s[:s0][k] })
    end
  end
end

# ---- 記述統計 ----
def dist_line(vals) = (1..5).map { |v| vals.count(v) }.join(" | ")

def mode_share(vals)
  return "-" if vals.empty?
  v, n = vals.tally.max_by { |_, c| c }
  "#{v} が #{n}/#{vals.size}（#{format('%.1f', 100.0 * n / vals.size)}%）"
end

def triples(gap_rows_by_key)
  gap_rows_by_key.filter_map { |_, trs| trs.map { |r| r[:gap] } if trs.size == 3 && trs.all? { |r| r[:parse_ok] } }
end

def print_triples(label, triple_list, total)
  t = triple_list.map { |x| x.join("/") }.tally.sort_by { |_, v| -v }
  top = t.first
  puts "#{label}: 対象 #{triple_list.size}/#{total}、組の種類 #{t.size}、最頻 #{top ? "#{top[0]} が #{top[1]}（#{format('%.1f', 100.0 * top[1] / triple_list.size)}%）" : '-'}"
  puts "  上位: #{t.first(5).map { |k, v| "#{k}=#{v}" }.join(' ')}"
end

def season_class(s) = %w[春 夏 秋 冬].include?(s) ? s : "無季"

def print_stats(rows, summary, verses)
  s0_raw = read_csv(S0_RAW_PATH).map { |r| { pair_no: r["pair_no"].to_i, trial: r["trial"].to_i, ok: r["parse_ok"] == "true",
                                             vals: AXIS_KEYS.map { |k| r[k]&.to_i } } }
  s0_summary = read_csv(S0_SUMMARY_PATH).to_h { |r| [r["pair_no"].to_i, r] }
  ok = rows.select { |r| r[:parse_ok] }

  puts "\n## 記述統計（判断・閾値提案はしない）"

  puts "\n### 1. 各軸の値の度数分布（1〜5）と最頻値の占有率（S-0と並べる）"
  puts "| 軸 | 版 | 1 | 2 | 3 | 4 | 5 | 最頻値の占有率 |", "|---|---|---:|---:|---:|---:|---:|---|"
  AXIS_KEYS.each_with_index do |k, i|
    s0v = s0_raw.select { |r| r[:ok] }.map { |r| r[:vals][i] }
    s0bv = ok.select { |r| r[:axis] == k }.map { |r| r[:gap] }
    puts "| #{k} | S-0 | #{dist_line(s0v)} | #{mode_share(s0v)} |"
    puts "| #{k} | S-0b | #{dist_line(s0bv)} | #{mode_share(s0bv)} |"
  end

  puts "\n### 2. 3軸の組（ペア×試行）の種類数と最頻の組の占有率"
  print_triples("S-0 ", s0_raw.select { |r| r[:ok] }.map { |r| r[:vals] }, s0_raw.size)
  print_triples("S-0b", triples(rows.group_by { |r| [r[:pair_no], r[:trial]] }), rows.map { |r| [r[:pair_no], r[:trial]] }.uniq.size)

  puts "\n### 3. unstable ペア"
  uns = summary.select { |s| s[:unstable] }
  puts "S-0b: #{uns.size} 件（S-0 は #{s0_summary.values.count { |r| r['unstable'] == 'true' }} 件: #{s0_summary.values.select { |r| r['unstable'] == 'true' }.map { |r| r['pair_no'] }.join(', ')}）"
  uns.each { |s| puts "- pair #{s[:pair_no]}（#{s[:ori]}#{s[:men]}）: " + AXIS_KEYS.map { |k| "#{k} #{s[:stats][k][:min]}〜#{s[:stats][k][:max]}" }.join(' / ') }

  puts "\n### 4. 各軸中央値と bui距離の Spearman 相関（参考値。同順位の多さを併記）"
  puts "| 軸 | 版 | Spearman | n | 中央値の異なる値の数 | 最大の同順位グループ |", "|---|---|---:|---:|---:|---:|"
  AXIS_KEYS.each do |k|
    s0pr = summary.select { |s| s[:s0][k] }
    s0r = spearman(s0pr.map { |s| s[:s0][k] }, s0pr.map { |s| s[:bui_distance] })
    s0t = s0pr.map { |s| s[:s0][k] }.tally
    pr = summary.select { |s| s[:stats][k][:med] }
    r = spearman(pr.map { |s| s[:stats][k][:med] }, pr.map { |s| s[:bui_distance] })
    t = pr.map { |s| s[:stats][k][:med] }.tally
    puts "| #{k} | S-0 | #{s0r ? format('%.3f', s0r) : 'N/A'} | #{s0pr.size} | #{s0t.size} | #{s0t.values.max} |"
    puts "| #{k} | S-0b | #{r ? format('%.3f', r) : 'N/A'} | #{pr.size} | #{t.size} | #{t.values.max} |"
  end

  puts "\n### 5. pair 1 と 71 の全値（S-0 では両方「2/3/4」）"
  [1, 71].each do |n|
    s0t = s0_raw.select { |r| r[:pair_no] == n }.map { |r| r[:vals].join("/") }
    puts "pair #{n}（#{verses[n][:season]}→#{verses[n + 1][:season]}）: S-0 試行別 #{s0t.join(' , ')}"
    AXIS_KEYS.each { |k| puts "  S-0b #{k}: #{rows.select { |r| r[:pair_no] == n && r[:axis] == k }.sort_by { |r| r[:trial] }.map { |r| r[:gap] || 'FAIL' }.join(' ')}" }
  end

  puts "\n### 6. 季移りの照合（原表の季欄。春夏秋冬・無季の区分が前句と付句で違えば「あり」。雑↔恋は季移りにしない）"
  strata = summary.group_by { |s| season_class(verses[s[:pair_no]][:season]) != season_class(verses[s[:pair_no] + 1][:season]) ? "あり" : "なし" }
  %w[あり なし].each do |k|
    ps = strata[k] || []
    s0m = ps.filter_map { |s| s[:s0]["season_gap"] }
    sbm = ps.filter_map { |s| s[:stats]["season_gap"][:med] }
    puts "季移り#{k}（#{ps.size}ペア）:"
    puts "  S-0  season_gap中央値の平均 #{s0m.empty? ? '-' : format('%.2f', s0m.sum / s0m.size)} / 度数 #{s0m.tally.sort.map { |v, n| "#{v}=#{n}" }.join(' ')}"
    puts "  S-0b season_gap中央値の平均 #{sbm.empty? ? '-' : format('%.2f', sbm.sum / sbm.size)} / 度数 #{sbm.tally.sort.map { |v, n| "#{v}=#{n}" }.join(' ')}"
  end

  puts "\n### 7. parse失敗と再試行"
  failed = rows.count { |r| !r[:parse_ok] }
  puts "呼び出し #{rows.size} 中 最終失敗 #{failed}（#{format('%.1f', 100.0 * failed / rows.size)}%） / 再試行が発生した呼び出し #{rows.count { |r| r[:retried] }}"
  puts "nのオウム返し #{rows.count { |r| n_echo?(r[:raw], r[:axis]) }} / <think>混入 #{rows.count { |r| think_leak?(r[:raw]) }}"
  AXIS_KEYS.each { |k| puts "  #{k}: 失敗 #{rows.count { |r| r[:axis] == k && !r[:parse_ok] }}" }
  puts "応答のmodel: #{RESPONSE_MODELS.to_a.join(',')}"
end

verses = load_verses
pairs  = build_pairs(verses)
puts "model=#{MODEL} temperature=#{TEMPERATURE} num_predict=#{NUM_PREDICT} think=false trials=#{TRIALS} axes=#{AXIS_KEYS.join(',')} url=#{BASE_URL}"

if TRIAL_MODE
  targets = pairs.select { |p| TRIAL_PAIRS.include?(p[:pair_no]) }
  abort "TRIAL_PAIRS に該当ペアがありません" if targets.empty?
  rows = score_all(targets)
  write_raw(TRIAL_PATH, rows)
  fails = rows.count { |r| !r[:parse_ok] }
  echoes = rows.count { |r| n_echo?(r[:raw], r[:axis]) }
  leaks = rows.count { |r| think_leak?(r[:raw]) }
  puts "\n試験: #{rows.size} 呼び出し 最終parse失敗 #{fails} / nオウム返し #{echoes} / <think>混入 #{leaks} / 再試行 #{rows.count { |r| r[:retried] }}（応答のmodel: #{RESPONSE_MODELS.to_a.join(',')}）"
  stop = fails * TRIAL_EXPECTED_CALLS >= TRIAL_STOP_FAILS * rows.size || echoes.positive?
  puts "停止基準（最終parse失敗が #{TRIAL_STOP_FAILS}/#{TRIAL_EXPECTED_CALLS} 以上、または nオウム返し1件以上）: #{stop ? '該当 → 全走せず報告して停止' : '非該当 → 全走へ進める'}"
  puts "出力: #{TRIAL_PATH}"
  puts "\n（以下は記述統計コードの動作確認。試験の対象ペアだけの値で、summaryは書かない）"
  print_stats(rows, build_summary(rows), verses)
else
  [S0_RAW_PATH, S0_SUMMARY_PATH, BUI_PATH].each { |p| abort "入力がありません: #{p}" unless File.exist?(p) }
  [RAW_PATH, SUMMARY_PATH].each { |p| rotate_existing(p) }
  t0 = Time.now
  rows = score_all(pairs)
  write_raw(RAW_PATH, rows)
  summary = build_summary(rows)
  write_summary(summary)
  puts "完了: #{rows.size} 呼び出し / #{summary.size} ペア / #{(Time.now - t0).round}秒"
  puts "出力: #{RAW_PATH}\n      #{SUMMARY_PATH}"
  print_stats(rows, summary, verses)
end
