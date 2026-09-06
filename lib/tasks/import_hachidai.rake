# frozen_string_literal: true

# lib/tasks/import_hachidai.rake
#
# 八代集の残り 6集（拾遺・後拾遺・金葉・詞花・千載・新古今）を
# wakas テーブルに取り込む rake タスク集。
#
# ▼ URL マッピング（日文研 lapis.nichibun.ac.jp）
#   waka_i003  拾遺和歌集
#   waka_i004  後拾遺和歌集
#   waka_i005  金葉和歌集（初度本）  ※ i006=二度本 / i007=三奏本
#   waka_i008  詞花和歌集
#   waka_i009  千載和歌集
#   waka_i010  新古今和歌集  ← 最優先
#
# ▼ 実行例
#   bundle exec rails waka:import_shinkokkin          # 新古今のみ
#   bundle exec rails waka:import_shinkokkin LIMIT=5  # 5首だけ試験取り込み
#   bundle exec rails waka:import_hachidai            # 6集まとめて
#
# ▼ 冪等設計
#   (source, upper_phrase_yomi, lower_phrase_yomi) で find_or_initialize_by。
#   既存レコードは更新しない（追加のみ）。
#
# ▼ ページ構造（lapis.nichibun.ac.jp の waka_i0XX.html）
#   <table>
#     <tr>
#       <td>00001</td>
#       <td>良経 (091)  みよしのは−やまもかすみて−しらゆきの−ふりにしさとに−はるはきにけり</td>
#     </tr>
#     ...
#   </table>
#   ・5句を「−」で連結（ひらがな）
#   ・作者名 + (番号) が句の直前または別行
#   ・詞書がある場合は 1列行 or 同一セル内の先行行
#
# ▼ 既存タスクとの関係
#   import_kokin / import_gosen は lib/tasks/import_waka.rake にある。
#   このファイルは独立して追加。rake の namespace :waka を共有してよい。

require 'nokogiri'
require 'open-uri'

# ------------------------------------------------------------------
# 共通インポートロジック（Object メソッドとして定義）
# ------------------------------------------------------------------

# @param source  [String] DB に登録する出典名（例: '新古今集'）
# @param url     [String] 日文研の一覧ページURL
# @param era     [String] 時代区分文字列
# @param limit   [Integer, nil] nil=全件、数値=先頭N首で止める（テスト用）
def _waka_nichibun_import(source:, url:, era:, limit: nil)
  puts "【#{source}】開始 (#{url})"
  limit_count = limit ? limit.to_i : nil

  # ---------- フェッチ ----------
  html = begin
    URI.open(
      url,
      'User-Agent'  => 'Mozilla/5.0 (compatible; waka-collector-bot/1.0; +https://github.com/toghisumasu/waka-collector)',
      read_timeout: 120,
      open_timeout:  30
    ) { |f| f.read }
  rescue => e
    abort "フェッチ失敗 [#{source}]: #{e.class} #{e.message}"
  end

  doc = Nokogiri::HTML(html, nil, 'UTF-8')

  created       = 0
  skipped       = 0
  errors        = []
  current_notes = nil   # 直前の 1列行（詞書候補）を保持

  doc.css('table tr').each do |row|
    break if limit_count && (created + skipped) >= limit_count

    cells = row.css('td')

    # ─ 1列行：詞書・巻見出し・その他 ─
    if cells.size == 1
      txt = cells[0].text.strip
      # 数字のみ or 空 は無視
      current_notes = txt unless txt.empty? || txt =~ /\A[\d\s]+\z/
      next
    end

    next unless cells.size >= 2

    num_text  = cells[0].text.strip
    body_text = cells[1].text.strip

    # 番号列が数字（00001 など）でない行はスキップ（ヘッダ等）
    next unless num_text =~ /\A\d+\z/

    # ─ body_text を解析 ─
    # 期待フォーマット（1つの td 内）:
    #   作者名 (ID)\n句1−句2−句3−句4−句5\n異同資料句番号：XXXXX
    # 詞書がある場合は作者行の前に付く。
    author    = '作者未詳'
    waka_line = nil
    notes_buf = []

    body_text.each_line do |raw|
      line = raw.strip
      next if line.empty?
      next if line =~ /\A異同資料/   # "異同資料句番号：XXXXX" をスキップ

      if line.include?('−')
        # 「−」を含む → 和歌本文（5句連結）
        # ※詞書に「−」が含まれるケースは稀だが、句数チェックで後続処理が弾く
        waka_line = line
      elsif line =~ /\A(.+?)\s*\((\d+)\)\s*\z/
        # "作者名 (数字)" パターン → 作者行
        author = $1.strip.presence || '作者未詳'
      else
        notes_buf << line
      end
    end

    # 詞書の組み立て（直前の 1列行 + 同一セル内の非作者・非和歌行）
    notes = ([current_notes] + notes_buf).compact.reject(&:empty?).join('　').strip
    current_notes = nil   # 消費済みにリセット

    next if waka_line.nil?   # 和歌本文が見つからない行はスキップ

    # ─ 5句に分割 ─
    parts = waka_line.split('−').map(&:strip)
    unless parts.size == 5
      errors << "#{num_text}: 句数 #{parts.size}（期待値 5）→ #{waka_line[0, 50]}"
      next
    end

    upper_yomi = parts[0..2].join(' ')  # 五七五
    lower_yomi = parts[3..4].join(' ')  # 七七

    # ─ DB 登録 ─
    begin
      w = Waka.find_or_initialize_by(
        source:            source,
        upper_phrase_yomi: upper_yomi,
        lower_phrase_yomi: lower_yomi
      )

      if w.new_record?
        # よみのみで text も埋める（日文研はよみがな表記のみ提供）
        w.upper_phrase_text = upper_yomi
        w.lower_phrase_text = lower_yomi
        w.author            = author
        w.era               = era
        w.notes             = notes
        w.flag              = 0
        w.save!
        created += 1
        print '.' if (created % 100).zero?
      else
        skipped += 1
      end
    rescue ActiveRecord::RecordInvalid => e
      errors << "#{num_text}: 検証エラー #{e.message[0, 80]}"
    rescue => e
      errors << "#{num_text}: #{e.class} #{e.message[0, 80]}"
    end
  end

  puts '' unless created.zero?
  puts "【#{source}】完了: 新規 #{created} / スキップ #{skipped} / エラー #{errors.size}"
  errors.first(10).each { |msg| warn "  NG #{msg}" }
  warn "  ...（以下省略）" if errors.size > 10

  { source: source, created: created, skipped: skipped, errors: errors.size }
