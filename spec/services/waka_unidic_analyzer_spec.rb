# frozen_string_literal: true
require "rails_helper"

RSpec.describe WakaUnidicAnalyzer do
  before do
    skip "WAKA_UNIDIC_DICDIR is not set" unless ENV["WAKA_UNIDIC_DICDIR"].present?
  end

  subject(:analyzer) { described_class.new }

  describe ".available?" do
    it "reflects whether WAKA_UNIDIC_DICDIR is set" do
      expect(described_class.available?).to be true
    end
  end

  describe "#analyze" do
    it "既知語「紅葉」でlemma/pronがいずれも非nilで取得できる" do
      morphemes = analyzer.analyze("紅葉")
      expect(morphemes).not_to be_empty
      morphemes.each do |m|
        expect(m.lemma).not_to be_nil
        expect(m.pron).not_to be_nil
      end
      expect(morphemes.first.lemma).to eq("紅葉")
      expect(morphemes.first.pron).to eq("モミジ")
    end

    it "活用語ではlForm(終止形の読み)とpron(実際の発音)が異なりうる" do
      morphemes = analyzer.analyze("読んで")
      yomi_node = morphemes.find { |m| m.lemma == "読む" }
      expect(yomi_node).not_to be_nil
      expect(yomi_node.lform).to eq("ヨム")
      expect(yomi_node.pron).to eq("ヨミ")
    end

    it "「逢ふ」が1形態素として認識される" do
      morphemes = analyzer.analyze("逢ふ")
      expect(morphemes.length).to eq(1)
      expect(morphemes.first.lemma).to eq("会う")
    end

    it "空文字列・nilは空配列を返す" do
      expect(analyzer.analyze("")).to eq([])
      expect(analyzer.analyze(nil)).to eq([])
    end
  end

  describe "列数の防御" do
    it "想定外の素性列数を与えると明示的な例外を送出する" do
      node = double("MeCabNode", is_eos?: false, surface: "テスト", feature: "a,b,c")
      allow(analyzer.instance_variable_get(:@mecab)).to receive(:parse).and_yield(node)

      expect { analyzer.analyze("テスト") }.to raise_error(WakaUnidicAnalyzer::UnsupportedFeatureFormatError)
    end
  end

  describe "素性列のCSVパース修正（Phase 0 D-XX 其の七十）" do
    # アクセント型欄等がカンマを含む引用符付きCSVフィールドになっている単語。
    # 修正前は node.feature.split(",") で列数が29→30/31にずれ、例外が発生していた。
    [
      ["面影", "面影"],
      ["て", "手"],
      ["しのぶ", "偲ぶ"],
      ["人目", "人目"],
      ["きぬぎぬ", "後朝"],
    ].each do |surface, expected_lemma|
      it "「#{surface}」を例外なく解析でき、lemmaが「#{expected_lemma}」になる" do
        morphemes = analyzer.analyze(surface)
        expect(morphemes.length).to eq(1)
        expect(morphemes.first.lemma).to eq(expected_lemma)
      end
    end

    it "35句「おもふなよわすれむもこそこころなれ」を例外なく解析できる" do
      expect { analyzer.analyze("おもふなよわすれむもこそこころなれ") }.not_to raise_error
    end

    it "96句「しぬるくすりはこひにえまほし」で「こひ」が1トークン・lemma=恋として取得できる" do
      morphemes = analyzer.analyze("しぬるくすりはこひにえまほし")
      koi = morphemes.find { |m| m.surface == "こひ" }
      expect(koi).not_to be_nil
      expect(koi.lemma).to eq("恋")
    end
  end

  describe ".instance" do
    it "WAKA_UNIDIC_DICDIRが設定されていればインスタンスを返す" do
      expect(described_class.instance).to be_a(described_class)
    end
  end
end

RSpec.describe WakaUnidicAnalyzer do
  describe ".available? / .instance" do
    around do |example|
      original = ENV["WAKA_UNIDIC_DICDIR"]
      ENV["WAKA_UNIDIC_DICDIR"] = nil
      example.run
      ENV["WAKA_UNIDIC_DICDIR"] = original
    end

    it "未設定時はavailable?がfalseでinstanceがnilになる（既存機能への影響なし）" do
      expect(described_class.available?).to be false
      expect(described_class.instance).to be_nil
    end
  end

  describe "#initialize" do
    it "WAKA_UNIDIC_DICDIR未設定でnewするとUnavailableErrorを送出する" do
      original = ENV["WAKA_UNIDIC_DICDIR"]
      ENV["WAKA_UNIDIC_DICDIR"] = nil
      expect { described_class.new }.to raise_error(WakaUnidicAnalyzer::UnavailableError)
    ensure
      ENV["WAKA_UNIDIC_DICDIR"] = original
    end
  end
end
