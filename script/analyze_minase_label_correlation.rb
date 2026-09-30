# frozen_string_literal: true
# S-2 / S-2a: 手ラベル（近=1・中=2・遠=3）と、各系列（qwen3:8b の各版・bui距離・--extra 追加系列）との順位相関。
# 読み取り専用・標準出力のみ・LLM は呼ばない。解釈・閾値提案・系列の採否判断はしない。
#
# 実行: ruby script/analyze_minase_label_correlation.rb [--extra NAME=PATH ...]
# 入力: tmp/minase_label_sheet.csv（30ペア）、tmp/minase_qwen8b_score_raw.csv（S-0）、
#       tmp/minase_qwen8b_split_raw.csv（S-0b）、tmp/minase_qwen8b_split_reason_raw.csv（S-0c）、
#       tmp/minase_bui_distance_report.csv（参考: bui距離）、docs/minase_sangin_hyakuin.md（季欄）
# --extra の CSV は pair_no,value（ペア単位の連続値1つ）。# 始まりの行は読み飛ばす。
# 連続値 = ペア×軸ごとの、parse成功試行（最大3）の平均。「3軸平均」は3軸の平均値の平均。
# 全系列の値は round(9) に揃える（同順位の扱いを rank・Kendall・種類数で一致させるため）。

require "csv"

ROOT      = File.expand_path("..", __dir__)
LABELS    = { "近" => 1, "中" => 2, "遠" => 3 }.freeze
AXES      = %w[season_gap material_gap scene_gap].freeze
PERM_N    = 10_000
PERM_SEED = 20_260_930
NOTE = "30ペアは折面・季移りで層別抽出したもので、無作為抽出ではない。この30ペアでの一致度であり、母集団の相関ではない。系列が多いので、補正前の p 値だけで判断しない。"