end

# ------------------------------------------------------------------
namespace :waka do
# ------------------------------------------------------------------

  desc '拾遺和歌集をwakas表に追加（冪等）'
  task import_shuui: :environment do
    _waka_nichibun_import(
      source: '拾遺集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i003.html',
      era:    '平安中期',
      limit:  ENV['LIMIT']
    )
  end

  desc '後拾遺和歌集をwakas表に追加（冪等）'
  task import_goshui: :environment do
    _waka_nichibun_import(
      source: '後拾遺集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i004.html',
      era:    '平安中期',
      limit:  ENV['LIMIT']
    )
  end

  desc '金葉和歌集（初度本）をwakas表に追加（冪等）'
  task import_kinyou: :environment do
    # 三奏本: waka_i007、二度本: waka_i006。
    # 連歌の本歌参照には初度本を採用。追加したい場合は source を変えて再実行可。
    _waka_nichibun_import(
      source: '金葉集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i005.html',
      era:    '平安中期',
      limit:  ENV['LIMIT']
    )
  end

  desc '詞花和歌集をwakas表に追加（冪等）'
  task import_shikka: :environment do
    _waka_nichibun_import(
      source: '詞花集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i008.html',
      era:    '平安中期',
      limit:  ENV['LIMIT']
    )
  end

  desc '千載和歌集をwakas表に追加（冪等）'
  task import_senzai: :environment do
    _waka_nichibun_import(
      source: '千載集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i009.html',
      era:    '平安末期',
      limit:  ENV['LIMIT']
    )
  end

  desc '【最優先】新古今和歌集をwakas表に追加（冪等）'
  task import_shinkokkin: :environment do
    _waka_nichibun_import(
      source: '新古今集',
      url:    'https://lapis.nichibun.ac.jp/waka/waka_i010.html',
      era:    '鎌倉初期',
      limit:  ENV['LIMIT']
    )
  end

  # ----------------------------------------------------------------
  desc '八代集残り6集を全てインポート（優先度順: 新古今→千載→詞花→金葉→後拾遺→拾遺）'
  task import_hachidai: :environment do
    collections = [
      { source: '新古今集',  url: 'https://lapis.nichibun.ac.jp/waka/waka_i010.html', era: '鎌倉初期'  },
      { source: '千載集',    url: 'https://lapis.nichibun.ac.jp/waka/waka_i009.html', era: '平安末期'  },
      { source: '詞花集',    url: 'https://lapis.nichibun.ac.jp/waka/waka_i008.html', era: '平安中期'  },
      { source: '金葉集',    url: 'https://lapis.nichibun.ac.jp/waka/waka_i005.html', era: '平安中期'  },
      { source: '後拾遺集',  url: 'https://lapis.nichibun.ac.jp/waka/waka_i004.html', era: '平安中期'  },
      { source: '拾遺集',    url: 'https://lapis.nichibun.ac.jp/waka/waka_i003.html', era: '平安初中期' },
    ]

    results = []
    collections.each_with_index do |col, i|
      sleep 3 if i > 0   # サーバー負荷対策（3秒インターバル）
      results << _waka_nichibun_import(**col)
    end

    puts "\n" + ('=' * 40)
    puts '八代集インポート集計'
    puts '=' * 40
    total_new = 0
    results.each do |r|
      printf "  %-10s  新規 %5d  スキップ %5d  エラー %d\n",
             r[:source], r[:created], r[:skipped], r[:errors]
      total_new += r[:created]
    end
    puts '-' * 40
    puts "  合計新規: #{total_new} 首"
    puts '=' * 40

    # 取り込み後の件数確認 SQL
    puts "\n-- DB 確認 --"
    puts Waka.group(:source).count.sort_by { |_, v| -v }.map { |s, c| "  #{s}: #{c}" }.join("\n")
  end

# ------------------------------------------------------------------
end
