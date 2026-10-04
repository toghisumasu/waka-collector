nm = begin
  Natto::MeCab.new(userdic: RengaGenerator::USER_DIC)
rescue StandardError
  Natto::MeCab.new
end
dict = BuiDictionary.new
rows = Renga.where.not(tsugeku: nil).pluck(:id, :previous_renga_id, :maeku, :tsugeku)
by_id = {}
rows.each { |id, prev, m, t| by_id[id] = { prev: prev, maeku: m, tsugeku: t } }
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
ck = ShikimokuChecker.new(rules_path: "app/data/kuzari_rules.yml", kukazo_path: "app/data/kukazo_rules.yml")
cat = ->(v) { v[:bui] || v[:type] }
n = 0; hit = 0; futai = 0
cats = Hash.new(0)
by_id.each do |_id, r|
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
    d = last - 2 - i
    analyze.(t).merge(verse_type: d.even? ? :chouku : :tanku)
  end
  chain[-1][:verse_type] = :tanku
  vs = ck.scan_chain(chain).select { |v| v[:pos] == last }
  n += 1
  hit += 1 unless vs.empty?
  vs.map(&cat).uniq.each { |c| cats[c] += 1 }
  futai += 1 if Array(chain[-1][:bui]).include?("風体")
end
puts "chains=#{n} violations=#{hit} (#{(100.0 * hit / n).round(2)}%)"
puts "by_category: " + cats.sort_by { |_, v| -v }.map { |k, v| "#{k}=#{v}" }.join(" ")
puts "last_verse_with_futai=#{futai}"
