require 'open-uri'
require 'nokogiri'

namespace :waka do
  desc '日文研から古今集の和歌をインポートする'
  task import_kokin: :environment do
    url = 'https://lapis.nichibun.ac.jp/waka/waka_i001.html'
    puts "既存の古今集データを削除中..."
    Waka.where(source: '古今集').delete_all

    puts "#{url} を取得中..."
    doc = Nokogiri::HTML(URI.open(url))

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

      # 上の句・下の句を分割（読み仮名）
      phrases = yomigana.split('−')
      next if phrases.length != 5

      upper_yomi = phrases[0..2].join(' ')
      lower_yomi = phrases[3..4].join(' ')

      # 本文から上の句・下の句を分割
      # 読み仮名の文字数比率で本文を分割
      upper_len = phrases[0..2].join.length
      total_len = phrases.join.length
      split_pos = (honbun.length * upper_len / total_len.to_f).round
      upper_text = honbun[0...split_pos]
      lower_text = honbun[split_pos..]

      Waka.create!(
        upper_phrase_text: upper_text,
        lower_phrase_text: lower_text,
        upper_phrase_yomi: upper_yomi,
        lower_phrase_yomi: lower_yomi,
        author: author,
        source: '古今集',
        era: '平安',
        notes: chokusho
      )
      count += 1
      print '.'

      sleep 0.5
    end

    puts "\n#{count}件インポートしました"
  end
end
