# 使い方: ruby script/scan_renga_csv.rb db/data/renga/minase_sangin_verses.csv
require "csv"
require_relative "../app/services/shikimoku_checker"

BUI_MAP = {
  "木"=>"植物","草"=>"植物","竹"=>"植物","◎"=>"植物",
  "鳥"=>"動物","獣"=>"動物","虫"=>"動物","魚"=>"動物",
  "降"=>"降物","聳"=>"聳物","光"=>"光物","水"=>"水辺","居"=>"居所",
  "恋"=>"恋","述"=>"述懐","旅"=>"旅","釈"=>"釈教","神"=>"神祇",
  "人"=>"人倫","名"=>"名所","山"=>"山類","衣"=>"衣裳",
  "夜"=>"夜分","朝"=>"朝時分","夕"=>"夕時分","風"=>"風体","聞"=>"聞え気味"
}.freeze
PLANT = { "木"=>"tree", "草"=>"grass" }.freeze
SEASONS = %w[春 夏 秋 冬].freeze

rows = CSV.read(ARGV[0], headers: true, encoding: "bom|utf-8")
chain = rows.map do |r|
  tk = r["kyoken_tokens"].to_s.split
  pt = (tk & PLANT.keys).first
  { bui: tk.filter_map { |x| BUI_MAP[x] }.uniq, season: (tk & SEASONS).first,
    plant_type: pt && PLANT[pt] }
end
puts "#{chain.size}句"

[0, 1].each do |off|
  ck = ShikimokuChecker.new(
    rules_path: "app/data/kuzari_rules_seta2016.yml", kukazo_path: "app/data/kukazo_rules_seta2016.yml",
    ichiza_words: [], nanaku_words: [], interval_offset: off
  )
  found = ck.scan_chain(chain).map { |v| [v[:pos], v[:bui] || v[:type]] }
  puts "interval_offset=#{off}: #{found.size}件"
  found.each { |pos, k| puts "  #{pos}句 #{k}  #{rows[pos - 1]['text']}" }
end
