require "rails_helper"

RSpec.describe RengaGenerator do
  describe "#levenshtein (private)" do
    subject(:generator) { described_class.new("まえく", [], :tanku) }

    it "同一文字列は距離0" do
      expect(generator.send(:levenshtein, "あいうえお", "あいうえお")).to eq(0)
    end

    it "一文字違いは距離1" do
      expect(generator.send(:levenshtein, "つきのかたむく", "つきのかたぶく")).to eq(1)
    end

    it "全く異なる文字列は文字数相応の距離" do
      expect(generator.send(:levenshtein, "あいう", "かきく")).to eq(3)
    end
  end

  describe "#history_repeat? (private)" do
    it "履歴が空なら常にfalse" do
      generator = described_class.new("まえく", [], :tanku, constraints: { verse_history: [] })
      expect(generator.send(:history_repeat?, "つきのかたむく")).to eq(false)
    end

    it "完全一致（距離0）はtrue" do
      generator = described_class.new(
        "まえく", [], :tanku, constraints: { verse_history: ["つきのかたむく"] }
      )
      expect(generator.send(:history_repeat?, "つきのかたむく")).to eq(true)
    end

    it "類似（閾値以内の距離）はtrue" do
      generator = described_class.new(
        "まえく", [], :tanku, constraints: { verse_history: ["つきのかたむく"] }
      )
      # 距離1、閾値 = max(7文字×0.3をceil=3, 3) = 3 → 閾値内
      expect(generator.send(:history_repeat?, "つきのかたぶく")).to eq(true)
    end

    it "閾値を超える距離はfalse" do
      generator = described_class.new(
        "まえく", [], :tanku, constraints: { verse_history: ["つきのかたむく"] }
      )
      expect(generator.send(:history_repeat?, "はるのよのゆめ")).to eq(false)
    end

    it "複数の履歴のうち最も近い1句で判定する" do
      generator = described_class.new(
        "まえく", [], :tanku,
        constraints: { verse_history: ["はるのよのゆめ", "つきのかたむく"] }
      )
      expect(generator.send(:history_repeat?, "つきのかたぶく")).to eq(true)
    end
  end
end
