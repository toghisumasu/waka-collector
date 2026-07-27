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

  # 其の七十二: 和歌形式抽出パイプライン（constraints[:generation_strategy] == :waka_extraction）
  describe "#waka_extraction_bounds (private)" do
    it "chouku（長句・五七五＝17音）は先頭17音を指定する" do
      generator = described_class.new("まえく", [], :chouku)
      expect(generator.send(:waka_extraction_bounds)).to eq([0, 17])
    end

    it "tanku（短句・七七＝14音）は17音スキップして14音を指定する" do
      generator = described_class.new("まえく", [], :tanku)
      expect(generator.send(:waka_extraction_bounds)).to eq([17, 14])
    end
  end

  describe "#waka_total_mora_within_tolerance? (private)" do
    subject(:generator) { described_class.new("まえく", [], :tanku) }

    it "31音ちょうどは許容内" do
      expect(generator.send(:waka_total_mora_within_tolerance?, 31)).to eq(true)
    end

    it "±2音以内は許容内" do
      expect(generator.send(:waka_total_mora_within_tolerance?, 29)).to eq(true)
      expect(generator.send(:waka_total_mora_within_tolerance?, 33)).to eq(true)
    end

    it "±2音を超えると許容外" do
      expect(generator.send(:waka_total_mora_within_tolerance?, 28)).to eq(false)
      expect(generator.send(:waka_total_mora_within_tolerance?, 34)).to eq(false)
    end
  end

  describe "#maeku_echo? (private)" do
    subject(:generator) { described_class.new("かすみたなびく", [], :chouku) }

    it "前句を完全に含む場合はecho" do
      expect(generator.send(:maeku_echo?, "かすみたなびくはなのはるのそらなが")).to eq(true)
    end

    it "前句と無関係な文はecho扱いしない" do
      expect(generator.send(:maeku_echo?, "うぐいすのはるをよぶこえきこゆなり")).to eq(false)
    end

    it "冒頭が前句に近い（閾値以内の距離）場合はecho" do
      # 前句「かすみたなびく」7文字、閾値=max(7*0.3をceil=3,3)=3。距離1（1文字違い）は閾値内
      expect(generator.send(:maeku_echo?, "かすみたなびきはなのはるのそら")).to eq(true)
    end

    it "冒頭が前句と大きく異なる場合はechoでない" do
      expect(generator.send(:maeku_echo?, "はなのいろはうつりにけりないたづらに")).to eq(false)
    end

    it "textが空・nilならfalse" do
      expect(generator.send(:maeku_echo?, "")).to eq(false)
      expect(generator.send(:maeku_echo?, nil)).to eq(false)
    end
  end

  describe "#extract_mora_segment (private)" do
    subject(:generator) { described_class.new("まえく", [], :tanku) }

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
      seg = generator.send(:extract_mora_segment, aligned_morphemes, 0, 17)
      expect(seg[:surface]).to eq("つきかげやたなびくくものしろたへに")
    end

    it "境界が揃う場合、七七（17音スキップ・14音）を切り出せる" do
      seg = generator.send(:extract_mora_segment, aligned_morphemes, 17, 14)
      expect(seg[:surface]).to eq("あきかぜぞふくこひしかりけり")
    end

    it "境界が揃わない場合はnilを返す" do
      misaligned = [{ surface: "はるのゆめみし", yomi: "はるのゆめみし", mora: 20 }]
      expect(generator.send(:extract_mora_segment, misaligned, 17, 14)).to be_nil
    end
  end

  describe "#build_waka_extraction_prompt (private)" do
    let(:seed) { { surface: "つきかげ", season: "秋" } }

    it "31音の和歌一首を詠ませる指示・前句・季節を含む" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      prompt = generator.send(:build_waka_extraction_prompt, seed, nil, "秋", nil)
      expect(prompt).to include("三十一音")
      expect(prompt).to include("しぐれふるなり")
      expect(prompt).to include("秋")
    end

    it "feedbackがある場合は前回の指摘文言を含む" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      feedback  = { ku: "つきかげやたなびく", issue: "区切り不一致",
                    message: "五・七・五・七・七の音数の区切りで詠み直してください" }
      prompt = generator.send(:build_waka_extraction_prompt, seed, feedback, "秋", nil)
      expect(prompt).to include("区切り不一致")
      expect(prompt).to include("五・七・五・七・七の音数の区切りで詠み直してください")
    end

    it "連想語を単独で出力させないための注意書き・五句すべてを含むfew-shot例を含む" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      prompt = generator.send(:build_waka_extraction_prompt, seed, nil, "秋", nil)
      expect(prompt).to include("連想語だけを単独で出力してはいけません")
      expect(prompt).to include("うぐいすのはるをよぶこえきこゆなりのべのわかくさもえいづるころ")
    end

    it "前句をそのまま複写しないことを明示する" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      prompt = generator.send(:build_waka_extraction_prompt, seed, nil, "秋", nil)
      expect(prompt).to include("前句の言葉をそのまま和歌に含めてはいけません")
    end

    it "三十一音を超えないことを明示する" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      prompt = generator.send(:build_waka_extraction_prompt, seed, nil, "秋", nil)
      expect(prompt).to include("三十一音を超えないこと")
    end

    it "few-shot例文（和歌部分）には区切り記号（／）を含めない（モデルの複写誘発を避けるため）" do
      generator = described_class.new("しぐれふるなり", [], :tanku)
      block = generator.send(:waka_extraction_examples_block)
      expect(block).not_to include("／")
    end
  end
end
