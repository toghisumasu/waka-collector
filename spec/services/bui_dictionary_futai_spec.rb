# frozen_string_literal: true

require "yaml"

# 風体(風・嵐・野分・東風)は、辞書では風体、規則(本番)では 5句去・連続1句まで。
# 根拠: 瀬田勝郭「連歌去嫌の総合的再検討」(2016)、湯山三吟・宗祇独吟の去嫌一覧表の「風」列。
RSpec.describe "bui_dictionary の風体" do
  root  = File.expand_path("../..", __dir__)
  dict  = YAML.load_file(File.join(root, "app/data/bui_dictionary.yml"))
  kuzari = YAML.load_file(File.join(root, "app/data/kuzari_rules.yml"))
  kukazo = YAML.load_file(File.join(root, "app/data/kukazo_rules.yml"))

  %w[風 東風 嵐 野分].each do |w|
    it "#{w} は部立が風体" do
      expect(dict.dig(w, "primary_bui")).to eq "風体"
    end
  end

  it "嵐は季なし、野分は秋、東風は春" do
    expect(dict.dig("嵐", "season")).to be_nil
    expect(dict.dig("野分", "season")).to eq "秋"
    expect(dict.dig("東風", "season")).to eq "春"
  end

  it "本番の規則: 風体は5句去、連続は1句まで" do
    expect(kuzari["風体"]).to eq 5
    expect(kukazo.dig("bui", "風体", "max")).to eq 1
  end
end
