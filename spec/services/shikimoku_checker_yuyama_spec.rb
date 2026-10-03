# frozen_string_literal: true

require "csv"
require "rails_helper" if File.exist?(File.expand_path("../rails_helper.rb", __dir__))
require_relative "../../app/services/shikimoku_checker"

# 湯山三吟(延徳三年・1491)を「正調の百韻」の回帰テストに使う。
# 出典: 瀬田勝哉「『湯山三吟』の新注解」(奈良高専研究紀要)の去嫌一覧と注解、
#       同「連歌去嫌の総合的再検討」(同52号, 2016)の規則。
# 期待値: 注解が指合と明記している2件のみ検出される。
#   ・64〜66句 植物の3句連続(上限2)
#   ・77句「庵」→82句「いらか」居所の間隔4句(要5)
RSpec.describe ShikimokuChecker, "湯山三吟の回帰テスト" do
  SEASONS = %w[春 夏 秋 冬].freeze
  BUI_MAP = {
    "木" => "植物", "草" => "植物", "竹" => "植物", "◎" => "植物",
    "鳥" => "動物", "獣" => "動物", "虫" => "動物", "魚" => "動物",
    "降" => "降物", "聳" => "聳物", "光" => "光物", "水" => "水辺", "居" => "居所",
    "恋" => "恋", "述" => "述懐", "旅" => "旅", "釈" => "釈教", "神" => "神祇",
    "人" => "人倫", "名" => "名所", "山" => "山類", "衣" => "衣裳",
    "夜" => "夜分", "朝" => "朝時分", "夕" => "夕時分", "風" => "風体", "聞" => "聞え気味"
  }.freeze
  PLANT_TYPE = { "木" => "tree", "草" => "grass" }.freeze

  let(:csv_path) { File.expand_path("../../db/data/renga/yuyama_sangin_verses.csv", __dir__) }
  let(:chain) do
    CSV.read(csv_path, headers: true, encoding: "bom|utf-8").map do |r|
      tk = r["kyoken_tokens"].to_s.split
      pt = (tk & PLANT_TYPE.keys).first
      { bui: tk.filter_map { |x| BUI_MAP[x] }.uniq, season: (tk & SEASONS).first,
        plant_type: pt && PLANT_TYPE[pt] }
    end
  end

  it "100句そろっている" do
    expect(chain.size).to eq 100
  end

  context "規則表(瀬田2016)・間にN句以上(interval_offset: 1)" do
    let(:checker) do
      ShikimokuChecker.new(
        rules_path:  File.expand_path("../../app/data/kuzari_rules_seta2016.yml", __dir__),
        kukazo_path: File.expand_path("../../app/data/kukazo_rules_seta2016.yml", __dir__),
        ichiza_words: [], nanaku_words: [], interval_offset: 1
      )
    end

    it "植物の3句連続(66句目)と居所の間隔不足(82句目)の2件だけが検出される" do
      found = checker.scan_chain(chain).map { |v| [v[:pos], v[:bui] || v[:type]] }
      expect(found).to contain_exactly([66, "植物"], [82, "居所"])
    end
  end
end
