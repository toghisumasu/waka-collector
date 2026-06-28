# frozen_string_literal: true
class RengaChecker
  def initialize(sentences)
    @sentences = sentences
  end

  def check
    raw = OllamaClient.generate(build_prompt)
    json = raw.match(/\{.*\}/m)&.to_s
    parsed = JSON.parse(json)
    {
      "result"    => parsed["result"],
      "issues"    => Array(parsed["issues"]),
      "breakdown" => Array(parsed["breakdown"])
    }
  rescue JSON::ParserError, TypeError
    { "result" => "unknown", "issues" => ["式目チェックの解析に失敗しました"], "breakdown" => [] }
  end

  private

  def build_prompt
    list = @sentences.each_with_index
                     .map { |s, i| "#{i + 1}. #{s}" }.join("\n")
    <<~PROMPT
      あなたは連歌の執筆（しっぴつ）役です。
      下の【チェック項目】だけを確認してください。
      ここに書かれていないルールは適用しないこと。句の良し悪しも評価しません。

      【季語の所属（迷ったら下に従う）】
      - 春：霞・梅・柳・桜　／　秋：霧・月・紅葉　／　冬：雪・霜
      - 同じ句に春と冬が混在していても、それ自体は違反としない。

      【句数（同じ季を続けてよい句数）】
      - 春・秋：3〜5句（始めたら最低3句、6句目以降は違反）
      - 夏・冬・恋・旅：3句まで
      - ★末尾の句で同じ季がまだ続いている場合は途中経過とみなし、句数不足の違反を出さないこと。
        句数不足は「同じ季が規定句数未満で別の季に切り替わった」ときにのみ判定する。

      【句去（一度出た語を再び出すまでに空ける句数）】
      - 月・日、雨・雪・露・霜、霞・霧・雲・煙、名所：間に3句空ける
      - 山、水辺（川・舟・水）、夜、恋、旅、風：間に5句空ける
      上記より近い間隔で同類が再登場したら違反。

      【検査対象（古い順・上から下へ流れる）】
      #{list}

      以下のJSON形式のみで返答（前後に説明文を付けない）。
      breakdownは各句を「句 → 季・種類」の形式で入れる。
      {"result": "okまたはng", "issues": ["違反内容。無ければ空配列"], "breakdown": ["各句の分析"]}
    PROMPT
  end
end
