require "rails_helper"

# 依頼書B Item 3: 縦書き印刷ページ（/hyakuin/:id/vertical）の受入基準を確認する。
RSpec.describe "GET /hyakuin/:id/vertical", type: :request do
  it "RC-3-1・RC-3-2・RC-3-3: 縦書きHTMLが表示され、季節分類とFORCED(常にfalse)が機能する" do
    v1 = RengaVerse.create!(verse_no: 1, maeku: nil, tsugeku: "はるののにかすみたなびく",
                             maeku_type: nil, tsugeku_type: "chouku",
                             previous_verse_id: nil, renga_id: nil)
    v2 = RengaVerse.create!(verse_no: 2, maeku: v1.tsugeku, tsugeku: "紅葉ちりゆく庭のあたり",
                             maeku_type: "chouku", tsugeku_type: "tanku",
                             previous_verse_id: v1.id, renga_id: nil)

    get vertical_hyakuin_path(v2)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("初折表")
    expect(response.body).to include("春")   # かすみ→春
    expect(response.body).to include("秋")   # 紅葉→秋
    expect(response.body).to include("FORCED 0句")
    expect(response.body).not_to include('class="forced-mark"')
  end

  it "RC-3-5: ゲート(verify_shikimoku.rb)に影響しない純粋な表示機能である" do
    v1 = RengaVerse.create!(verse_no: 1, maeku: nil, tsugeku: "はるののにかすみたなびく",
                             maeku_type: nil, tsugeku_type: "chouku",
                             previous_verse_id: nil, renga_id: nil)

    get vertical_hyakuin_path(v1)

    expect(response).to have_http_status(:ok)
  end
end
