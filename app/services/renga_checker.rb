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

      【字数は音（モーラ）で数える】
      まず各句を古語のよみのまま、ひらがなに直す（現代語に変換しない）。
      - 「にほふ」＝に・ほ・ふ（3音）、「夜」＝よ（1音）、「けふ」＝け・ふ（2音）
      - 拗音（みょ）＝1音、促音（っ）＝1音、撥音（ん）＝1音
      そのうえで音数を数え、長句5/7/5・短句7/7 になっているか見る。

      【季語の所属（迷ったら下に従う）】
      - 春：霞（かすむ）・梅・柳・桜　／　秋：霧・月・紅葉　／　冬：雪・霜
      - 同じ句に春と冬が混在していても、それ自体は違反としない。

      【句数（同じ季を続けてよい句数）】
      - 春・秋：3〜5句（始めたら最低3句、6句目以降は違反）
      - 夏・冬・恋・旅：3句まで

      【句去（一度出た語を再び出すまでに空ける句数）】
      - 月・日、雨・雪・露・霜、霞・霧・雲・煙、名所：間に3句空ける
      - 山、水辺（川・舟・水）、夜、恋、旅、風：間に5句空ける
      上記より近い間隔で同類が再登場したら違反。

      【検査対象（古い順・上から下へ流れる）】
      #{list}

      以下のJSON形式のみで返答（前後に説明文を付けない）。
      breakdown は各句を「句 → よみ → 音分解（N音）／季・種類」の形式で入れる。
      {"result": "ok または ng", "issues": ["違反内容。無ければ空配列"], "breakdown": ["各句の分析"]}
    PROMPT
  end
end
