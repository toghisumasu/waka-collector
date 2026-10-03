require "rails_helper"

RSpec.describe RengaMatchScore do
  def v(text, bui, season = nil) = { text: text, bui: bui, season: season }

  it "類似度0は20%(最も遠い付合)" do
    expect(described_class.call(v("あいう", %w[水辺]), v("かきく", %w[恋]))).to eq 20.0
  end

  it "類似度0.5は80%" do
    expect(described_class.call(v("あいう", %w[水辺 恋]), v("かきく", %w[水辺]))).to eq 80.0
  end

  it "集合が完全一致でも本文が違えば90%(100%にならない)" do
    expect(described_class.call(v("あいう", %w[水辺], "春"), v("かきく", %w[水辺], "春"))).to eq 90.0
  end

  it "1要素どうしが同じ部立でも、割り引いて80%(上限90%には届かない)" do
    expect(described_class.call(v("あいう", %w[聳物]), v("かきく", %w[聳物]))).to eq 80.0
  end

  it "本文がほぼ同じ(オウム返し)なら100%" do
    expect(described_class.call(v("春の夜の月", %w[光物]), v("春の夜の月", %w[光物]))).to eq 100.0
  end

  it "本文が空なら0%" do
    expect(described_class.call(v("", %w[水辺]), v("かきく", %w[水辺]))).to eq 0.0
  end

  it "両方とも部立なしは20%" do
    expect(described_class.call(v("あいう", []), v("かきく", []))).to eq 20.0
  end

  it "類似度が上がるほど単調に大きい" do
    xs = [0, 0.2, 0.5, 0.7, 1.0].map { |r| described_class.score(r) }
    expect(xs).to eq xs.sort
  end

  describe "式目違反" do
    let(:a) { v("あいう", %w[水辺 恋]) }
    let(:b) { v("かきく", %w[水辺]) }

    it "違反1件で19%以下になる" do
      expect(described_class.call(a, b, violations: 1)).to be <= 19.0
    end

    it "違反が増えるほど低く、0を下回らない" do
      s1 = described_class.call(a, b, violations: 1)
      s2 = described_class.call(a, b, violations: 2)
      s9 = described_class.call(a, b, violations: 9)
      expect(s1).to be > s2
      expect(s2).to be > s9
      expect(s9).to eq 0.0
    end

    it "オウム返しでも違反があれば19%以下" do
      echo = v("春の夜の月", %w[光物])
      expect(described_class.call(echo, echo, violations: 1)).to be <= 19.0
    end
  end
end
