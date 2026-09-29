# frozen_string_literal: true
# 依頼書S-0: 水無瀬三吟 付合ペア（前句→付句、99組）のqwen3:8bスコアリング（基礎データ収集）
#
# 実行（本番）: WAKA_OLLAMA_MODEL=qwen3:8b bin/rails runner script/score_minase_pairs_qwen8b.rb
# 実行（試験）: WAKA_OLLAMA_MODEL=qwen3:8b TRIAL_PAIRS=1,50,71 bin/rails runner script/score_minase_pairs_qwen8b.rb
#   試験は指定ペアだけを採点し、tmp/minase_qwen8b_score_trial_raw.csv にだけ書く（本番出力・盲検シートには触れない）
#
# app/ は変更しない。OllamaClient は temperature がトップレベルに置かれて効かず、num_predict / repeat_penalty も
# 固定なので使わず、ここに薄いHTTP呼び出しを持つ（temperature / num_predict は options の中に入れる）。
# 判定・閾値決定・本番配線はしない。記述統計だけを出す。
#
# 測定条件:
# ・各呼び出しは独立した単発リクエスト（文脈を持ち越さない）。ペアごとに3試行
# ・think:false はAPIパラメータで渡す。repeat_penalty / top_p / top_k / seed は送らない（Modelfile既定・seed未固定）
# ・プロンプトに渡すのは前句・付句の本文のみ（折・季・bui・型のヒントは渡さない）
# ・季・折は盲検シートの層別抽出にだけ使う（プロンプトには入らない）

require "csv"
require "json"
require "net/http"

MODEL         = ENV["WAKA_OLLAMA_MODEL"].to_s
BASE_URL      = ENV.fetch("OLLAMA_URL", "http://localhost:11434")
TEMPERATURE   = 0.3
NUM_PREDICT   = 60
TRIALS        = 3
HTTP_TIMEOUT  = 120
MAX_CONSEC_ERRORS = 5
LABEL_SEED    = 20260930
AXES          = %w[season_gap material_gap scene_gap].freeze
TRIAL_PAIRS   = ENV["TRIAL_PAIRS"].to_s.split(",").map(&:to_i)
TRIAL_MODE    = !TRIAL_PAIRS.empty?

PROMPT_TEMPLATE = <<~PROMPT.freeze
  あなたは連歌の付合を評価する。次の前句と付句を読み、3つの軸で「離れ」を1〜5の整数で評価せよ。
  1 = ほぼ同じ・非常に近い、5 = まったく異なる・非常に遠い。

  - season_gap: 季節感の離れ
  - material_gap: 句材（題材）の離れ
  - scene_gap: 情景の離れ

  JSONのみを出力せよ。説明は不要。
  {"season_gap": n, "material_gap": n, "scene_gap": n}

  前句：{maeku}
  付句：{tsukeku}
PROMPT

# 折面（前句の句番で判定。measure_bui_distance.rb の FOLD_MAP と同じ）
FOLD_FACES = [
  { range: (1..8),   label: "初折表" },
  { range: (9..22),  label: "初折裏" },
  { range: (23..36), label: "二折表" },
  { range: (37..50), label: "二折裏" },
  { range: (51..64), label: "三折表" },
  { range: (65..78), label: "三折裏" },
  { range: (79..92), label: "名残折表" },
  { range: (93..99), label: "名残折裏" }
].freeze
LABEL_QUOTA = { "名残折表" => 3, "名残折裏" => 3 }.freeze # 他の6折面は4ペア → 計30
LABEL_DEFAULT_QUOTA = 4

TMP = Rails.root.join("tmp")
RAW_PATH     = TMP.join("minase_qwen8b_score_raw.csv")
SUMMARY_PATH = TMP.join("minase_qwen8b_score_summary.csv")
LABEL_PATH   = TMP.join("minase_label_sheet.csv")
TRIAL_PATH   = TMP.join("minase_qwen8b_score_trial_raw.csv")
BUI_PATH     = TMP.join("minase_bui_distance_report.csv")

abort "WAKA_OLLAMA_MODEL が未指定です（例: WAKA_OLLAMA_MODEL=qwen3:8b）" if MODEL.empty?

def face_of(maeku_no) = FOLD_FACES.find { |f| f[:range].include?(maeku_no) }[:label]

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

