# frozen_string_literal: true

require_relative "store"
require_relative "keyboard"

module LabelBot
  # 次の batch を送る。完了ゲートと同日二重送信の防止を持つ。
  class Sender
    def initialize(store:, api:, chat_id:, out: $stdout)
      @store = store
      @api = api
      @chat_id = chat_id
      @out = out
    end

    # 戻り値: :sent / :reminded / :skipped_same_day / :nothing / :no_batches
    def run(now = Config.now_jst)
      date = now.strftime("%Y-%m-%d")
      if @store.sent_on?(date)
        say "本日（#{date}）はすでに送信済みです。何も送りません。"
        return :skipped_same_day
      end

      last = @store.last_sent_batch
      if last && !@store.complete?(last)
        remind(last, date, now)
      else
        send_next(date, now)
      end
    end

    private

    def remind(last, date, now)
      total = @store.batch_items(last).size
      rest = total - @store.valued_count(last)
      @api.send_message(chat_id: @chat_id, text: "#{last}日目の句が未完了です（残り #{rest} 件）。完了すると次の句が届きます。")
      @store.append_sent({ kind: "reminder", batch: last, date: date, sent_at: now.iso8601, remaining: rest })
      say "リマインダーを送信（#{last}日目、残り #{rest} 件）"
      :reminded
    end

    def send_next(date, now)
      n = @store.next_unsent_batch
      if n.nil?
        say(@store.batch_numbers.empty? ? "batch がありません。" : "配信する次の batch がありません。")
        return @store.batch_numbers.empty? ? :no_batches : :nothing
      end

      items = @store.batch_items(n)
      # 先に記録する（途中で失敗しても、同じ batch を再送して二重配信にならないため）
      @store.append_sent({ kind: "batch", batch: n, date: date, sent_at: now.iso8601, count: items.size })
      sent = 0
      begin
        items.each_with_index do |it, i|
          @api.send_message(chat_id: @chat_id,
                            text: "#{i + 1}/#{items.size} 【#{it['form']}】#{it['text']}",
                            reply_markup: Keyboard.markup(it["id"]))
          sent += 1
        end
      rescue StandardError => e
        @store.append_sent({ kind: "batch_partial", batch: n, date: date, sent: sent, count: items.size })
        raise e
      end
      say "#{n}日目の #{items.size} 句を送信しました。"
      :sent
    end

    def say(msg)
      @out.puts("[send_batch] #{msg}")
    end
  end
end
