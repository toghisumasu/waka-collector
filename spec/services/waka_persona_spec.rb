require "rails_helper"

RSpec.describe WakaPersona do
  describe ".resolve" do
    it "具体的なキー指定はそのペルソナを返す" do
      expect(described_class.resolve(:hermit, "まえく")).to eq(WakaPersona::PERSONAS[:hermit])
      expect(described_class.resolve(:youth, "まえく")).to eq(WakaPersona::PERSONAS[:youth])
      expect(described_class.resolve(:woman, "まえく")).to eq(WakaPersona::PERSONAS[:woman])
    end

    it ":randomは前句の内容に関わらずいずれかのペルソナを返す" do
      # キーワードが一致するhermit向けの前句を渡しても:randomは常にランダム選出する
      persona = described_class.resolve(:random, "山深き草庵にひとり住む")
      expect(WakaPersona::PERSONAS.values).to include(persona)
    end

    it "未指定（nil）で前句にキーワードが一致すれば該当ペルソナを返す" do
      persona = described_class.resolve(nil, "山深き草庵にひとり住む")
      expect(persona).to eq(WakaPersona::PERSONAS[:hermit])
    end

    it "未指定（nil）で前句にキーワードが一致しなければランダムにフォールバックする" do
      persona = described_class.resolve(nil, "つきかげやたなびくくもの")
      expect(WakaPersona::PERSONAS.values).to include(persona)
    end

    it "未知のキーはArgumentErrorを送出する" do
      expect { described_class.resolve(:unknown_persona, "まえく") }.to raise_error(ArgumentError)
    end
  end

  describe ".resolve_zone（其の七十七 D-77-2）" do
    it "キー指定は該当する距離帯を返す" do
      expect(described_class.resolve_zone(:near)[:label]).to eq("手元・身近")
      expect(described_class.resolve_zone(:far)[:label]).to eq("遠く")
    end

    it "未指定（nil）はいずれかの距離帯を返す" do
      expect(WakaPersona::GAZE_ZONES).to include(described_class.resolve_zone)
    end

    it "未知のキーはArgumentErrorを送出する" do
      expect { described_class.resolve_zone(:nowhere) }.to raise_error(ArgumentError)
    end

    it "距離帯は具体的な景物の語を含まない（丸写しの原因を作らない）" do
      # 「若草」「露」など、そのまま和歌に使える名詞をcueに入れてはならない
      concrete_words = WakaPersona::PERSONAS.values.flat_map { |p| p[:gaze_path] }
      WakaPersona::GAZE_ZONES.each do |zone|
        text = "#{zone[:label]}#{zone[:cue]}#{zone[:sense]}"
        concrete_words.each { |w| expect(text).not_to include(w) }
      end
    end
  end

  describe ".best_match" do
    it "hermitのキーワードを含む前句はhermitと一致する" do
      expect(described_class.best_match("山深き草庵にひとり住む")).to eq(WakaPersona::PERSONAS[:hermit])
    end

    it "youthのキーワードを含む前句はyouthと一致する" do
      expect(described_class.best_match("若草萌ゆる春の朝")).to eq(WakaPersona::PERSONAS[:youth])
    end

    it "womanのキーワードを含む前句はwomanと一致する" do
      expect(described_class.best_match("格子窓のそばで針仕事をする")).to eq(WakaPersona::PERSONAS[:woman])
    end

    it "どのキーワードも含まない前句はnilを返す" do
      expect(described_class.best_match("つきかげやたなびくくもの")).to be_nil
    end

    it "空・nilはnilを返す" do
      expect(described_class.best_match("")).to be_nil
      expect(described_class.best_match(nil)).to be_nil
    end
  end
end
