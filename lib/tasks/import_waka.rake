require 'open-uri'
require 'nokogiri'

namespace :waka do

  def split_honbun(honbun, upper_yomi, lower_yomi)
    upper_kana = upper_yomi.gsub(' ', '')
    lower_kana = lower_yomi.gsub(' ', '')
    search_text = upper_kana + lower_kana
    flag_note = false
    kanji_pat = /[^\u3040-\u309f\u30a0-\u30ff\u0000-\u007f]/

    if honbun =~ /\A[ぁ-んー]+\z/
      return [honbun[0...upper_kana.length], honbun[upper_kana.length..], false]
    end

    kana_parts = honbun.scan(/[ぁ-ん]+/)
    search_pos = 0
    honbun_pos = 0
    split_honbun_pos = nil

    kana_parts.each do |part|
      found = search_text.index(part, search_pos)
      break unless found
      next_pos = found + part.length
      honbun_part_pos = honbun.index(part, honbun_pos)
      break unless honbun_part_pos

      if next_pos >= upper_kana.length
        if found >= upper_kana.length
          split_honbun_pos = honbun_part_pos
        else
          chars_in_upper = upper_kana.length - found
          split_honbun_pos = honbun_part_pos + chars_in_upper
        end
        break
      end

      search_pos = next_pos
      honbun_pos = honbun_part_pos + part.length
    end

    unless split_honbun_pos
      total_len = upper_kana.length + lower_kana.length
      split_honbun_pos = (honbun.length * upper_kana.length / total_len.to_f).round
      flag_note = true
    end

    upper_text = honbun[0...split_honbun_pos]
    kanji_tail = upper_text.match(/#{kanji_pat}+$/)&.to_s
    flag_note = true if kanji_tail && kanji_tail.length >= 5

    [honbun[0...split_honbun_pos], honbun[split_honbun_pos..], flag_note]
  end

  def import_from_nichibun(url:, source:, era:)
    puts "既存の#{source}データを削除中..."
    Waka.where(source: source).delete_all
    puts "#{url} を取得中..."
    doc = Nokogiri::HTML(URI.open(url))
    tables = doc.css('table')[3..]
    count = 0
    noted = 0

    tables.each do |table|
      td = table.css('td')[1]
      next if td.nil?
      chokusho = td.css('div[align="left"]').first&.text&.strip
      chokusho = chokusho&.gsub(/^\[詞書\]\s*/, '')
      author_text = td.css('div[align="right"]').first&.text&.strip
      author = author_text&.gsub(/\(\d+\)/, '')&.split('　')[1]&.strip
      honbun_div = td.css('div[align="left"]')[1]
      next if honbun_div.nil?
      texts = honbun_div.text.strip.split("\n").map(&:strip).reject(&:empty?)
      next if texts.length < 2
      honbun   = texts[0]
      yomigana = texts[1]
      phrases = yomigana.split('−')
      next if phrases.length != 5
      upper_yomi = phrases[0..2].join(' ')
      lower_yomi = phrases[3..4].join(' ')
      upper_text, lower_text, flag_note = split_honbun(honbun, upper_yomi, lower_yomi)
      Waka.create!(
        upper_phrase_text: upper_text,
        lower_phrase_text: lower_text,
        upper_phrase_yomi: upper_yomi,
        lower_phrase_yomi: lower_yomi,
        author: author,
        source: source,
        era: era,
        notes: chokusho,
        flag: flag_note ? 1 : 0
      )
      count += 1
      noted += 1 if flag_note
      print '.'
      sleep 0.5
    end
    puts "\n#{count}件インポートしました（注フラグ: #{noted}件）"
  end

  desc '日文研から古今集の和歌をインポートする'
  task import_kokin: :environment do
    import_from_nichibun(
      url: 'https://lapis.nichibun.ac.jp/waka/waka_i001.html',
      source: '古今集',
      era: '平安'
    )
  end

  desc '日文研から後撰集の和歌をインポートする'
  task import_gosen: :environment do
    import_from_nichibun(
      url: 'https://lapis.nichibun.ac.jp/waka/waka_i002.html',
      source: '後撰集',
      era: '平安'
    )
  end

end
