require "rails_helper"
require "tmpdir"

# 其の七十七 D-77-1: StepwiseStepLoggerはStepwiseWakaGeneratorへincludeされる
# 前提のモジュールなので、実際のincluder経由で検証する。
RSpec.describe StepwiseStepLogger do
  around do |example|
    Dir.mktmpdir("stepwise_step_log") do |dir|
      @log_dir = dir
      example.run
    end
  end

  def build(constraints: {}, verse_type: :tanku, nm: nil)
    generator = StepwiseWakaGenerator.new(
      "まえく", verse_type, constraints: constraints, pool: [], nm: nm, bui_dict: nil
    )
    allow(generator).to receive(:step_log_path).and_return(File.join(@log_dir, "steps.jsonl"))
    generator
  end

  def records(generator)
    path = generator.send(:step_log_path)
    return [] unless File.exist?(path)

    File.readlines(path).map { |line| JSON.parse(line) }
  end

  describe "#log_step" do
    it "ブロックの戻り値をそのまま返す（生成結果に介入しない）" do
      generator = build
      result = generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "よまれたわか" }
      expect(result).to eq("よまれたわか")
    end

    it "入出力・所要秒数・プロンプトのdigestを1行記録する" do
      generator = build
      generator.send(:log_step, "step3", prompt: "ぷろんぷと", input_text: "したがき") { "しゅつりょく" }

      expect(records(generator).size).to eq(1)
      rec = records(generator).first
      expect(rec["step"]).to eq("step3")
      expect(rec["input_text"]).to eq("したがき")
      expect(rec["output"]).to eq("しゅつりょく")
      expect(rec["prompt_digest"]).to eq(Digest::SHA256.hexdigest("ぷろんぷと")[0, 12])
      expect(rec["elapsed_sec"]).to be_a(Float)
      expect(rec["failure"]).to be_nil
      expect(rec["ts"]).to be_present
    end

    it "プロンプト全文は既定では記録しない" do
      generator = build
      generator.send(:log_step, "step1", prompt: "ないしょのぷろんぷと") { "しゅつりょく" }
      expect(records(generator).first).not_to have_key("prompt")
    end

    it "log_context[:full_prompt]が真ならプロンプト全文も記録する" do
      generator = build(constraints: { log_context: { full_prompt: true } })
      generator.send(:log_step, "step1", prompt: "ないしょのぷろんぷと") { "しゅつりょく" }
      expect(records(generator).first["prompt"]).to eq("ないしょのぷろんぷと")
    end

    it "ブロックが例外を投げた場合、失敗として記録した上で例外を伝播させる" do
      generator = build
      expect {
        generator.send(:log_step, "step1", prompt: "ぷろんぷと") do
          raise RuntimeError, "メンタムさんへの接続がタイムアウトしました（180秒）"
        end
      }.to raise_error(RuntimeError, /タイムアウト/)

      rec = records(generator).first
      expect(rec["failure"]).to include("RuntimeError")
      expect(rec["failure"]).to include("タイムアウト")
      expect(rec["output"]).to be_nil
    end

    it "記録に失敗しても生成を止めない（例外を投げずブロックの戻り値を返す）" do
      generator = build
      allow(generator).to receive(:step_log_path).and_return("/no/such/dir/steps.jsonl")
      expect(Rails.logger).to receive(:warn).with(/StepwiseStepLogger/)
      expect(generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "よまれたわか" })
        .to eq("よまれたわか")
    end
  end

  describe "出力先" do
    it "テスト環境では既定の出力先を持たない（実ログを汚染しない）" do
      generator = StepwiseWakaGenerator.new(
        "まえく", :tanku, constraints: {}, pool: [], nm: nil, bui_dict: nil
      )
      expect(generator.send(:step_log_path)).to be_nil
    end

    it "出力先がnilなら書き込まずブロックの戻り値を返す" do
      generator = StepwiseWakaGenerator.new(
        "まえく", :tanku, constraints: {}, pool: [], nm: nil, bui_dict: nil
      )
      expect(File).not_to receive(:open)
      expect(generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "よまれたわか" })
        .to eq("よまれたわか")
    end
  end

  describe "#log_step_verdict" do
    it "issueがnilならok判定として記録する" do
      generator = build
      generator.send(:log_step_verdict, "step2", text: "はんていたいしょう")
      rec = records(generator).first
      expect(rec["step"]).to eq("step2")
      expect(rec["verdict"]).to eq("ok")
      expect(rec["issue"]).to be_nil
      expect(rec["input_text"]).to eq("はんていたいしょう")
    end

    it "issueがあれば違反理由を記録する（其の七十六 未検証事項1の内訳）" do
      generator = build
      generator.send(:log_step_verdict, "step4", text: "はんていたいしょう", issue: "区切り不一致")
      rec = records(generator).first
      expect(rec["verdict"]).to eq("区切り不一致")
      expect(rec["issue"]).to eq("区切り不一致")
    end
  end

  describe "相関キー" do
    it "log_contextのbatch・verse_no・attemptを各行に記録する" do
      generator = build(constraints: { log_context: { batch: "sono77_run1", verse_no: 12, attempt: 3 } })
      generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "しゅつりょく" }
      rec = records(generator).first
      expect(rec["batch"]).to eq("sono77_run1")
      expect(rec["verse_no"]).to eq(12)
      expect(rec["attempt"]).to eq(3)
    end

    it "log_context未指定でも記録は成立する（当該欄はnull）" do
      generator = build
      generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "しゅつりょく" }
      rec = records(generator).first
      expect(rec["batch"]).to be_nil
      expect(rec["verse_no"]).to be_nil
      expect(rec["verse_type"]).to eq("tanku")
    end

    it "ペルソナ・seed・draft_attemptを記録する" do
      generator = build
      generator.instance_variable_set(:@draft_attempt, 2)
      generator.instance_variable_set(:@current_persona, WakaPersona::PERSONAS[:hermit])
      generator.instance_variable_set(:@current_seed, { surface: "つきかげ", waka_id: 42 })
      generator.send(:log_step, "step1", prompt: "ぷろんぷと") { "しゅつりょく" }
      rec = records(generator).first
      expect(rec["draft_attempt"]).to eq(2)
      expect(rec["persona"]).to eq(WakaPersona::PERSONAS[:hermit][:name])
      expect(rec["seed"]).to eq("つきかげ")
      expect(rec["seed_waka_id"]).to eq(42)
    end

    it "extraの任意欄を記録するが、コア欄は上書きさせない" do
      generator = build
      generator.send(:log_step, "step1", prompt: "ぷろんぷと",
                     extra: { content_retry: 2, season_label: "秋", step: "偽装" }) { "しゅつりょく" }
      rec = records(generator).first
      expect(rec["content_retry"]).to eq(2)
      expect(rec["season_label"]).to eq("秋")
      expect(rec["step"]).to eq("step1")
    end
  end

  # StepwiseWakaGenerator#generate から各ステップが実際に記録されるか（配線の確認）。
  # Ollamaはスタブし、句の成立可否は問わない。
  describe "generateからの配線" do
    let(:waka31) { "つきかげやたなびくくものしろたへにあきかぜぞふくこひしかりけり" } # 30音

    it "step1・step2・step3・step4の各行が記録される" do
      generator = StepwiseWakaGenerator.new(
        "はなのはるかな", :chouku,
        constraints: { log_context: { batch: "wiring_test", verse_no: 1 } },
        pool: [{ surface: "つきかげ", season: "秋", waka_id: 7 }],
        nm: Natto::MeCab.new, bui_dict: BuiDictionary.new
      )
      allow(generator).to receive(:step_log_path).and_return(File.join(@log_dir, "steps.jsonl"))
      allow(OllamaClient).to receive(:generate).and_return(waka31)

      generator.generate

      steps = records(generator).map { |r| r["step"] }.uniq
      expect(steps).to include("step1", "step2", "step3", "step4")
    end

    it "適正音数のStep1出力ではstep1.5がskipとして記録される" do
      generator = StepwiseWakaGenerator.new(
        "はなのはるかな", :chouku, constraints: {},
        pool: [{ surface: "つきかげ", season: "秋", waka_id: 7 }],
        nm: Natto::MeCab.new, bui_dict: BuiDictionary.new
      )
      allow(generator).to receive(:step_log_path).and_return(File.join(@log_dir, "steps.jsonl"))
      allow(OllamaClient).to receive(:generate).and_return(waka31)

      generator.generate

      skips = records(generator).select { |r| r["step"] == "step1.5" }
      expect(skips).to be_present
      expect(skips.map { |r| r["direction"] }.uniq).to eq(["skip"])
    end

    it "ペルソナ・seed・draft_attemptが実走行でも各行に載る" do
      generator = StepwiseWakaGenerator.new(
        "はなのはるかな", :chouku, constraints: { persona: :woman },
        pool: [{ surface: "つきかげ", season: "秋", waka_id: 7 }],
        nm: Natto::MeCab.new, bui_dict: BuiDictionary.new
      )
      allow(generator).to receive(:step_log_path).and_return(File.join(@log_dir, "steps.jsonl"))
      allow(OllamaClient).to receive(:generate).and_return(waka31)

      generator.generate

      rec = records(generator).find { |r| r["step"] == "step1" }
      expect(rec["persona"]).to eq(WakaPersona::PERSONAS[:woman][:name])
      expect(rec["seed"]).to eq("つきかげ")
      expect(rec["seed_waka_id"]).to eq(7)
      expect(rec["draft_attempt"]).to eq(1)
      expect(rec["content_retry"]).to eq(1)
    end
  end

  describe "音数の記録" do
    it "@nmがあれば入出力のモーラ数を記録する" do
      generator = build(nm: Natto::MeCab.new)
      generator.send(:log_step, "step1.5", prompt: "ぷろんぷと", input_text: "つきかげ") { "つきかげや" }
      rec = records(generator).first
      expect(rec["input_mora"]).to eq(4)
      expect(rec["output_mora"]).to eq(5)
    end

    it "@nmがなければモーラ数はnullだが記録自体は成立する" do
      generator = build(nm: nil)
      generator.send(:log_step, "step1.5", prompt: "ぷろんぷと", input_text: "つきかげ") { "つきかげや" }
      rec = records(generator).first
      expect(rec["input_mora"]).to be_nil
      expect(rec["output"]).to eq("つきかげや")
    end
  end
end
