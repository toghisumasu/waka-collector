require "rails_helper"
require "natto"

# 依頼書M-3: OverlapGuardの単体テスト。
# 水無瀬三吟99組の実測（script/measure_minase_distance.rb）で得た
# THRESHOLD=0.111（pair37の実測最大重複率）を境界に、閾値超過を
# 正しく判定できることを確認する。
RSpec.describe OverlapGuard do
  let(:nm) { Natto::MeCab.new(userdic: RengaGenerator::USER_DIC) }

  describe "::THRESHOLD" do
    it "水無瀬三吟の実測最大重複率0.111が設定されている" do
      expect(described_class::THRESHOLD).to eq(0.111)
    end
  end

  describe ".overlap_rate" do
    it "内容語を全く共有しない場合は0.0に近い値を返す" do
      rate = described_class.overlap_rate("雪ながら山本かすむ夕べかな", "月の光に遠き人影ゆかし", nm)
      expect(rate).to be < described_class::THRESHOLD
    end

    it "内容語をすべて共有する場合は1.0を返す" do
      rate = described_class.overlap_rate("かすみたつ春の夕暮れ", "かすみたつ春の夕暮れ", nm)
      expect(rate).to eq(1.0)
    end

    it "前句の名詞をそのまま流用した付句は閾値を超える重複率になる" do
      rate = described_class.overlap_rate("かきねをとへばあらはなるみち", "おみちのぞるや重く重くしる重", nm)
      expect(rate).to be > described_class::THRESHOLD
    end
  end

  describe ".partial_echo?" do
    it "重複率が閾値以下ならfalse" do
      expect(described_class.partial_echo?("雪ながら山本かすむ夕べかな", "月の光に遠き人影ゆかし", nm)).to be false
    end

    it "重複率が閾値を超えるとtrue" do
      expect(described_class.partial_echo?("かきねをとへばあらはなるみち", "おみちのぞるや重く重くしる重", nm)).to be true
    end
  end
end
