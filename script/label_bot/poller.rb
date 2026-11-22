# frozen_string_literal: true

require_relative "store"
require_relative "keyboard"

module LabelBot
  # 更新 1 件の処理。許可した chat_id 以外はすべて無視する（本文は記録しない）。
  class Poller
    def initialize(store:, api:, chat_id:, out: $stdout)
      @store = store
      @api = api
      @chat_id = chat_id.to_s
      @out = out
    end

    # 長いポーリングを 1 回行い、受け取った更新をすべて処理する。
    def poll_once(timeout: 50)
      updates = @api.get_updates(offset: @store.offset, timeout: timeout)
      updates.each do |u|
        handle(u)
        @store.save_offset(u["update_id"] + 1)
      end
      updates.size
    end

    def handle(update)
      if (cq = update["callback_query"])
        chat = cq.dig("message", "chat", "id")
        return ignore(update) unless allowed?(chat)

        handle_callback(cq)
      elsif (msg = update["message"])
        return ignore(update) unless allowed?(msg.dig("chat", "id"))

        handle_message(msg)
      end
    end

    private

    def allowed?(chat_id)
      !chat_id.nil? && chat_id.to_s == @chat_id
    end

    def ignore(update)
      say "許可していない chat の更新を無視しました（update_id=#{update['update_id']}）"
      :ignored
    end

    def handle_callback(cq)
      parsed = Keyboard.parse(cq["data"])
      found = parsed && @store.find_item(parsed[1])
      unless found
        @api.answer_callback(callback_query_id: cq["id"], text: "不明な操作です")
        return :unknown
      end

      field, item_id, value = parsed
      state = @store.current_state[item_id]
      action = "set"
      if field == "tag"
        action = state[:tags].include?(value) ? "remove" : "add"
      end
      @store.append_label(batch: found[:batch], item_id: item_id, field: field, value: value, action: action)
      @store.write_csv

      state = @store.current_state[item_id]
      @api.answer_callback(callback_query_id: cq["id"])
      @api.edit_reply_markup(chat_id: cq.dig("message", "chat", "id"), message_id: cq.dig("message", "message_id"),
                             reply_markup: Keyboard.markup(item_id, value: state[:value], tags: state[:tags]))
      announce_completion(found[:batch])
      :labeled
    end

    def handle_message(msg)
      text = msg["text"].to_s.strip
      m = text.match(%r{\A/memo(?:@\S+)?\s+(\d+)\s+(.+)\z}m)
      return :ignored_text unless m

      batch = @store.last_sent_batch
      unless batch
        reply("配信済みの batch がありません。")
        return :no_batch
      end

      found = @store.find_by_number(batch, m[1])
      unless found
        reply("番号 #{m[1]} は #{batch}日目にありません。")
        return :bad_number
      end

      @store.append_label(batch: batch, item_id: found[:item]["id"], field: "memo", value: m[2].strip, action: "set")
      @store.write_csv
      reply("#{m[1]}/#{found[:total]} にメモを保存しました。")
      :memo
    end

    def announce_completion(batch)
      return if @store.completion_recorded?(batch) || !@store.complete?(batch)

      @store.append_sent({ kind: "complete", batch: batch, sent_at: Config.now_jst.iso8601 })
      reply("#{batch}日目 完了")
    end

    def reply(text)
      @api.send_message(chat_id: @chat_id, text: text)
    end

    def say(msg)
      @out.puts("[poll] #{msg}")
    end
  end
end
