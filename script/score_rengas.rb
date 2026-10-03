require "csv"

nm = begin
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end
dict = BuiDictionary.new
SEASONS = %w[春 夏 秋 冬].freeze

analyze = lambda do |text|
  bui = []
  season = nil
  nm.parse(text.to_s.gsub(/[\s　]+/, "")) do |node|
    next if node.is_eos?
    e = dict.fetch(node.surface)
    next unless e.is_a?(Hash)
    bui << e["primary_bui"] if e["primary_bui"]
    s = e["season"]
    season ||= s if SEASONS.include?(s)
  end
  { text: text.to_s, bui: bui.uniq, season: season }
end

rows = []
season_hits = 0
Renga.where.not(tsugeku: nil).where.not(style_check_result: nil).order(:id).find_each do |r|
  a = analyze.(r.maeku)
  b = analyze.(r.tsugeku)
  season_hits += 1 if a[:season] || b[:season]
  sim = RengaMatchScore.similarity(a, b)
  rows << { id: r.id, batch: r.observation_batch.to_s, result: r.style_check_result["result"].to_s,
            maeku: r.maeku, tsugeku: r.tsugeku, a: a, b: b, sim: sim,
            score: RengaMatchScore.call(a, b) }
end

FileUtils.mkdir_p("tmp")
CSV.open("tmp/rengas_match_scores.csv", "w", encoding: "utf-8") do |csv|
  csv << %w[id batch result maeku tsugeku maeku_bui tsugeku_bui maeku_season tsugeku_season similarity score]
  rows.each do |x|
    csv << [x[:id], x[:batch], x[:result], x[:maeku], x[:tsugeku], x[:a][:bui].join(","), x[:b][:bui].join(","),
            x[:a][:season], x[:b][:season], x[:sim].round(3), x[:score].round(1)]
  end
end

def stats(label, arr)
  return puts("#{label}: なし") if arr.empty?
  s = arr.sort
  q = ->(p) { s[((s.size - 1) * p).round].round(1) }
  at20 = arr.count { |v| v <= 20.0 }
  puts format("%-26s n=%4d  20%%ちょうど=%4.1f%%  中央%5.1f  75%%点%5.1f  90%%点%5.1f  平均%5.1f  80%%以上=%4.1f%%",
              label, arr.size, 100.0 * at20 / arr.size, q.(0.5), q.(0.75), q.(0.9),
              arr.sum / arr.size, 100.0 * arr.count { |v| v >= 80 } / arr.size)
end

puts "季が検出された付合: #{season_hits}/#{rows.size}"
puts "(参考)正調 湯山: 20%ちょうど約43%  中央44  90%点80  平均約44"
stats("全体", rows.map { |x| x[:score] })
rows.group_by { |x| x[:result] }.sort_by { |_, v| -v.size }.each do |res, xs|
  stats("result=#{res}", xs.map { |x| x[:score] })
end
puts "出力: tmp/rengas_match_scores.csv"
