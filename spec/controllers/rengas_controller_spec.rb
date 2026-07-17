require "rails_helper"

RSpec.describe RengasController, type: :controller do
  describe "#fetch_verse_history (private)" do
    it "previous_renga_idが空なら空配列を返す" do
      expect(controller.send(:fetch_verse_history, nil)).to eq([])
    end

    it "chain全体のtsugekuを古い→新しい順で返す" do
      r1 = Renga.create!(maeku: "まえく1", tsugeku: "つぎく1")
      r2 = Renga.create!(maeku: "まえく2", tsugeku: "つぎく2", previous_renga_id: r1.id)
      r3 = Renga.create!(maeku: "まえく3", tsugeku: "つぎく3", previous_renga_id: r2.id)

      expect(controller.send(:fetch_verse_history, r3.id)).to eq(%w[つぎく1 つぎく2 つぎく3])
    end

    it "履歴の深さによらず1クエリで取得する（N+1が発生しない）" do
      previous_id = nil
      10.times do |i|
        r = Renga.create!(maeku: "まえく#{i}", tsugeku: "つぎく#{i}", previous_renga_id: previous_id)
        previous_id = r.id
      end

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].to_s == "SCHEMA"
        queries << payload[:sql] if payload[:sql].match?(/\brengas\b/i)
      end

      history = controller.send(:fetch_verse_history, previous_id)

      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(history.size).to eq(10)
      expect(queries.size).to eq(1)
    end
  end

  describe "#build_verse_history (private)" do
    it "previous_renga_idが空なら現在句のみのhistoryを返す" do
      history = controller.send(:build_verse_history, nil, "はるののにかすみたなびく", :tanku)
      expect(history).to eq([{ bui: [], season: "春", verse_type: :tanku }])
    end

    it "verse_typeの奇偶交互パターンとseasonのマッピングを維持する" do
      r1 = Renga.create!(maeku: "まえく1", tsugeku: "つぎく1")
      r2 = Renga.create!(maeku: "まえく2", tsugeku: "つぎく2", previous_renga_id: r1.id)
      r3 = Renga.create!(maeku: "まえく3", tsugeku: "つぎく3", previous_renga_id: r2.id)

      # D-41-1修正前は第4引数maekuにr3.tsugekuと異なる文字列を渡すことで
      # 「chain由来3件+maeku追加1件=4件」を期待していたが、これは
      # chain末尾（r3自身）とmaeku追加が本来同一句であるべきという前提を
      # 崩す不自然な呼び出しだった。修正後は実際の呼び出し規約
      # （maekuはprevious_renga_idが指す句と同一）に合わせ、r3.tsugekuを渡す。
      history = controller.send(:build_verse_history, r3.id, r3.tsugeku, :tanku)

      expect(history).to eq([
        { bui: [], season: nil, verse_type: :tanku },
        { bui: [], season: nil, verse_type: :chouku },
        { bui: [], season: nil, verse_type: :tanku }
      ])
    end

    it "chainが9句を超えても直近9句のみを含む（chain.size<9を維持、D-41-1修正後は重複なしでchain.size件）" do
      previous_id = nil
      last_tsugeku = nil
      12.times do |i|
        last_tsugeku = "つぎく#{i}"
        r = Renga.create!(maeku: "まえく#{i}", tsugeku: last_tsugeku, previous_renga_id: previous_id)
        previous_id = r.id
      end

      history = controller.send(:build_verse_history, previous_id, last_tsugeku, :tanku)

      expect(history.size).to eq(9) # chain.size<9の上限（其の三十七）はそのまま、D-41-1修正で重複が消え9件ちょうど
    end

    it "1クエリで取得する（N+1が発生しない）" do
      previous_id = nil
      12.times do |i|
        r = Renga.create!(maeku: "まえく#{i}", tsugeku: "つぎく#{i}", previous_renga_id: previous_id)
        previous_id = r.id
      end

      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        next if payload[:name].to_s == "SCHEMA"
        queries << payload[:sql] if payload[:sql].match?(/\brengas\b/i)
      end

      controller.send(:build_verse_history, previous_id, "げんざいのまえく", :tanku)

      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(queries.size).to eq(1)
    end
  end

  # 其の四十二 D-41-1回帰: build_verse_historyの前句二重カウント修正により、
  # 其の四十一（Run5ログ分析）で特定した誤却下パターンが解消されることを、
  # 実際に誤却下が発生した句・候補文（実データ）で再現・検証する。
  describe "D-41-1回帰: 前句二重カウント修正によるkukazo誤却下の解消" do
    let(:nm)       { controller.send(:build_mecab) }
    let(:bui_dict) { BuiDictionary.new }
    let(:checker)  { ShikimokuChecker.new }

    def kukazo_result_for(previous_renga, candidate_text)
      history = controller.send(
        :build_verse_history, previous_renga.id, previous_renga.tsugeku, :tanku,
        nm: nm, bui_dict: bui_dict
      )
      candidate = {
        bui: bui_dict.detect_all(candidate_text, nm),
        season: controller.send(:season_from_text, candidate_text),
        verse_type: :tanku
      }
      checker.kukazo_violations(history, candidate)
    end

    it "verse30相当: 冬streakの誤カウント(4→3)による誤却下が解消する" do
      r1 = Renga.create!(maeku: "まえく", tsugeku: "霜の夜は星の光を揺れてなり")
      r2 = Renga.create!(maeku: "まえく", tsugeku: "氷の心に身をはやなから", previous_renga_id: r1.id)

      # Run5実データ: この候補は修正前streak=4(max=3超過)でng却下されていた（attempt1・2で2回）
      expect(kukazo_result_for(r2, "音の衣を雪の下に隠して")).to eq([])
    end

    it "verse34相当: 秋streakの誤カウント(6→5)による誤却下が解消する（forced_zatsuエスカレーションの原因だった5回分）" do
      r1 = Renga.create!(maeku: "まえく", tsugeku: "月の影に心を寄せたるかな")
      r2 = Renga.create!(maeku: "まえく", tsugeku: "鹿のききょううゑて見るへくかな", previous_renga_id: r1.id)
      r3 = Renga.create!(maeku: "まえく", tsugeku: "川のほとりの月の光りてゆかねり", previous_renga_id: r2.id)
      r4 = Renga.create!(maeku: "まえく", tsugeku: "もみじのしぐれにかへりけり", previous_renga_id: r3.id)

      # Run5実データ: この候補は修正前streak=6(max=5超過)でng却下されていた（attempt1〜5、5回連続）
      expect(kukazo_result_for(r4, "秋風のささやきに心ゆかし")).to eq([])
    end

    it "verse56相当: 秋streakの誤カウントによる誤却下が解消する" do
      r1 = Renga.create!(maeku: "まえく", tsugeku: "月の光りそっと心に沁みてなり")
      r2 = Renga.create!(maeku: "まえく", tsugeku: "菊の香りひくらしのこゑかな", previous_renga_id: r1.id)
      r3 = Renga.create!(maeku: "まえく", tsugeku: "つもれは人のもみちに露そそぐ", previous_renga_id: r2.id)
      r4 = Renga.create!(maeku: "まえく", tsugeku: "きりの紅葉ゆかし秋の嵐", previous_renga_id: r3.id)

      # Run5実データ: この候補は修正前streak超過でattempt1のみng却下されていた
      expect(kukazo_result_for(r4, "しぐれの音に心の雨やと願う")).to eq([])
    end

    it "verse21相当: kukazo_under（最短規制）の判定結論は修正前後で変わらない" do
      r1 = Renga.create!(maeku: "まえく", tsugeku: "月の光に揺れる心の波かな")

      # Run5実データ: 修正前streak=2(表示のみ誤り)・修正後streak=1、
      # いずれもmin=3未満のため結論（ng）自体は変わらない
      result = kukazo_result_for(r1, "夜空に散る星屑の夢かな")
      expect(result).to contain_exactly(hash_including(type: :kukazo_under, season: "秋", streak: 1, min: 3))
    end
  end
end
