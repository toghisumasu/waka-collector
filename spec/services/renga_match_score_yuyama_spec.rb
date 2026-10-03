require "rails_helper"
require "csv"

RSpec.describe RengaMatchScore, "湯山三吟" do
  BUI_MAP_YY = {
    "木" => "植物", "草" => "植物", "竹" => "植物", "◎" => "植物",
    "鳥" => "動物", "獣" => "動物", "虫" => "動物", "魚" => "動物",
    "降" => "降物", "聳" => "聳物", "光" => "光物", "水" => "水辺", "居" => "居所",
    "恋" => "恋", "述" => "述懐", "旅" => "旅", "釈" => "釈教", "神" => "神祇",
    "人" => "人倫", "名" => "名所", "山" => "山類", "衣" => "衣裳",
    "夜" => "夜分", "朝" => "朝時分", "夕" => "夕時分", "風" => "風体", "聞" => "聞え気味"
  }.freeze
  PLANT_YY   = { "木" => "tree", "草" => "grass" }.freeze
  SEASONS_YY = %w[春 夏 秋 冬].freeze

  let(:verses) do
    path = File.expand_path("../../db/data/renga/yuyama_sangin_verses.csv", __dir__)
    CSV.read(path, headers: true, encoding: "bom|utf-8").map do |r|
      tk = r["kyoken_tokens"].to_s.split
      pt = (tk & PLANT_YY.keys).first
      { text: r["text"], bui: tk.filter_map { |x| BUI_MAP_YY[x] }.uniq,
        season: (tk & SEASONS_YY).first, plant_type: pt && PLANT_YY[pt],
        match_bui: r["bui_list"].delete("{}").split(",") }
    end
  end
  let(:checker) do
    ShikimokuChecker.new(
      rules_path:  File.expand_path("../../app/data/kuzari_rules_seta2016.yml", __dir__),
      kukazo_path: File.expand_path("../../app/data/kukazo_rules_seta2016.yml", __dir__),
      ichiza_words: [], nanaku_words: [], interval_offset: 1
    )
  end

  it "99組の一致率が出る" do
    expect(described_class.score_chain(verses).size).to eq 99
  end

  it "違反を渡すと、66句と82句の付合だけが20%未満になる" do
    scores = described_class.score_chain(verses, checker: checker)
    low = scores.each_with_index.select { |s, _| s < 20 }.map { |_, k| k + 2 }
    expect(low).to contain_exactly(66, 82)
  end

  it "違反なしなら、全付合が20%以上" do
    expect(described_class.score_chain(verses).min).to be >= 20.0
  end
end
