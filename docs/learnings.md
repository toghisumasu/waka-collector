# learnings（プロジェクト知見の蓄積）

LLM挙動の症状→打ち手は `docs/llm_behavior_notes.md` を参照。ここには実装・計測上の落とし穴を記録する。

---

## 2026-09-29

### OllamaClient.generate の temperature が options の外に置かれている

- `app/services/ollama_client.rb` の `generate` は `body[:temperature] = temperature` と**トップレベル**に置いている。Ollama `/api/generate` のモデルパラメータ（temperature・num_predict・repeat_penalty・num_ctx 等）は `options: {}` の中が正で、トップレベルのtemperatureは無視される見込み。
- 影響（コード読みによる推定）：`renga_generator.rb` が渡す `temperature: 0.5 / 0.8`（wrong_streak>=2 で0.8に上げる仕組み）や `tenji_kata_hint` の 0.5 は、これまで効いていなかった可能性が高い。実際にはモデル既定（Modelfile）の温度で走っている。
- **未検証**（Ollamaでの実測は未実施）。**未修正**：修正すると全走行の生成挙動が変わるため、14b対27b比較（同一条件）が終わるまで触らない。修正するときは1変数として単独で行い、前後で観測走行を比較すること。
- なお num_predict / repeat_penalty（bc97363）は最初から `options` 内に置いている。

### MeCab複合語の盲点：単一トークン化された複合語は語単位の照合をすり抜ける

MeCab（ユーザー辞書込み）は「霜夜」「月夜」「月影」を**それぞれ1トークンの名詞**にする（2026-09-29確認）。語単位の照合はすべて、これらの複合語の内側にある「霜」「月」を見ない。

- **辞書照合（BuiDictionary）**：`霜夜` → bui=[]（部立検出なし）。`霜の夜` は 霜/の/夜 に分かれて 降物・時分 を検出する。「露に映す秋の月夜」も 露 しか検出されず、月夜の「月」（光物）は拾われない。複合語は辞書に個別登録するか、部分文字列照合が必要。
- **OverlapGuard（内容語Jaccard）**：前句「…秋の月夜」に対し付句「…月影ゆふ」は、トークンが「月夜」≠「月影」なので重複0.0となりガードをすり抜ける。M-3 Phase2の91句目のFORCED（七句去物「月」）はこれが背景（3候補とも overlap=0.0 で通過し、式目チェッカーの七句去物で初めて検出された）。閾値0.111の根拠（水無瀬三吟99組）は表層トークン単位の重複で、語幹・部分一致の流用は測れていない。
- 対応の方向（未実施）：OverlapGuardに部分文字列（漢字1字語幹）一致の補助判定を追加する／辞書に複合語を登録する。いずれも別依頼書で判断。

出典：`docs/observation_20260929_bonsai2_m3_phase2_run100.md`
