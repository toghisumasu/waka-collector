nm = begin
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end
dict = BuiDictionary.new

rows = Renga.where.not(tsugeku: nil).pluck(:id, :previous_renga_id, :maeku, :tsugeku, :style_check_result)
by_id = {}
rows.each { |id, prev, m, t, sc| by_id[id] = { prev: prev, maeku: m, tsugeku: t, result: sc && sc["result"] } }

season_of = lambda do |text|
  key = RengaGenerator::SEASON_WORDS.find { |_, ws| ws.any? { |w| w != "しも" && text.include?(w) } }&.first
  key ? RengaGenerator::SEASON_JP[key] : nil
end
cache = {}
analyze = lambda do |text|
  cache[text] ||= begin
    word = dict.detect_word(text, nm)
    { bui: dict.detect_all(text, nm), season: season_of.(text), word: word,
      text: text, plant_type: dict.plant_type(word) }
  end
end

old = ShikimokuChecker.new(rules_path: "tmp/old_kuzari_rules.yml", kukazo_path: "tmp/old_kukazo_rules.yml")
new = ShikimokuChecker.new(rules_path: "app/data/kuzari_rules.yml", kukazo_path: "app/data/kukazo_rules.yml")
cat = ->(v) { v[:bui] || v[:type] }

n = 0; old_hit = 0; new_hit = 0; newly = 0
newcats = Hash.new(0)
by_result = Hash.new { |h, k| h[k] = { n: 0, newly: 0 } }
examples = []

by_id.each do |id, r|
  ids = []
  cur = r[:prev]
  while cur && by_id[cur] && ids.size < 9
    ids.unshift(cur)
    cur = by_id[cur][:prev]
  end
  texts = ids.empty? ? [r[:maeku].to_s] : ids.map { |i| by_id[i][:tsugeku].to_s }
  texts << r[:tsugeku].to_s
  next if texts.any?(&:empty?)
  last = texts.size
  chain = texts.each_with_index.map do |t, i|
    d = last - 2 - i                       # 前句(末尾の1つ前)からの距離
    analyze.(t).merge(verse_type: d.even? ? :chouku : :tanku)
  end
  chain[-1][:verse_type] = :tanku
  vo = old.scan_chain(chain).select { |v| v[:pos] == last }
  vn = new.scan_chain(chain).select { |v| v[:pos] == last }
  n += 1
  old_hit += 1 unless vo.empty?
  new_hit += 1 unless vn.empty?
  added = vn.map(&cat).uniq - vo.map(&cat).uniq
  by_result[r[:result].to_s][:n] += 1
  unless added.empty?
    newly += 1
    by_result[r[:result].to_s][:newly] += 1
    added.each { |c| newcats[c] += 1 }
    examples << [id, texts[-2], texts[-1], added] if examples.size < 8
  end
end

pct = ->(a, b) { format("%.1f%%", 100.0 * a / b) }
puts "評価した付合: #{n}組"
puts "旧ルールで違反: #{old_hit}組(#{pct.(old_hit, n)})"
puts "新ルールで違反: #{new_hit}組(#{pct.(new_hit, n)})"
puts "新ルールで新たに加わった違反: #{newly}組(#{pct.(newly, n)})"
puts "--- 新たに加わった違反の種類 ---"
newcats.sort_by { |_, c| -c }.each { |c, k| puts format("  %-10s %4d", c, k) }
puts "--- 記録された result 別の「新たに違反」---"
by_result.sort_by { |_, v| -v[:n] }.each { |res, v| puts format("  %-22s %4d組中 %4d (%s)", res, v[:n], v[:newly], pct.(v[:newly], v[:n])) }
puts "--- 例 ---"
examples.each { |id, a, b, c| puts "#{id}  #{a}\n     → #{b}   [#{c.join(',')}]" }
