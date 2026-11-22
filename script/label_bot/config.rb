# frozen_string_literal: true

require "json"
require "time"

# 手ラベル配信・回収 Bot の設定。
# トークンと chat_id は環境変数 LABEL_BOT_TOKEN / LABEL_BOT_CHAT_ID で受け取る。
# launchd はシェルの環境変数を引き継がないため、LABEL_BOT_ENV_FILE で
# リポジトリ外の権限 0600 のファイル（KEY=VALUE 形式）を指せる。
# トークンはどこにも出力しない（ログ・例外メッセージにも含めない）。
module LabelBot
  class ConfigError < StandardError; end

  JST_OFFSET = "+09:00"

  module Config
    DEFAULT_DIR = File.expand_path("../../tmp/gendai", __dir__)

    module_function

    # 環境ファイルを読み、未設定のキーだけ ENV に入れる。
    # group/other に権限があるファイルは拒否する（トークン保護）。
    def load_env_file!(path = ENV["LABEL_BOT_ENV_FILE"])
      return if path.nil? || path.strip.empty?

      path = File.expand_path(path)
      raise ConfigError, "LABEL_BOT_ENV_FILE のファイルが見つかりません: #{path}" unless File.file?(path)

      mode = File.stat(path).mode & 0o777
      raise ConfigError, "環境ファイルの権限が #{format('%04o', mode)} です。0600 にしてください: #{path}" if (mode & 0o077) != 0

      File.readlines(path, encoding: "UTF-8").each do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        line = line.sub(/\Aexport\s+/, "")
        key, value = line.split("=", 2)
        next if key.nil? || value.nil?

        value = value.strip.sub(/\A(["'])(.*)\1\z/, '\2')
        ENV[key.strip] = value if ENV[key.strip].to_s.empty?
      end
    end

    def token
      v = ENV["LABEL_BOT_TOKEN"].to_s.strip
      raise ConfigError, "LABEL_BOT_TOKEN が未設定です" if v.empty?

      v
    end

    def chat_id
      v = ENV["LABEL_BOT_CHAT_ID"].to_s.strip
      raise ConfigError, "LABEL_BOT_CHAT_ID が未設定です" if v.empty?

      v
    end

    def data_dir
      d = ENV["LABEL_BOT_DIR"].to_s.strip
      d.empty? ? DEFAULT_DIR : File.expand_path(d)
    end

    # 日本時間の現在時刻（launchd 側の TZ に依存しない）
    def now_jst
      Time.now.getlocal(JST_OFFSET)
    end
  end
end
