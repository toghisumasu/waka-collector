require "rails_helper"

RSpec.describe StepwiseWakaGenerator do
  def build(maeku, verse_type, constraints: {})
    described_class.new(maeku, verse_type, constraints: constraints, pool: [], nm: nil, bui_dict: nil)
  end

  describe "#waka_extraction_bounds (private)" do
    it "chouku（長句・五七五＝17音）は先頭17音を指定する" do
      generator = build("まえく", :chouku)
      expect(generator.send(:waka_extraction_bounds)).to eq([0, 17])
    end

    it "tanku（短句・七七＝14音）は17音スキップして14音を指定する" do
      generator = build("まえく", :tanku)
      expect(generator.send(:waka_extraction_bounds)).to eq([17, 14])
    end
  end

  describe "#waka_total_mora_within_tolerance? (private)" do
    subject(:generator) { build("まえく", :tanku) }

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

  describe "#build_free_verse_prompt (private、Step1)" do
    let(:seed)    { { surface: "つきかげ", season: "秋" } }
    let(:persona) { WakaPersona::PERSONAS[:hermit] }

    it "前句・連想・季節を含み、三十一音程度を目安に短く終わらせないよう指示する" do
      generator = build("しぐれふるなり", :tanku)
      prompt = generator.send(:build_free_verse_prompt, seed, nil, "秋", persona)
      expect(prompt).to include("しぐれふるなり")
      expect(prompt).to include("つきかげ")
      expect(prompt).to include("秋")
      expect(prompt).to include("三十一音程度")
      expect(prompt).to include("短いフレーズだけで終わらせないこと")
    end

    it "前句の複写・連想語単独出力を禁止する" do
      generator = build("しぐれふるなり", :tanku)
      prompt = generator.send(:build_free_verse_prompt, seed, nil, "秋", persona)
      expect(prompt).to include("前句の言葉をそのまま和歌に含めてはいけません")
      expect(prompt).to include("連想語だけを単独で出力してはいけません")
    end

    it "feedbackがある場合は前回の指摘文言を含む" do
      generator = build("しぐれふるなり", :tanku)
      feedback  = { ku: "しぐれふるなりけり", issue: "前句エコー",
                    message: "前句をそのまま繰り返さず、新しい言葉で詠み直してください" }
      prompt = generator.send(:build_free_verse_prompt, seed, feedback, "秋", persona)
      expect(prompt).to include("前句エコー")
      expect(prompt).to include("前句をそのまま繰り返さず、新しい言葉で詠み直してください")
    end

    it "指定されたペルソナの名前・立ち位置・視線移動・ネガティブ指示を含む" do
      generator = build("しぐれふるなり", :tanku)
      prompt = generator.send(:build_free_verse_prompt, seed, nil, "秋", persona)
      expect(prompt).to include("【ペルソナ】")
      expect(prompt).to include(persona[:name])
      expect(prompt).to include(persona[:stance])
      expect(prompt).to include("【視座の移動】")
      expect(prompt).to include(persona[:gaze_path][0])
      expect(prompt).to include(persona[:gaze_path][1])
      expect(prompt).to include(persona[:gaze_path][2])
      expect(prompt).to include("【描写の注意】")
      expect(prompt).to include(WakaPersona::NEGATIVE_INSTRUCTION)
    end

    it "ペルソナが変われば視座の記述も変わる" do
      generator = build("しぐれふるなり", :tanku)
      hermit_prompt = generator.send(:build_free_verse_prompt, seed, nil, "秋", WakaPersona::PERSONAS[:hermit])
      youth_prompt  = generator.send(:build_free_verse_prompt, seed, nil, "秋", WakaPersona::PERSONAS[:youth])
      expect(hermit_prompt).not_to eq(youth_prompt)
      expect(hermit_prompt).to include(WakaPersona::PERSONAS[:hermit][:name])
      expect(youth_prompt).to include(WakaPersona::PERSONAS[:youth][:name])
    end
  end

  describe "#build_mora_rewrite_prompt (private、Step3)" do
    it "意味を保ったまま31音へ書き換える指示・区切り記号禁止を含む" do
      generator = build("しぐれふるなり", :tanku)
      prompt = generator.send(:build_mora_rewrite_prompt, "つきかげやたなびくくものしろたへにあきかぜぞふくこひしかりけり", nil)
      expect(prompt).to include("三十一音")
      expect(prompt).to include("区切り記号")
      expect(prompt).to include("つきかげやたなびくくものしろたへにあきかぜぞふくこひしかりけり")
    end

    it "feedbackがある場合は前回の書き換えへの指摘文言を含む" do
      generator = build("しぐれふるなり", :tanku)
      feedback  = { ku: "つきかげやたなびくくもの", issue: "区切り不一致",
                    message: "五・七・五・七・七の音数の区切りで書き換えてください" }
      prompt = generator.send(:build_mora_rewrite_prompt, "つきかげやたなびくくもの", feedback)
      expect(prompt).to include("区切り不一致")
      expect(prompt).to include("五・七・五・七・七の音数の区切りで書き換えてください")
    end

    it "feedbackは書き換え対象テキストより前（指示ブロック側）に置かれる" do
      generator = build("しぐれふるなり", :tanku)
      feedback  = { ku: "つきかげやたなびくくもの", issue: "区切り不一致",
                    message: "五・七・五・七・七の音数の区切りで書き換えてください" }
      prompt = generator.send(:build_mora_rewrite_prompt, "つきかげやたなびくくもの", feedback)
      expect(prompt.index("区切り不一致")).to be < prompt.index("【書き換え対象】")
    end
  end

  describe "#content_violation (private、Step2)" do
    it "前句エコーを検出する" do
      generator = build("かすみたなびく", :tanku)
      violation = generator.send(:content_violation, "かすみたなびくはなのはるのそらなが")
      expect(violation[:issue]).to eq("前句エコー")
    end

    it "一巻内の既出表現を検出する" do
      generator = build("しらくもかかる", :tanku, constraints: { verse_history: ["つきのかたむく"] })
      violation = generator.send(:content_violation, "つきのかたむく")
      expect(violation[:issue]).to eq("既出")
    end

    it "違反がなければnil" do
      generator = build("かすみたなびく", :tanku)
      expect(generator.send(:content_violation, "うぐいすのはるをよぶこえきこゆなり")).to be_nil
    end
  end
end
