require "rails_helper"

RSpec.describe OllamaClient do
  let(:http) { instance_double(Net::HTTP) }

  before do
    allow(Net::HTTP).to receive(:new).and_return(http)
    allow(http).to receive(:open_timeout=)
    allow(http).to receive(:read_timeout=)
  end

  def success_response(body)
    res = instance_double(Net::HTTPOK, code: "200", body: body)
    allow(res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    res
  end

  def error_response(code)
    res = instance_double(Net::HTTPServerError, code: code, body: "")
    allow(res).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
    res
  end

  describe ".generate" do
    it "returns response text on 200" do
      allow(http).to receive(:request).and_return(success_response({ response: "つきのかたむく" }.to_json))
      expect(described_class.generate("prompt")).to eq("つきのかたむく")
    end

    it "raises when Ollama responds with a non-2xx status (其の四十 T2)" do
      allow(http).to receive(:request).and_return(error_response("500"))
      expect { described_class.generate("prompt") }.to raise_error(RuntimeError, /HTTP 500/)
    end

    describe "temperature の配置（M-7a。其の四十 T3 の body 直下指定は無効と判明したため置換）" do
      def capture_body
        sent = nil
        allow(http).to receive(:request) do |req|
          sent = JSON.parse(req.body)
          success_response({ response: "ok" }.to_json)
        end
        yield
        sent
      end

      around do |ex|
        saved = ENV["WAKA_OLLAMA_TEMPERATURE"]
        begin
          ex.run
        ensure
          saved.nil? ? ENV.delete("WAKA_OLLAMA_TEMPERATURE") : ENV["WAKA_OLLAMA_TEMPERATURE"] = saved
        end
      end

      it "body 直下に temperature を置かない（引数を渡しても）" do
        ENV.delete("WAKA_OLLAMA_TEMPERATURE")
        sent = capture_body { described_class.generate("prompt", temperature: 0.8) }
        expect(sent).not_to have_key("temperature")
      end

      it "環境変数未指定のとき options に temperature がない（既存 options は維持）" do
        ENV.delete("WAKA_OLLAMA_TEMPERATURE")
        sent = capture_body { described_class.generate("prompt", temperature: 0.8) }
        expect(sent["options"]).not_to have_key("temperature")
        expect(sent["options"]).to include("num_predict" => 4000, "repeat_penalty" => 1.15)
      end

      it "環境変数指定のとき options.temperature がその値になり、ログに残る" do
        ENV["WAKA_OLLAMA_TEMPERATURE"] = "0.3"
        allow(Rails.logger).to receive(:info)
        sent = capture_body { described_class.generate("prompt", temperature: 0.8) }
        expect(sent["options"]["temperature"]).to eq(0.3)
        expect(sent).not_to have_key("temperature")
        expect(Rails.logger).to have_received(:info).with(/WAKA_OLLAMA_TEMPERATURE=0\.3/)
      end

      it "環境変数が数値でないとき ConfigError（接続エラーに包まない）" do
        ENV["WAKA_OLLAMA_TEMPERATURE"] = "abc"
        expect { described_class.generate("prompt") }
          .to raise_error(OllamaClient::ConfigError, /WAKA_OLLAMA_TEMPERATURE/)
      end
    end
  end

  describe ".chat" do
    it "returns message content on 200" do
      allow(http).to receive(:request).and_return(success_response({ message: { content: "こたえ" } }.to_json))
      expect(described_class.chat([{ role: "user", content: "hi" }])).to eq("こたえ")
    end

    it "raises when Ollama responds with a non-2xx status (其の四十 T2)" do
      allow(http).to receive(:request).and_return(error_response("500"))
      expect { described_class.chat([{ role: "user", content: "hi" }]) }.to raise_error(RuntimeError, /HTTP 500/)
    end
  end

  describe ".chat_with_tools" do
    it "raises when Ollama responds with a non-2xx status (其の四十 T2)" do
      allow(http).to receive(:request).and_return(error_response("500"))
      expect do
        described_class.chat_with_tools([{ role: "user", content: "hi" }], tools: []) { |_n, _a| {} }
      end.to raise_error(RuntimeError, /HTTP 500/)
    end
  end

  # 其の四十 T4: chat/chat_with_toolsのrescue => e（StandardError全体を捕捉し
  # "Ollama接続エラー: <元メッセージ>" というRuntimeErrorへ正規化する挙動）を
  # 変更前に固定するcharacterization test。T4はこの正規化の挙動自体は変えず、
  # re-raise前に元の例外クラス・バックトレースをログへ残すことのみを追加する。
  describe "rescue正規化のふるまい（T4着手前の固定・T4着手後も不変）" do
    it "generate: StandardErrorはOllama接続エラーというRuntimeErrorに正規化される" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect { described_class.generate("prompt") }
        .to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end

    it "chat: StandardErrorはOllama接続エラーというRuntimeErrorに正規化される" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect { described_class.chat([{ role: "user", content: "hi" }]) }
        .to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end

    it "chat_with_tools: StandardErrorはOllama接続エラーというRuntimeErrorに正規化される" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect do
        described_class.chat_with_tools([{ role: "user", content: "hi" }], tools: []) { |_n, _a| {} }
      end.to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end

    it "generate: Net::ReadTimeoutは専用メッセージのRuntimeErrorに正規化される" do
      allow(http).to receive(:request).and_raise(Net::ReadTimeout)
      expect { described_class.generate("prompt", timeout: 42) }
        .to raise_error(RuntimeError, "メンタムさんへの接続がタイムアウトしました（42秒）")
    end
  end

  # 其の四十 T4: chat/chat_with_toolsはre-raise前に元の例外クラス・
  # バックトレースをRails.loggerへ記録する（挙動＝例外クラス/メッセージは不変）
  describe "T4: rescue時のログ記録" do
    it "chatは元の例外クラス・メッセージをログに残してからRuntimeErrorをraiseする" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect(Rails.logger).to receive(:error).with(/SocketError: getaddrinfo failed/)
      expect { described_class.chat([{ role: "user", content: "hi" }]) }
        .to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end

    it "chat_with_toolsは元の例外クラス・メッセージをログに残してからRuntimeErrorをraiseする" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect(Rails.logger).to receive(:error).with(/SocketError: getaddrinfo failed/)
      expect do
        described_class.chat_with_tools([{ role: "user", content: "hi" }], tools: []) { |_n, _a| {} }
      end.to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end

    it "generateはログを追加しない（T4のスコープ外・既存挙動を維持）" do
      allow(http).to receive(:request).and_raise(SocketError, "getaddrinfo failed")
      expect(Rails.logger).not_to receive(:error)
      expect { described_class.generate("prompt") }
        .to raise_error(RuntimeError, "Ollama接続エラー: getaddrinfo failed")
    end
  end
end
