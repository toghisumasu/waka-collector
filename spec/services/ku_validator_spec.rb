# frozen_string_literal: true
require "rails_helper"

RSpec.describe KuValidator do
  describe "#validate" do
    it "正しい17音の句はokになる" do
      result = KuValidator.new("さむざむと時雨は晴れて妙高の").validate
      expect(result[:result]).to eq("ok")
      expect(result[:mora]).to eq(17)
    end

    it "東風(コチ)を含む句が正しく音数判定される" do
      result = KuValidator.new("東風ふかばにほいおこせよ梅の花").validate
      expect(result[:mora]).to be_a(Integer)
      expect(result[:mora]).to be > 0
    end

    it "紅葉(モミジ)を含む句が正しく音数判定される" do
      result = KuValidator.new("紅葉踏み分け鳴く鹿の声").validate
      expect(result[:mora]).to be_a(Integer)
      expect(result[:mora]).to be > 0
    end

    it "字数が極端に少ない場合はngになる" do
      result = KuValidator.new("あ").validate
      expect(result[:result]).to eq("ng")
    end
  end

  describe "#count_mora" do
    it "ユーザー辞書の読みを反映してモーラ数を数える" do
      mora = KuValidator.new("時雨").count_mora
      expect(mora).to eq(3) # シ・グ・レ
    end
  end
end

