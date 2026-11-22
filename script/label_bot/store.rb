# frozen_string_literal: true

require "json"
require "csv"
require "fileutils"
require_relative "config"
require_relative "keyboard"

module LabelBot
  # tmp/gendai/ の読み書き。key.json（出典・標本種別）は読まない。
  #   batches/day{N}.json … 入力（id, form, text）
  #   sent.jsonl          … 配信・リマインダー・完了の記録（追記のみ）
  #   labels.jsonl        … ボタン・メモ操作の記録（追記のみ）
  #   labels.csv          … 現在値の集約（毎回書き直す）
  #   offset.json         … getUpdates の offset
  class Store
    CSV_HEADER = %w[ID 値 タグ メモ 最終更新].freeze

    attr_reader :dir

    def initialize(dir = Config.data_dir)
      @dir = dir
      FileUtils.mkdir_p(File.join(@dir, "batches"))
    end

    # ── 入力 batch ──────────────────────────────
    def batch_numbers
      Dir.glob(File.join(@dir, "batches", "day*.json")).filter_map do |f|
        File.basename(f)[/\Aday(\d+)\.json\z/, 1]&.to_i
      end.sort
    end

    def batch_items(number)
      items = JSON.parse(File.read(File.join(@dir, "batches", "day#{number}.json"), encoding: "UTF-8"))
      items.each do |it|
        raise "不正な id: #{it['id'].inspect}（day#{number}）" unless Keyboard.valid_id?(it["id"])
      end
      items
    end

    # ── sent.jsonl ──────────────────────────────
    def sent_entries
      read_jsonl("sent.jsonl")
    end

    def append_sent(entry)
      append_jsonl("sent.jsonl", entry)
    end

    # 配信済みの batch 番号（kind == "batch"）
    def sent_batch_numbers
      sent_entries.select { |e| e["kind"] == "batch" }.map { |e| e["batch"] }.uniq.sort
    end

    def next_unsent_batch
      (batch_numbers - sent_batch_numbers).first
    end

    def last_sent_batch
      sent_batch_numbers.last
    end

    # 今日（JST の日付）すでに何か（batch / reminder / 送り直し）送っているか
    def sent_on?(date)
      sent_entries.any? { |e| %w[batch reminder batch_resumed].include?(e["kind"]) && e["date"] == date }
    end

    # 途中で送信に失敗し、まだ全件送れていない batch。
    # batch_partial（送れた件数 sent）が、同じ batch の batch_resumed（全件送れた）より後ろにある場合。
    # 戻り値: { batch:, sent:, count: } / なければ nil
    def pending_partial
      pending = nil
      sent_entries.each do |e|
        case e["kind"]
        when "batch_partial" then pending = { batch: e["batch"], sent: e["sent"], count: e["count"] }
        when "batch_resumed" then pending = nil if pending && pending[:batch] == e["batch"]
        end
      end
      pending
    end

    def completion_recorded?(batch)
      sent_entries.any? { |e| e["kind"] == "complete" && e["batch"] == batch }
    end

    # ── labels.jsonl ────────────────────────────
    def append_label(batch:, item_id:, field:, value:, action:, ts: Config.now_jst)
      append_jsonl("labels.jsonl", { ts: ts.iso8601, batch: batch, item_id: item_id,
                                     field: field, value: value, action: action })
    end

    # item_id => { value:, tags:, memo:, updated: }（追記順に畳み込む）
    def current_state
      state = Hash.new { |h, k| h[k] = { value: nil, tags: [], memo: nil, updated: nil } }
      read_jsonl("labels.jsonl").each do |l|
        s = state[l["item_id"]]
        case l["field"]
        when "value" then s[:value] = l["value"]
        when "tag"
          l["action"] == "remove" ? s[:tags].delete(l["value"]) : (s[:tags] << l["value"] unless s[:tags].include?(l["value"]))
        when "memo" then s[:memo] = l["value"]
        end
        s[:updated] = l["ts"]
      end
      state
    end

    # 配信済み batch の (batch, item) を探す。配信していない batch の id は対象外。
    def find_item(item_id)
      sent_batch_numbers.each do |n|
        batch_items(n).each_with_index do |it, i|
          return { batch: n, index: i + 1, total: batch_items(n).size, item: it } if it["id"] == item_id
        end
      end
      nil
    end

    def find_by_number(batch, number)
      items = batch_items(batch)
      it = items[number.to_i - 1] if number.to_i.between?(1, items.size)
      it && { batch: batch, index: number.to_i, total: items.size, item: it }
    end

    # 値が入った件数
    def valued_count(batch)
      state = current_state
      batch_items(batch).count { |it| state.key?(it["id"]) && state[it["id"]][:value] }
    end

    def complete?(batch)
      valued_count(batch) == batch_items(batch).size
    end

    def write_csv
      state = current_state
      path = File.join(@dir, "labels.csv")
      CSV.open(path, "w", encoding: "UTF-8") do |csv|
        csv << CSV_HEADER
        sent_batch_numbers.each do |n|
          batch_items(n).each do |it|
            s = state.key?(it["id"]) ? state[it["id"]] : { value: nil, tags: [], memo: nil, updated: nil }
            csv << [ it["id"], s[:value], s[:tags].join("|"), s[:memo], s[:updated] ]
          end
        end
      end
      path
    end

    # ── offset ──────────────────────────────────
    def offset
      f = File.join(@dir, "offset.json")
      File.exist?(f) ? JSON.parse(File.read(f))["offset"] : nil
    end

    def save_offset(value)
      File.write(File.join(@dir, "offset.json"), { offset: value }.to_json)
    end

    private

    def read_jsonl(name)
      f = File.join(@dir, name)
      return [] unless File.exist?(f)

      File.readlines(f, encoding: "UTF-8").filter_map { |l| l.strip.empty? ? nil : JSON.parse(l) }
    end

    def append_jsonl(name, hash)
      File.open(File.join(@dir, name), "a", encoding: "UTF-8") { |io| io.puts(hash.to_json) }
    end
  end
end