def read_csv(name) = CSV.read(File.join(ROOT, "tmp", name), headers: true, skip_lines: /\A#/)

def rank(values)
  sorted = values.each_with_index.sort_by { |v, _| v }
  ranks = Array.new(values.size)
  i = 0
  while i < sorted.size
    j = i
    j += 1 while j + 1 < sorted.size && sorted[j + 1][0] == sorted[i][0]
    (i..j).each { |k| ranks[sorted[k][1]] = (i + j) / 2.0 + 1 }
    i = j + 1
  end
  ranks
end

def pearson(xs, ys)
  mx, my = xs.sum / xs.size, ys.sum / ys.size
  den = Math.sqrt(xs.sum { |a| (a - mx)**2 } * ys.sum { |b| (b - my)**2 })
  den.zero? ? nil : xs.zip(ys).sum { |a, b| (a - mx) * (b - my) } / den
end

def spearman(xs, ys) = pearson(rank(xs), rank(ys))

def kendall_tau_b(xs, ys)
  n = xs.size
  c = d = tx = ty = 0
  (0...n).each do |i|
    ((i + 1)...n).each do |j|
      dx = xs[i] <=> xs[j]
      dy = ys[i] <=> ys[j]
      if dx.zero? && dy.zero? then next
      elsif dx.zero? then tx += 1
      elsif dy.zero? then ty += 1
      elsif dx == dy then c += 1
      else d += 1
      end
    end
  end
  den = Math.sqrt((c + d + tx).to_f * (c + d + ty))
  den.zero? ? nil : (c - d) / den
end

def f(v, d = 3) = v.nil? ? "N/A" : format("%.#{d}f", v)
def mean(a) = a.sum.to_f / a.size
def mean_or_na(a) = a.empty? ? nil : mean(a)

# ---- 原表（季欄）----
def load_seasons
  seasons = {}
  File.foreach(File.join(ROOT, "docs", "minase_sangin_hyakuin.md")) do |line|
    next unless line.start_with?("|")
    cols = line.split("|").map(&:strip)
    next if cols[1].nil? || cols[1] =~ /\A句番\z|\A-+\z/
    no = cols[1].to_i
    seasons[no] = cols[5].to_s if no.between?(1, 100) && cols[4] && !cols[4].empty?
  end
  abort "水無瀬三吟100句が読み込めません（#{seasons.size}句）" unless seasons.size == 100
  seasons
end

def season_class(s) = %w[春 夏 秋 冬].include?(s) ? s : "無季"

# ---- 引数 ----
extra_specs = []
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when "--extra" then extra_specs << (args.shift || abort("--extra には NAME=PATH が必要"))
  when /\A--extra=(.+)\z/ then extra_specs << Regexp.last_match(1)
  else abort "不明な引数: #{a}"
  end
end

sheet = read_csv("minase_label_sheet.csv")
label_by_pair = sheet.to_h { |r| [r["pair_no"].to_i, LABELS.fetch(r["label"]) { abort "label が近/中/遠以外または空欄: pair #{r['pair_no']}" }] }
pairs = label_by_pair.keys.sort
abort "30ペアでない: #{pairs.size}" unless pairs.size == 30
seasons = load_seasons

# trials[version][axis][pair_no] = [試行値...]
trials = { "S-0" => {}, "S-0b" => {}, "S-0c" => {} }
AXES.each { |a| trials.each_value { |h| h[a] = Hash.new { |hh, k| hh[k] = [] } } }
read_csv("minase_qwen8b_score_raw.csv").each do |r|
  next unless r["parse_ok"] == "true"
  AXES.each { |a| trials["S-0"][a][r["pair_no"].to_i] << r[a].to_i }
end
{ "S-0b" => "minase_qwen8b_split_raw.csv", "S-0c" => "minase_qwen8b_split_reason_raw.csv" }.each do |ver, file|
  read_csv(file).each { |r| trials[ver][r["axis"]][r["pair_no"].to_i] << r["gap"].to_i if r["parse_ok"] == "true" }
end
bui = read_csv("minase_bui_distance_report.csv").to_h { |r| [r["pair_no"].to_i, r["bui_distance"].to_f] }

# series: {name:, vals: {pair_no => round(9)された連続値}, tv: {pair_no => 試行値配列} or nil, kind: :model | :extra | :ref}
series = []
trials.each do |ver, by_axis|
  AXES.each do |a|
    series << { name: "#{ver} #{a}", kind: :model, tv: pairs.to_h { |p| [p, by_axis[a][p]] },
                vals: pairs.to_h { |p| [p, mean(by_axis[a][p]).round(9)] } }
  end
  series << { name: "#{ver} 3軸平均", kind: :model, tv: pairs.to_h { |p| [p, AXES.flat_map { |a| by_axis[a][p] }] },
              vals: pairs.to_h { |p| [p, mean(AXES.map { |a| mean(by_axis[a][p]) }).round(9)] } }
end

def load_extra(spec, pairs)
  name, path = spec.split("=", 2)
  abort "--extra は NAME=PATH の形式: #{spec}" if name.to_s.empty? || path.to_s.empty?
  abort "--extra のファイルが無い: #{path}" unless File.file?(path)
  rows = CSV.read(path, headers: true, skip_lines: /\A#/)
  abort "--extra #{name}: 列 pair_no,value が必要: #{path}" unless (rows.headers & %w[pair_no value]).size == 2
  vals = {}
  rows.each do |r|
    pn = Integer(r["pair_no"].to_s.strip, exception: false) || abort("--extra #{name}: pair_no が整数でない: #{r['pair_no'].inspect}")
    next unless pairs.include?(pn)
    abort "--extra #{name}: pair_no #{pn} が重複" if vals.key?(pn)
    v = Float(r["value"].to_s.strip, exception: false) || abort("--extra #{name}: pair #{pn} の value が数値でない: #{r['value'].inspect}")
    vals[pn] = v.round(9)
  end
  missing = pairs - vals.keys
  abort "--extra #{name}: 30ペアのうち欠けている pair_no: #{missing.join(',')}" unless missing.empty?
  { name: name, kind: :extra, tv: nil, vals: vals }
end
extra_specs.each do |spec|
  s = load_extra(spec, pairs)
  abort "--extra の NAME が既存系列と重複: #{s[:name]}" if series.any? { |x| x[:name] == s[:name] } || (s[:name] == "bui距離（参考）")
  series << s
end
series << { name: "bui距離（参考）", kind: :ref, tv: nil, vals: pairs.to_h { |p| [p, bui.fetch(p).round(9)] } }

# ---- 恋→恋（前句・付句の季欄がともに「恋」）と季移り（春夏秋冬・無季[雑・恋]の区分が異なる）----
koi_koi = pairs.select { |p| seasons[p] == "恋" && seasons[p + 1] == "恋" }
shift_of = pairs.to_h { |p| [p, season_class(seasons[p]) != season_class(seasons[p + 1])] }
versions = [["A. 全30ペア", pairs], ["B. 恋→恋を除く", pairs - koi_koi]]

def label_counts(ps, label_by_pair) = (1..3).map { |l| ps.count { |p| label_by_pair[p] == l } }

def analyze(ps, label_by_pair, series)
  ry = rank(ps.map { |p| label_by_pair[p].to_f })
  ys = ps.map { |p| label_by_pair[p].to_f }
  rows = series.map do |s|
    xs = ps.map { |p| s[:vals][p] }
    t = xs.tally
    rx = rank(xs)
    { s: s, xs: xs, rx: rx, rho: pearson(rx, ry)&.round(9), tau: kendall_tau_b(xs, ys), kinds: t.size, maxtie: t.values.max, cnt: 0, ccnt: 0 }
  end
  elig  = rows.select { |r| r[:rho] }
  cset  = elig.select { |r| r[:s][:kind] != :ref }
  rng   = Random.new(PERM_SEED)
  PERM_N.times do
    yp = ry.shuffle(random: rng) # ラベルの並べ替え（順位ベクトルの並べ替えと同値）
    mx = 0.0
    elig.each do |r|
      v = pearson(r[:rx], yp).abs.round(9)
      r[:cnt] += 1 if v >= r[:rho].abs
      mx = v if r[:s][:kind] != :ref && v > mx
    end
    cset.each { |r| r[:ccnt] += 1 if mx >= r[:rho].abs }
  end
  rows.each do |r|
    next unless r[:rho]
    r[:p] = (1 + r[:cnt]).to_f / (PERM_N + 1)
    r[:p_corr] = r[:s][:kind] == :ref ? nil : (1 + r[:ccnt]).to_f / (PERM_N + 1)
  end
  [rows, cset.map { |r| r[:s][:name] }, rows.select { |r| r[:rho].nil? && r[:s][:kind] != :ref }.map { |r| r[:s][:name] }]
end

# ---- 出力 ----
puts "## S-2a 手ラベル（近=1・中=2・遠=3）と各系列の順位相関（解釈・閾値提案はしない）"
puts "> #{NOTE}"
puts
puts "- 系列の値は round(9)。順位相関は Spearman（同順位は平均順位）と Kendall τ-b。p 値は Spearman のみ"
puts "- 置換検定: 回数=#{PERM_N} / 乱数=Random.new(#{PERM_SEED}) / 手ラベルのみを並べ替え（同じ並べ替えを全系列に適用）/ 版ごとに乱数を作り直す"
puts "- 両側 p = (1 + #{'{'}|ρ_perm| ≥ |ρ_obs|#{'}'}の個数) / (#{PERM_N} + 1)。p 値の下限 = 1/#{PERM_N + 1} = #{format('%.10f', 1.0 / (PERM_N + 1))}"
puts "- 補正済み p = (1 + #{'{'}max|ρ_perm| ≥ |ρ_obs|#{'}'}の個数) / (#{PERM_N} + 1)。max は補正集合の系列の中での最大。ρ は round(9) して比較"
puts "- 補正集合: 相関が計算できる 8b 系列（N/A でないもの）と --extra 系列。版ごとに決まる（各版の表の前に明記）。bui距離は参考系列で補正対象外（補正前 p のみ）"
puts "- --extra: " + (extra_specs.empty? ? "なし" : extra_specs.join(", "))
puts "- ラベル分布: " + LABELS.map { |k, v| "#{k}(#{v})=#{label_by_pair.values.count(v)}" }.join(" ")

puts "\n### 0. 恋→恋のペア（原表の季欄で前句・付句がともに恋）: #{koi_koi.size}件"
puts "| pair_no | 前句の季欄 | 付句の季欄 | 手ラベル |", "|---:|:---:|:---:|:---:|"
koi_koi.each { |p| puts "| #{p} | #{seasons[p]} | #{seasons[p + 1]} | #{LABELS.key(label_by_pair[p])} |" }
puts "（参考: 片側だけ恋のペアは除外しない: " + pairs.select { |p| [seasons[p], seasons[p + 1]].count("恋") == 1 }.map { |p| "#{p}(#{seasons[p]}→#{seasons[p + 1]})" }.join(" ") + "）"

analyzed = {}
versions.each do |title, ps|
  rows, cset_names, na_names = analyze(ps, label_by_pair, series)
  analyzed[title] = rows
  c = label_counts(ps, label_by_pair)
  puts "\n### 1. 順位相関と置換検定 〔#{title}: n=#{ps.size} / 近#{c[0]}・中#{c[1]}・遠#{c[2]}〕"
  puts "補正集合（#{cset_names.size}系列）: #{cset_names.join(' / ')}"
  puts "N/A（全ペア同値で相関が計算できず、補正集合から除外）: #{na_names.empty? ? 'なし' : na_names.join(' / ')}"
  puts "| 系列 | Spearman | Kendall τ-b | 値の種類数 | 最大の同順位グループ | p（補正前・両側） | p（補正済み） |", "|---|---:|---:|---:|---:|---:|---:|"
  rows.each do |r|
    pc = r[:s][:kind] == :ref ? "—（参考）" : f(r[:p_corr], 4)
    puts "| #{r[:s][:name]} | #{f(r[:rho])} | #{f(r[:tau])} | #{r[:kinds]} | #{r[:maxtie]} | #{f(r[:p], 4)} | #{pc} |"
  end

  puts "\n### 2. 手ラベル別の平均（ペア単位の連続値の平均。bui距離は距離の平均）〔#{title}〕"
  puts "| 系列 | 近(n=#{c[0]}) | 中(n=#{c[1]}) | 遠(n=#{c[2]}) |", "|---|---:|---:|---:|"
  series.each do |s|
    puts "| #{s[:name]} | " + (1..3).map { |l| f(mean_or_na(ps.select { |p| label_by_pair[p] == l }.map { |p| s[:vals][p] }), 2) }.join(" | ") + " |"
  end
end

puts "\n### 3. 手ラベル別の値の分布（試行単位の値の度数 1/2/3/4/5。3軸平均は3軸の全試行を合算）〔A. 全30ペア〕"
puts "| 系列 | 近 | 中 | 遠 |", "|---|---|---|---|"
series.each do |s|
  if s[:tv]
    cells = (1..3).map do |l|
      vs = pairs.select { |p| label_by_pair[p] == l }.flat_map { |p| s[:tv][p] }
      (1..5).map { |v| vs.count(v) }.join("/") + " (#{vs.size})"
    end
    puts "| #{s[:name]} | #{cells.join(' | ')} |"
  else
    puts "| #{s[:name]} | —（試行値なし） | —（試行値なし） | —（試行値なし） |"
  end
end

puts "\n### 4. 季移りの有無 × 手ラベル（30ペア。季移り = 春夏秋冬・無季[雑・恋]の区分が前句と付句で異なる。雑↔恋は季移りでない）"
puts "| | 近 | 中 | 遠 | 計 |", "|---|---:|---:|---:|---:|"
[[true, "季移りあり"], [false, "季移りなし"]].each do |flag, name|
  ps = pairs.select { |p| shift_of[p] == flag }
  c = label_counts(ps, label_by_pair)
  puts "| #{name} | #{c.join(' | ')} | #{ps.size} |"
end
c = label_counts(pairs, label_by_pair)
puts "| 計 | #{c.join(' | ')} | #{pairs.size} |"