def build_prompt(pair)
  PROMPT_TEMPLATE.gsub("{maeku}") { pair[:maeku] }.gsub("{tsukeku}") { pair[:tsukeku] }
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
  JSON.parse(res.body)
end

# 先頭に <think></think> が付いても、最初の {...} を抜く
def parse_scores(raw)
  body = raw.to_s.gsub(%r{<think>.*?</think>}m, "")
  json = body[/\{.*?\}/m]
  return nil unless json
  h = JSON.parse(json)
  vals = AXES.map { |a| h[a] }
  return nil unless vals.all? { |v| v.is_a?(Integer) && v.between?(1, 5) }
  AXES.zip(vals).to_h
rescue JSON::ParserError
  nil
end

# 1試行（パース失敗は1回だけ再試行）。[scores|nil, raw_output, retried, error?]
def run_trial(prompt)
  raw = nil
  2.times do |attempt|
    begin
      raw = call_ollama(prompt)["response"].to_s
    rescue StandardError => e
      raw = "ERROR: #{e.message}"
      return [nil, raw, attempt == 1, true] if attempt == 1
      next
    end
    scores = parse_scores(raw)
    return [scores, raw, attempt == 1, false] if scores
  end
  [nil, raw, true, raw.start_with?("ERROR:")]
end

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

# コメント行（# 始まり）はCSVのクォート処理を通さず生テキストで書く（読み手は # 始まりの行を読み飛ばせばよい）
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

def header_comments(extra = [])
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
  cmd = "WAKA_OLLAMA_MODEL=#{MODEL}#{TRIAL_MODE ? " TRIAL_PAIRS=#{TRIAL_PAIRS.join(',')}" : ''} bin/rails runner script/score_minase_pairs_qwen8b.rb"
  lines = [
    "依頼書S-0 水無瀬三吟 付合ペア qwen3:8b スコアリング（raw・試行単位）",
    "model: #{MODEL}",
    "temperature: #{TEMPERATURE}（options内） / num_predict: #{NUM_PREDICT}（options内） / think: false（APIパラメータ）",
    "repeat_penalty: 未送信（Modelfile既定） / top_p・top_k: 未送信（Modelfile既定） / seed: 未固定（再実行しても同じ値にならない）",
    "trials_per_pair: #{TRIALS} / parse失敗は1回だけ再試行（retried列） / http_timeout: #{HTTP_TIMEOUT}s / ollama: #{version} @ #{BASE_URL}",
    "command: #{cmd}",
    "read: CSV.read(path, headers: true, skip_lines: /\\A#/) — # 始まりの行はコメント（クォートなしの生テキスト）",
    "run_at: #{Time.now.strftime('%Y-%m-%d %H:%M:%S %z')} / git HEAD: #{head}",
    "prompt（{maeku}{tsukeku}を本文に置換）:"
  ] + PROMPT_TEMPLATE.lines.map { |l| "  #{l.chomp}" } + extra
  lines.map { |l| "# #{l}" }
end

# ---- 盲検シート（30ペア。折面ごとに3〜4ペア、季移りの有無で層別。シード固定） ----
def season_class(s) = %w[春 夏 秋 冬].include?(s) ? s : "無季"

def build_label_sheet(pairs, verses)
  rng = Random.new(LABEL_SEED)
  chosen = []
  FOLD_FACES.each do |face|
    ps = pairs.select { |p| face[:range].include?(p[:pair_no]) }
    quota = LABEL_QUOTA.fetch(face[:label], LABEL_DEFAULT_QUOTA)
    change, same = ps.partition { |p| season_class(verses[p[:pair_no]][:season]) != season_class(verses[p[:pair_no] + 1][:season]) }
    change = change.shuffle(random: rng)
    same = same.shuffle(random: rng)
    picked = []
    if face[:label] == "三折裏"
      koi = same.select { |p| verses[p[:pair_no]][:season] == "恋" && verses[p[:pair_no] + 1][:season] == "恋" }
      raise "三折裏に恋→恋のペアがありません" if koi.empty?
      first = koi.first
      picked << first
      same.delete(first)
    end
    want_change = quota / 2
    picked += change.shift(want_change)
    picked += same.shift(quota - picked.size)
    picked += change.shift(quota - picked.size) if picked.size < quota
    chosen.concat(picked.map { |p| p.merge(face: face[:label]) })
  end
  raise "盲検シートが30ペアになりません（#{chosen.size}）" unless chosen.size == 30
  chosen.sort_by { |p| p[:pair_no] }
