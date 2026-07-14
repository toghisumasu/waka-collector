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
end
