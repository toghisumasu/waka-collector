# frozen_string_literal: true

# 依頼書2026-09-06 百韻管理機能: renga_verses（成立句）を折ごとに一覧表示する。
class HyakuinsController < ApplicationController
  def show
    tip = RengaVerse.find(params[:id])
    @verses   = fetch_chain(tip.id)
    @complete = @verses.size >= RengaVerse::TOTAL_VERSES
  end

  private

  # rengas側のfetch_verse_chainと同じ再帰CTEパターン（previous_verse_idを
  # 遡って古い順に取得）。renga_versesにグルーピング用の列がないため、
  # tip.idから遡る形でその一巻だけを取り出す。
  def fetch_chain(tip_id)
    sql = RengaVerse.sanitize_sql_array([<<~SQL, tip_id])
      WITH RECURSIVE verse_chain AS (
        SELECT id, verse_no, maeku, tsugeku, previous_verse_id, 0 AS depth
        FROM renga_verses
        WHERE id = ?
        UNION ALL
        SELECT r.id, r.verse_no, r.maeku, r.tsugeku, r.previous_verse_id, verse_chain.depth + 1
        FROM renga_verses r
        INNER JOIN verse_chain ON r.id = verse_chain.previous_verse_id
      )
      SELECT id, verse_no, maeku, tsugeku FROM verse_chain ORDER BY depth DESC
    SQL

    RengaVerse.connection.select_all(sql).to_a
  end
end