end

def write_label_sheet(pairs, verses)
  if File.exist?(LABEL_PATH)
    puts "盲検シートは既に存在するため再生成しません（記入済みの可能性）: #{LABEL_PATH}"
    return
  end
  sheet = build_label_sheet(pairs, verses)
  comments = [
    "# 依頼書S-0 手ラベル用の盲検シート（スコア・bui距離は載せない）",
    "# 抽出: 8折面（前句の句番で判定）ごとに4ペア（名残折表・名残折裏は3ペア）=30ペア。季移りの有無（春夏秋冬・無季[雑・恋]の区分が前句と付句で異なるか）を半々に層別。不足時は他方の層で補う",
    "# 三折裏の4ペアには恋→恋を最低1ペア含める。乱数シード: #{LABEL_SEED}（Random.new）。季は水無瀬原表(md)の季欄"
  ]
  write_csv_with_comments(LABEL_PATH, comments) do |csv|
    csv << %w[pair_no maeku tsukeku label memo]
    sheet.each { |p| csv << [p[:pair_no], p[:maeku], p[:tsukeku], "", ""] }
  end
  puts "盲検シート出力: #{LABEL_PATH}（#{sheet.size}ペア）"
end

# ---- 採点 ----
def score_pairs(pairs)
  rows = []
  consec_errors = 0
  pairs.each_with_index do |pair, idx|
    prompt = build_prompt(pair)
    TRIALS.times do |t|
      scores, raw, retried, errored = run_trial(prompt)
      consec_errors = errored ? consec_errors + 1 : 0
      abort "Ollamaエラーが#{MAX_CONSEC_ERRORS}試行連続しました。中断: #{raw}" if consec_errors >= MAX_CONSEC_ERRORS
      rows << { pair_no: pair[:pair_no], maeku: pair[:maeku], tsukeku: pair[:tsukeku], trial: t + 1,
                scores: scores, parse_ok: !scores.nil?, retried: retried, raw: raw }
      puts "  pair #{pair[:pair_no]} trial #{t + 1}: #{scores ? scores.values.join('/') : 'PARSE FAIL'}#{retried ? ' (retried)' : ''} | #{raw.to_s.gsub(/\s+/, ' ')[0, 100]}" if TRIAL_MODE
    end
    puts "#{idx + 1}/#{pairs.size} pairs done (#{Time.now.strftime('%H:%M:%S')})" if !TRIAL_MODE && ((idx + 1) % 10).zero?
  end
  rows
end

def write_raw(path, rows)
  write_csv_with_comments(path, header_comments) do |csv|
    csv << %w[pair_no maeku tsukeku trial season_gap material_gap scene_gap parse_ok raw_output retried]
    rows.each do |r|
      s = r[:scores]
      csv << [r[:pair_no], r[:maeku], r[:tsukeku], r[:trial], s&.[]("season_gap"), s&.[]("material_gap"), s&.[]("scene_gap"),
              r[:parse_ok], r[:raw], r[:retried]]
    end
  end
end

def build_summary(rows, verses)
  bui = CSV.read(BUI_PATH, headers: true).to_h { |r| [r["pair_no"].to_i, r] }
  rows.group_by { |r| r[:pair_no] }.sort.map do |pair_no, trs|
    b = bui.fetch(pair_no) { raise "bui距離レポートにpair_no #{pair_no} がありません" }
    raise "pair_no #{pair_no} の本文がbui距離レポートと一致しません" unless b["maeku_text"] == trs.first[:maeku] && b["tsugeku_text"] == trs.first[:tsukeku]
    ok = trs.select { |r| r[:parse_ok] }
    stats = AXES.to_h do |a|
      vals = ok.map { |r| r[:scores][a] }
      [a, vals.empty? ? { med: nil, min: nil, max: nil } : { med: median(vals), min: vals.min, max: vals.max }]
    end
    unstable = stats.values.any? { |s| s[:max] && s[:max] - s[:min] >= 2 }
    { pair_no: pair_no, ori: b["ori"], men: b["men"], maeku: trs.first[:maeku], tsukeku: trs.first[:tsukeku],
      n_ok: ok.size, stats: stats, bui_distance: b["bui_distance"].to_f, unstable: unstable }
  end
end

