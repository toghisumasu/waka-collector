require "rails_helper"

# 其の七十三: RengaGenerator/StepwiseWakaGeneratorの両方が使う純粋なテキスト
# 解析ロジックをVerseTextAnalysisモジュールへ切り出した際に、renga_generator_spec.rb
# から移設したテスト群。モジュール単体の振る舞いとして、どちらのホストクラスにも
# 依存しない軽量なテスト用クラスを介してテストする。
RSpec.describe VerseTextAnalysis do
  let(:host_class) do
    Class.new do
      include VerseTextAnalysis
      def initialize(maeku: "", verse_history: [])
        @maeku         = maeku
        @verse_history = verse_history
      end
    end
  end

  describe "#levenshtein (private)" do
    subject(:host) { host_class.new }

    it "同一文字列は距離0" do
      expect(host.send(:levenshtein, "あいうえお", "あいうえお")).to eq(0)
    end

    it "一文字違いは距離1" do
      expect(host.send(:levenshtein, "つきのかたむく", "つきのかたぶく")).to eq(1)
    end

    it "全く異なる文字列は文字数相応の距離" do
      expect(host.send(:levenshtein, "あいう", "かきく")).to eq(3)
    end
  end

  describe "#history_repeat? (private)" do
    it "履歴が空なら常にfalse" do
      host = host_class.new(verse_history: [])
      expect(host.send(:history_repeat?, "つきのかたむく")).to eq(false)
    end

    it "完全一致（距離0）はtrue" do
      host = host_class.new(verse_history: ["つきのかたむく"])
      expect(host.send(:history_repeat?, "つきのかたむく")).to eq(true)
    end

    it "類似（閾値以内の距離）はtrue" do
      host = host_class.new(verse_history: ["つきのかたむく"])
      # 距離1、閾値 = max(7文字×0.3をceil=3, 3) = 3 → 閾値内
      expect(host.send(:history_repeat?, "つきのかたぶく")).to eq(true)
    end

    it "閾値を超える距離はfalse" do
      host = host_class.new(verse_history: ["つきのかたむく"])
      expect(host.send(:history_repeat?, "はるのよのゆめ")).to eq(false)
    end

    it "複数の履歴のうち最も近い1句で判定する" do
      host = host_class.new(verse_history: ["はるのよのゆめ", "つきのかたむく"])
      expect(host.send(:history_repeat?, "つきのかたぶく")).to eq(true)
    end
  end

  # 其の七十二 D-72-5: 前句エコー（前句をそのまま複写する誤り）の検出
  describe "#maeku_echo? (private)" do
    subject(:host) { host_class.new(maeku: "かすみたなびく") }

    it "前句を完全に含む場合はecho" do
      expect(host.send(:maeku_echo?, "かすみたなびくはなのはるのそらなが")).to eq(true)
    end

    it "前句と無関係な文はecho扱いしない" do
      expect(host.send(:maeku_echo?, "うぐいすのはるをよぶこえきこゆなり")).to eq(false)
    end

    it "冒頭が前句に近い（閾値以内の距離）場合はecho" do
      # 前句「かすみたなびく」7文字、閾値=max(7*0.3をceil=3,3)=3。距離1（1文字違い）は閾値内
      expect(host.send(:maeku_echo?, "かすみたなびきはなのはるのそら")).to eq(true)
    end

    it "冒頭が前句と大きく異なる場合はechoでない" do
      expect(host.send(:maeku_echo?, "はなのいろはうつりにけりないたづらに")).to eq(false)
    end

    it "textが空・nilならfalse" do
      expect(host.send(:maeku_echo?, "")).to eq(false)
      expect(host.send(:maeku_echo?, nil)).to eq(false)
    end
  end

  describe "#extract_mora_segment (private)" do
    subject(:host) { host_class.new }

    # 五七五七七＝31音、各形態素の境界が5/12/17/24/31音にちょうど一致する
    # 手動形態素配列（build_seed_poolが実データで使っているのと同じ形）
    let(:aligned_morphemes) do
      [
        { surface: "つきかげや",     yomi: "つきかげや",     mora: 5 },
        { surface: "たなびくくもの", yomi: "たなびくくもの", mora: 7 },
        { surface: "しろたへに",     yomi: "しろたへに",     mora: 5 },
        { surface: "あきかぜぞふく", yomi: "あきかぜぞふく", mora: 7 },
        { surface: "こひしかりけり", yomi: "こひしかりけり", mora: 7 },
      ]
    end

    it "境界が揃う場合、五七五（先頭17音）を切り出せる" do
      seg = host.send(:extract_mora_segment, aligned_morphemes, 0, 17)
      expect(seg[:surface]).to eq("つきかげやたなびくくものしろたへに")
    end

    it "境界が揃う場合、七七（17音スキップ・14音）を切り出せる" do
      seg = host.send(:extract_mora_segment, aligned_morphemes, 17, 14)
      expect(seg[:surface]).to eq("あきかぜぞふくこひしかりけり")
    end

    it "境界が揃わない場合はnilを返す" do
      misaligned = [{ surface: "はるのゆめみし", yomi: "はるのゆめみし", mora: 20 }]
      expect(host.send(:extract_mora_segment, misaligned, 17, 14)).to be_nil
    end
  end
end
