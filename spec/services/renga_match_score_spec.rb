require "rails_helper"

RSpec.describe RengaMatchScore do
  def v(text, bui, season = nil) = { text: text, bui: bui, season: season }

  it "類似度0は20%(最も遠い付合)" do
    expect(described_class.call(v("a", %w[水辺]), v("b", %w[恋]))).to eq 20.0
  end

  it "類似度0.5は80%" do
    expect(described_class.call(v("a", %w[水辺 恋]), v("b", %w[水辺]))).to eq 80.0
  end

  it "完全一致は100%(オウム返し)" do
    expect(described_class.call(v("a", %w[水辺], "春"), v("b", %w[水辺], "春"))).to eq 100.0
  end

  it "本文が空なら0%" do
    expect(described_class.call(v("", %w[水辺]), v("b", %w[水辺]))).to eq 0.0
  end

  it "両方とも部立なしは20%" do
    expect(described_class.call(v("a", []), v("b", []))).to eq 20.0
  end

  it "類似度が上がるほど単調に大きい" do
    xs = [0, 0.2, 0.5, 0.7, 1.0].map { |r| described_class.score(r) }
    expect(xs).to eq xs.sort
  end
end
