# 其の六十二: 4作品（水無瀬三吟・湯山三吟・遺誡百韻・住吉夢想百韻）横断で
# 恋・旅・述懐の出現ブロック（開始句番・連続句数・間隔）を機械抽出する。
#
# 恋・旅・述列の判定は「セルが値と完全一致する場合のみ真」とする
# （其の六十二 Phase 0 追加3で判明：非空判定だと第52号凡例の「×」＝対象外を
# 恋として誤カウントする事故が起きたため）。

require "csv"

def blocks_from_flags(flags) # flags: {verse_no(Integer) => true} for verses where category present
  present = flags.keys.sort
  blocks = []
  present.each do |v|
    if blocks.last && blocks.last[:end] == v - 1
      blocks.last[:end] = v
    else
      blocks << { start: v, end: v }
    end
  end
  blocks.each { |b| b[:len] = b[:end] - b[:start] + 1 }
  blocks
end

def blocks_with_gap(blocks)
  blocks.each_with_index.map do |b, i|
    gap = i.zero? ? "初出" : (b[:start] - blocks[i - 1][:end] - 1).to_s
    { 開始句番: b[:start], 連続句数: b[:len], 間隔: gap }
  end
end

def csv_flags(path, col)
  rows = CSV.read(path, headers: true)
  flags = {}
  rows.each do |r|
    n = r["番号"]
    verse_no = (n == "00") ? 100 : n.to_i
    flags[verse_no] = true if r[col] && r[col].strip == col
  end
  flags
end

# 水無瀬三吟（連衆吟）: script/verify_shikimoku.rb の minase_full 配列（bui配列にタグ付け済み）
verify_src = File.read(File.expand_path("verify_shikimoku.rb", __dir__))
minase_src = verify_src[/^minase_full\s*=\s*\[.*?^\]/m]
minase_entries = eval(minase_src.sub(/^minase_full\s*=\s*/, ""))

def minase_flags(entries, tag)
  flags = {}
  entries.each_with_index do |e, i|
    flags[i + 1] = true if Array(e[:bui]).include?(tag)
  end
  flags
end

data_dir = File.expand_path("../docs/reference", __dir__)

works = {
  "水無瀬三吟"   => { type: "連衆吟", 恋: minase_flags(minase_entries, "恋"), 旅: minase_flags(minase_entries, "旅"), 述: minase_flags(minase_entries, "述懐") },
  "湯山三吟"     => { type: "連衆吟",
                       恋: csv_flags("#{data_dir}/yuyama_sangin_kokiraisichiran.csv", "恋"),
                       旅: csv_flags("#{data_dir}/yuyama_sangin_kokiraisichiran.csv", "旅"),
                       述: csv_flags("#{data_dir}/yuyama_sangin_kokiraisichiran.csv", "述") },
  "遺誡百韻"     => { type: "独吟",
                       恋: csv_flags("#{data_dir}/yuikai_hyakuin_kokiraisichiran.csv", "恋"),
                       旅: csv_flags("#{data_dir}/yuikai_hyakuin_kokiraisichiran.csv", "旅"),
                       述: csv_flags("#{data_dir}/yuikai_hyakuin_kokiraisichiran.csv", "述") },
  "住吉夢想百韻" => { type: "独吟",
                       恋: csv_flags("#{data_dir}/sumiyoshi_muso_kokiraisichiran.csv", "恋"),
                       旅: csv_flags("#{data_dir}/sumiyoshi_muso_kokiraisichiran.csv", "旅"),
                       述: csv_flags("#{data_dir}/sumiyoshi_muso_kokiraisichiran.csv", "述") },
}

puts "作品,分類,部立,開始句番,連続句数,間隔"
%w[独吟 連衆吟].each do |type|
  works.each do |name, data|
    next unless data[:type] == type
    %i[恋 旅 述].each do |cat|
      rows = blocks_with_gap(blocks_from_flags(data[cat]))
      if rows.empty?
        puts "#{name},#{type},#{cat},(出現なし),,"
      else
        rows.each do |r|
          puts "#{name},#{type},#{cat},#{r[:開始句番]},#{r[:連続句数]},#{r[:間隔]}"
        end
      end
    end
  end
end