def write_summary(summary)
  comment = "# 依頼書S-0 ペア単位の集計（rawとtmp/minase_bui_distance_report.csvから再生成可能）。中央値・最小・最大はparse成功試行のみ。unstable=いずれかの軸で最大-最小>=2"
  write_csv_with_comments(SUMMARY_PATH, [comment]) do |csv|
    csv << (%w[pair_no ori men maeku tsukeku n_ok] + AXES.flat_map { |a| %W[#{a}_median #{a}_min #{a}_max] } + %w[bui_distance unstable])
    summary.each do |s|
      csv << ([s[:pair_no], s[:ori], s[:men], s[:maeku], s[:tsukeku], s[:n_ok]] +
              AXES.flat_map { |a| [s[:stats][a][:med], s[:stats][a][:min], s[:stats][a][:max]] } + [s[:bui_distance], s[:unstable]])
    end
  end
end

def print_stats(rows, summary)
  ok = rows.select { |r| r[:parse_ok] }
  failed = rows.size - ok.size
  puts "\n## 記述統計（判断・閾値提案はしない）"
  puts "\n### parse失敗"
  puts "試行 #{rows.size} 中 最終失敗 #{failed}（#{format('%.1f', 100.0 * failed / rows.size)}%） / 再試行が発生した試行 #{rows.count { |r| r[:retried] }}"
  puts "\n### 各軸の値の分布（試行単位、parse成功 #{ok.size} 試行。1〜5の度数）"
  puts "| 軸 | 1 | 2 | 3 | 4 | 5 |", "|---|---:|---:|---:|---:|---:|"
  AXES.each { |a| c = ok.map { |r| r[:scores][a] }.tally; puts "| #{a} | #{(1..5).map { |v| c[v] || 0 }.join(' | ')} |" }
  puts "\n### 各軸の3試行中央値の分布（ペア単位、小数は.5刻み）"
  AXES.each { |a| puts "#{a}: #{summary.filter_map { |s| s[:stats][a][:med] }.tally.sort.map { |v, n| "#{v}=#{n}" }.join(' ')}" }
  uns = summary.select { |s| s[:unstable] }
  puts "\n### unstable ペア: #{uns.size} 件"
  uns.each { |s| puts "- pair #{s[:pair_no]}（#{s[:ori]}#{s[:men]}）: " + AXES.map { |a| "#{a} #{s[:stats][a][:min]}〜#{s[:stats][a][:max]}" }.join(' / ') }
  puts "\n### 各軸中央値と bui距離の Spearman 相関（参考値、有効ペア #{summary.count { |s| s[:n_ok] > 0 }}）"
  AXES.each do |a|
    pr = summary.select { |s| s[:stats][a][:med] }
    rho = spearman(pr.map { |s| s[:stats][a][:med] }, pr.map { |s| s[:bui_distance] })
    puts "#{a}: #{rho ? format('%.3f', rho) : 'N/A'}（n=#{pr.size}）"
  end
  puts "\n### n_ok < 3 のペア: " + (summary.select { |s| s[:n_ok] < 3 }.map { |s| "#{s[:pair_no]}(#{s[:n_ok]})" }.join(' ').then { |x| x.empty? ? 'なし' : x })
end

verses = load_verses
pairs  = build_pairs(verses)
puts "model=#{MODEL} temperature=#{TEMPERATURE} num_predict=#{NUM_PREDICT} think=false trials=#{TRIALS} url=#{BASE_URL}"

if TRIAL_MODE
  targets = pairs.select { |p| TRIAL_PAIRS.include?(p[:pair_no]) }
  abort "TRIAL_PAIRS に該当ペアがありません" if targets.empty?
  rows = score_pairs(targets)
  write_raw(TRIAL_PATH, rows)
  ok = rows.count { |r| r[:parse_ok] }
  puts "\n試験: #{rows.size} 試行中 parse成功 #{ok} / 失敗 #{rows.size - ok} → #{TRIAL_PATH}"
else
  write_label_sheet(pairs, verses)
  [RAW_PATH, SUMMARY_PATH].each { |p| rotate_existing(p) }
  t0 = Time.now
  rows = score_pairs(pairs)
  write_raw(RAW_PATH, rows)
  summary = build_summary(rows, verses)
  write_summary(summary)
  puts "完了: #{rows.size} 試行 / #{summary.size} ペア / #{(Time.now - t0).round}秒"
  puts "出力: #{RAW_PATH}\n      #{SUMMARY_PATH}"
  print_stats(rows, summary)
end
