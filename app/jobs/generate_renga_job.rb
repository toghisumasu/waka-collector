# frozen_string_literal: true

# 平野連歌会向けVPSデプロイ（方式B'、docs/phase0_async_report.md）:
# RengasController#createから重い生成処理（Ollama呼び出しを含む、実測49-256秒）を
# 切り離し、ActiveJob(:asyncアダプタ、追加gem・Redis不要)で非同期実行する。
# 完了時はTurbo Streamsで該当Rengaのshowページへブロードキャストし、
# ブラウザ側は何もポーリングせず自動的に結果が表示される。
class GenerateRengaJob < ApplicationJob
  queue_as :default

  def perform(renga_id, verse_type, honka_ids)
    renga = Renga.find(renga_id)
    renga.update!(status: "generating")

    result = RengaGenerationService.new(
      maeku: renga.maeku, previous_renga_id: renga.previous_renga_id,
      verse_type: verse_type, honka_ids: honka_ids
    ).call

    renga.update!(
      tsugeku:            result.tsugeku,
      tsugeku_author:     result.tsugeku_author,
      generated_by_model: result.generated_by_model,
      style_check_result: result.style_check_result,
      honka_reference:    result.honka_reference,
      status:             "done"
    )
  rescue RengaGenerationService::ShikimokuNg => e
    Rails.logger.warn "[GenerateRengaJob] shikimoku ng: renga_id=#{renga_id} #{e.message}"
    renga.update!(status: "failed")
  rescue => e
    Rails.logger.error "[GenerateRengaJob] failed: renga_id=#{renga_id} #{e.class}: #{e.message}"
    renga&.update(status: "failed")
  ensure
    broadcast_result(renga) if renga
  end

  private

  def broadcast_result(renga)
    Turbo::StreamsChannel.broadcast_replace_to(
      renga, target: "renga_result", partial: "rengas/result", locals: { renga: renga }
    )
  end
end
