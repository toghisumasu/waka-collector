require 'open-uri'
require 'nokogiri'

namespace :waka do
  desc '日文研から古今集の和歌をインポートする'
  task import_kokin: :environment do
    url = 'https://lapis.nichibun.ac.jp/waka/waka_i001.html'
    puts "#{url} を取得中..."
    doc = Nokogiri::HTML(URI.open(url))

    # 3番目以降のテーブルが和歌データ
    tables = doc.css('table')[3..]
    count = 0

    tables.each do |table|
      td = table.css('td')[1]
      next if td.nil?

      # 詞書
      chokusho = td.css('div[align="left"]').first&.text&.strip
      chokusho = chokusho&.gsub(/^\[詞書\]\s*/, '')

      # 作者
      author_text = td.css('div[align="right"]').first&.text&.strip
      author = author_text&.gsub(/\(\d+\)/, '')&.split('　')[1]&.strip

      # 本文と読み仮名
      honbun_div = td.css('div[align="left"]')[1]
      next if honbun_div.nil?

      texts = honbun_div.text.strip.split("\n").map(&:strip).reject(&:empty?)
      next if texts.length < 2

      honbun   = texts[0]
      yomigana = texts[1]

      # 上の句・下の句を分割
      phrases = yomigana.split('−')
      next if phrases.length != 5

      upper_phrase = phrases[0..2].join(' ')
      lower_phrase = phrases[3..4].join(' ')

      # DBに保存（重複チェック）
      unless Waka.exists?(upper_phrase: upper_phrase, lower_phrase: lower_phrase)
        Waka.create!(
          upper_phrase: upper_phrase,
          lower_phrase: lower_phrase,
          author: author,
          source: '古今集',
          era: '平安',
          notes: chokusho
        )
        count += 1
        print '.'
      end

      sleep 0.5
    end

    puts "\n#{count}件インポートしました"
  end
end
