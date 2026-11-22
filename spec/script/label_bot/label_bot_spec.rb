# frozen_string_literal: true

require "tmpdir"
require "stringio"
require "csv"
require_relative "../../../script/label_bot/telegram_api"
require_relative "../../../script/label_bot/sender"
require_relative "../../../script/label_bot/poller"
require_relative "../../../script/label_bot/whoami"

# ダミーデータ（無意味な句）だけを使う。実データ・DB・ネットワークには触れない。
RSpec.describe "LabelBot" do
  # 送信内容を記録するだけの偽 API
  class FakeApi
    attr_reader :sent, :answers, :edits

    def initialize
      @sent = []
      @answers = []
      @edits = []
      @updates = []
    end

    def send_message(chat_id:, text:, reply_markup: nil)
      @sent << { chat_id: chat_id, text: text, reply_markup: reply_markup }
    end

    def answer_callback(callback_query_id:, text: nil)
      @answers << callback_query_id
    end

    def edit_reply_markup(chat_id:, message_id:, reply_markup:)
      @edits << { chat_id: chat_id, message_id: message_id, reply_markup: reply_markup }
    end

    def queue(*updates) = @updates.concat(updates)

    def get_updates(offset: nil, timeout: 50)
      @updates.shift(@updates.size)
    end
  end

  let(:dir) { Dir.mktmpdir("label_bot_spec") }
  let!(:store) { LabelBot::Store.new(dir) }
  let(:api) { FakeApi.new }
  let(:out) { StringIO.new }
  let(:chat) { 4242 }
  let(:day1) { Time.new(2026, 11, 23, 7, 30, 0, "+09:00") }
  let(:day2) { Time.new(2026, 11, 24, 7, 30, 0, "+09:00") }

  after { FileUtils.remove_entry(dir) }

  def write_batch(n, count: 20)
    items = (1..count).map { |i| { "id" => "d#{n}x#{i.to_s.rjust(2, '0')}", "form" => i.odd? ? "長句" : "短句", "text" => "テスト句#{n}-#{i}" } }
    File.write(File.join(dir, "batches", "day#{n}.json"), JSON.generate(items))
    items
  end

  def sender = LabelBot::Sender.new(store: store, api: api, chat_id: chat, out: out)
  def poller = LabelBot::Poller.new(store: store, api: api, chat_id: chat, out: out)

  def press(callback_data, chat_id: chat, id: "cq1")
    { "update_id" => 1, "callback_query" => { "id" => id, "data" => callback_data,
                                              "message" => { "message_id" => 9, "chat" => { "id" => chat_id } } } }
  end

  def label_lines
    File.exist?(File.join(dir, "labels.jsonl")) ? File.readlines(File.join(dir, "labels.jsonl")).map { |l| JSON.parse(l) } : []
  end

  describe LabelBot::Keyboard do
    it "callback_data を解析し、不正なものは nil にする" do
      expect(described_class.parse("v|abc123|y")).to eq([ "value", "abc123", "描ける" ])
      expect(described_class.parse("t|abc123|g")).to eq([ "tag", "abc123", "文法・意味" ])
      expect(described_class.parse("v|abc123|z")).to be_nil
      expect(described_class.parse("x|abc123|y")).to be_nil
      expect(described_class.parse("v|a b|y")).to be_nil
    end

    it "付いている値・タグを ✓ で表示する" do
      kb = described_class.markup("abc", value: "描けない", tags: [ "言葉" ])
      texts = kb[:inline_keyboard].map { |row| row.map { |b| b[:text] } }
      expect(texts).to eq([ [ "描ける", "✓ 描けない" ], [ "文法・意味", "✓ 言葉", "その他" ] ])
      expect(kb[:inline_keyboard].flatten.map { |b| b[:callback_data].bytesize }.max).to be <= 64
    end
  end

  describe LabelBot::Config do
    let(:env_file) { File.join(dir, "env") }

    around do |ex|
      saved = ENV.to_h.slice("LABEL_BOT_TOKEN", "LABEL_BOT_CHAT_ID")
      ENV.delete("LABEL_BOT_TOKEN")
      ENV.delete("LABEL_BOT_CHAT_ID")
      ex.run
      ENV.delete("LABEL_BOT_TOKEN")
      ENV.delete("LABEL_BOT_CHAT_ID")
      saved.each { |k, v| ENV[k] = v }
    end

    it "権限 0600 の環境ファイルから読む" do
      File.write(env_file, "# c\nLABEL_BOT_TOKEN=dummy-token\nexport LABEL_BOT_CHAT_ID=\"4242\"\n")
      File.chmod(0o600, env_file)
      described_class.load_env_file!(env_file)
      expect(described_class.token).to eq("dummy-token")
      expect(described_class.chat_id).to eq("4242")
    end

    it "権限が緩いファイルは拒否し、エラー文にトークンを含めない" do
      File.write(env_file, "LABEL_BOT_TOKEN=secret-dummy\n")
      File.chmod(0o644, env_file)
      expect { described_class.load_env_file!(env_file) }
        .to raise_error(LabelBot::ConfigError) { |e| expect(e.message).not_to include("secret-dummy") }
    end

    it "トークン未設定は ConfigError" do
      expect { described_class.token }.to raise_error(LabelBot::ConfigError)
    end
  end

  describe LabelBot::TelegramApi do
    it "通信エラーの文面にトークンを含めない" do
      client = described_class.new(token: "SECRET-DUMMY-TOKEN", base: "http://127.0.0.1:1")
      expect { client.send_message(chat_id: 1, text: "x") }
        .to raise_error(LabelBot::TelegramApi::Error) { |e| expect(e.message).not_to include("SECRET-DUMMY-TOKEN") }
    end
  end

  describe LabelBot::Sender do
    before { write_batch(1) && write_batch(2) }

    it "1 日目を 1 句 1 メッセージ（ボタン付き）で送り、sent.jsonl に記録する" do
      expect(sender.run(day1)).to eq(:sent)
      expect(api.sent.size).to eq(20)
      expect(api.sent.first[:text]).to eq("1/20 【長句】テスト句1-1")
      expect(api.sent[1][:text]).to start_with("2/20 【短句】")
      expect(api.sent.first[:reply_markup][:inline_keyboard].size).to eq(2)
      expect(store.sent_entries.map { |e| [ e["kind"], e["batch"], e["date"] ] }).to eq([ [ "batch", 1, "2026-11-23" ] ])
    end

    it "同じ日に 2 回実行しても二重に送らない" do
      sender.run(day1)
      api.sent.clear
      expect(sender.run(day1 + 3600)).to eq(:skipped_same_day)
      expect(api.sent).to be_empty
    end

    it "前の batch が未完了なら、次の batch を送らずリマインダーだけ送る" do
      sender.run(day1)
      api.sent.clear
      expect(sender.run(day2)).to eq(:reminded)
      expect(api.sent.size).to eq(1)
      expect(api.sent.first[:text]).to include("残り 20 件")
      expect(api.sent.first[:reply_markup]).to be_nil
      expect(store.sent_batch_numbers).to eq([ 1 ])
    end

    it "前の batch が完了していれば、翌日に次の batch を送る" do
      sender.run(day1)
      store.batch_items(1).each { |it| store.append_label(batch: 1, item_id: it["id"], field: "value", value: "描ける", action: "set") }
      api.sent.clear
      expect(sender.run(day2)).to eq(:sent)
      expect(api.sent.first[:text]).to eq("1/20 【長句】テスト句2-1")
      expect(store.sent_batch_numbers).to eq([ 1, 2 ])
    end

    context "送信が途中で失敗したとき" do
      # n 件目の送信で失敗する偽 API（それまでに n-1 件が届く）
      def fail_at(nth)
        count = 0
        allow(api).to receive(:send_message).and_wrap_original do |orig, **kw|
          count += 1
          raise LabelBot::TelegramApi::Error, "boom" if count == nth

          orig.call(**kw)
        end
      end

      it "送れた件数を batch_partial に記録する" do
        fail_at(8)
        expect { sender.run(day1) }.to raise_error(LabelBot::TelegramApi::Error)
        expect(store.sent_entries.map { |e| e["kind"] }).to eq(%w[batch batch_partial])
        expect(store.pending_partial).to eq({ batch: 1, sent: 7, count: 20 })
      end

      it "次の実行で未送信の句だけを送り直し、結果を sent.jsonl に残す（同日でも）" do
        fail_at(8)
        expect { sender.run(day1) }.to raise_error(LabelBot::TelegramApi::Error)
        allow(api).to receive(:send_message).and_call_original
        api.sent.clear

        expect(sender.run(day1 + 600)).to eq(:resumed)
        expect(api.sent.size).to eq(13)
        expect(api.sent.first[:text]).to eq("8/20 【短句】テスト句1-8")
        expect(api.sent.last[:text]).to start_with("20/20")
        expect(store.sent_entries.map { |e| e["kind"] }).to eq(%w[batch batch_partial batch_resume batch_resumed])
        expect(store.sent_entries[2]).to include("from" => 7, "count" => 20)
        expect(store.sent_entries.last).to include("sent" => 20)
        expect(store.pending_partial).to be_nil
      end

      it "送り直しでさらに失敗したら、そこまでの件数を記録し、次の実行で続きから送る" do
        fail_at(8)
        expect { sender.run(day1) }.to raise_error(LabelBot::TelegramApi::Error)
        fail_at(4) # 送り直しの 4 件目（全体の 11 件目）で失敗
        expect { sender.run(day1 + 600) }.to raise_error(LabelBot::TelegramApi::Error)
        expect(store.pending_partial).to eq({ batch: 1, sent: 10, count: 20 })

        allow(api).to receive(:send_message).and_call_original
        api.sent.clear
        expect(sender.run(day2)).to eq(:resumed)
        expect(api.sent.first[:text]).to eq("11/20 【長句】テスト句1-11")
        expect(api.sent.size).to eq(10)
      end

      it "全件送れた後は通常のゲートに戻る（同日は送らず、翌日は未完了ならリマインダーのみ）" do
        fail_at(8)
        expect { sender.run(day1) }.to raise_error(LabelBot::TelegramApi::Error)
        allow(api).to receive(:send_message).and_call_original
        sender.run(day1 + 600)
        api.sent.clear

        expect(sender.run(day1 + 1200)).to eq(:skipped_same_day)
        expect(sender.run(day2)).to eq(:reminded)
        expect(api.sent.size).to eq(1)
        expect(store.sent_batch_numbers).to eq([ 1 ])
      end

      it "送り直しの途中でも、次の batch は送らない（2 日目は送り直しが先）" do
        fail_at(1)
        expect { sender.run(day1) }.to raise_error(LabelBot::TelegramApi::Error)
        allow(api).to receive(:send_message).and_call_original
        api.sent.clear
        expect(sender.run(day2)).to eq(:resumed)
        expect(api.sent.size).to eq(20)
        expect(api.sent.first[:text]).to start_with("1/20")
        expect(store.sent_batch_numbers).to eq([ 1 ])
      end
    end

    it "配信する batch がなければ何も送らない" do
      FileUtils.rm_f(Dir.glob(File.join(dir, "batches", "*.json")))
      expect(sender.run(day1)).to eq(:no_batches)
      expect(api.sent).to be_empty
    end
  end

  describe LabelBot::Poller do
    before do
      write_batch(1)
      sender.run(day1)
      api.sent.clear
    end

    it "値を保存し、押し直しは新しい行として追記する" do
      poller.handle(press("v|d1x01|y"))
      poller.handle(press("v|d1x01|n"))
      lines = label_lines
      expect(lines.size).to eq(2)
      expect(lines.map { |l| [ l["batch"], l["item_id"], l["field"], l["value"], l["action"] ] })
        .to eq([ [ 1, "d1x01", "value", "描ける", "set" ], [ 1, "d1x01", "value", "描けない", "set" ] ])
      expect(store.current_state["d1x01"][:value]).to eq("描けない")
      expect(api.edits.last[:reply_markup][:inline_keyboard][0].map { |b| b[:text] }).to eq([ "描ける", "✓ 描けない" ])
    end

    it "タグは押すごとに付く／外れる" do
      poller.handle(press("t|d1x02|g"))
      poller.handle(press("t|d1x02|w"))
      poller.handle(press("t|d1x02|g"))
      expect(label_lines.map { |l| l["action"] }).to eq(%w[add add remove])
      expect(store.current_state["d1x02"][:tags]).to eq([ "言葉" ])
    end

    it "labels.csv に ID・値・タグ・メモ・最終更新を書き出す" do
      poller.handle(press("v|d1x01|y"))
      poller.handle(press("t|d1x01|g"))
      poller.handle(press("t|d1x01|o"))
      poller.handle({ "update_id" => 2, "message" => { "chat" => { "id" => chat }, "text" => "/memo 1 テストのメモ" } })
      rows = CSV.read(File.join(dir, "labels.csv"), headers: true)
      expect(rows.headers).to eq(%w[ID 値 タグ メモ 最終更新])
      expect(rows.size).to eq(20)
      r = rows.find { |x| x["ID"] == "d1x01" }
      expect([ r["値"], r["タグ"], r["メモ"] ]).to eq([ "描ける", "文法・意味|その他", "テストのメモ" ])
      expect(r["最終更新"]).not_to be_nil
      expect(rows.find { |x| x["ID"] == "d1x03" }["値"]).to be_nil
    end

    it "許可していない chat_id の更新は無視し、何も保存・返信しない" do
      expect(poller.handle(press("v|d1x01|y", chat_id: 999))).to eq(:ignored)
      expect(poller.handle({ "update_id" => 3, "message" => { "chat" => { "id" => 999 }, "text" => "/memo 1 x" } })).to eq(:ignored)
      expect(label_lines).to be_empty
      expect(api.sent).to be_empty
      expect(api.answers).to be_empty
      expect(out.string).to include("無視")
      expect(out.string).not_to include("/memo")
    end

    it "配信していない句や不正な操作は保存しない" do
      expect(poller.handle(press("v|nosuch|y"))).to eq(:unknown)
      expect(poller.handle(press("v|d1x01|zzz"))).to eq(:unknown)
      expect(label_lines).to be_empty
    end

    it "20 件すべてに値が入ったら『N日目 完了』を 1 回だけ送る" do
      store.batch_items(1).each_with_index { |it, i| poller.handle(press("v|#{it['id']}|y", id: "c#{i}")) }
      expect(api.sent.map { |m| m[:text] }).to eq([ "1日目 完了" ])
      poller.handle(press("v|d1x01|n"))
      expect(api.sent.size).to eq(1)
    end

    it "poll_once は更新を処理し、offset を保存する" do
      api.queue(press("v|d1x01|y").merge("update_id" => 77))
      expect(poller.poll_once).to eq(1)
      expect(store.offset).to eq(78)
      expect(store.current_state["d1x01"][:value]).to eq("描ける")
    end

    it "範囲外のメモ番号は保存せず知らせる" do
      poller.handle({ "update_id" => 4, "message" => { "chat" => { "id" => chat }, "text" => "/memo 21 x" } })
      expect(label_lines).to be_empty
      expect(api.sent.last[:text]).to include("21")
    end
  end

  describe "LabelBot::Whoami" do
    def msg_update(id, chat_id) = { "update_id" => id, "message" => { "chat" => { "id" => chat_id }, "text" => "hi" } }

    it "最後のメッセージの chat_id を返す" do
      updates = [ msg_update(1, 111), msg_update(2, 222) ]
      expect(LabelBot::Whoami.last_chat_id(updates)).to eq(222)
    end

    it "ボタン操作の更新からも取れる。メッセージがなければ nil" do
      cq = { "update_id" => 3, "callback_query" => { "message" => { "chat" => { "id" => 333 } } } }
      expect(LabelBot::Whoami.last_chat_id([ msg_update(1, 111), cq ])).to eq(333)
      expect(LabelBot::Whoami.last_chat_id([ { "update_id" => 4, "my_chat_member" => {} } ])).to be_nil
      expect(LabelBot::Whoami.last_chat_id([])).to be_nil
    end
  end
end
