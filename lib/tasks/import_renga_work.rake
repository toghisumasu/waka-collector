require "csv"
namespace :renga do
  # bin/rails "renga:import_csv[yuyama_sangin,湯山三吟百韻,yugama,三吟,tmp/yuyama_sangin_verses.csv]"
  desc "百韻CSVを renga_works / renga_work_verses に取り込む(再実行可)"
  task :import_csv, [:slug, :title, :style, :form, :path] => :environment do |_, a|
    work = RengaWork.find_or_initialize_by(slug: a[:slug])
    work.update!(title: a[:title], style: a[:style], form: a[:form],
                 source: "去嫌一覧(紀要)からの転記", data_status: "draft")
    arr = ->(s) { s.to_s.delete("{}").split(",") }
    n = 0
    CSV.foreach(a[:path], headers: true, encoding: "bom|utf-8") do |r|
      v = work.renga_work_verses.find_or_initialize_by(verse_no: r["verse_no"].to_i)
      v.update!(fold: r["fold"], kind: r["kind"], author: r["author"], text: r["text"],
                reading: r["reading"], season: r["season"],
                bui_list: arr.(r["bui_list"]), bui_weak_list: arr.(r["bui_weak_list"]),
                nana_list: arr.(r["nana_list"]), other_cats: arr.(r["other_cats"]),
                kyoken_tokens: r["kyoken_tokens"])
      n += 1
    end
    puts "#{work.title}: #{n}句 取込"
  end
end
