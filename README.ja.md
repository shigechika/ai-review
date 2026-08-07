# ai-review

[English README](README.md)

Pull Request を **アドバイザリ AI コードレビュー**する再利用可能（reusable）
GitHub Actions ワークフローです。自前の OpenAI 互換エンドポイント（Azure AI
Foundry v1 API で検証済み）を使います。中央のエンジン1つを、各リポジトリから
20行程度の caller で呼び出す構成 — エンジンの修正はタグを動かすだけで全
caller に届き、ワークフローファイルのコピペ横展開は不要になります。

## 何をするか

PR ごと（caller が `synchronize` を有効にしていれば push ごと）に、エンジンは:

1. PR タイトル・説明、**リポジトリガイダンス**（`CLAUDE.md`・`AGENTS.md`・
   `.github/copilot-instructions.md`）、**変更ファイルの全文**、diff から
   レビュープロンプトを組み立てます。
2. モデルに最大3件の指摘を求めます。各指摘には具体的な失敗入力／状態、
   重大度（`blocking`/`advisory`）、厳密な出力形式が要求されます。
3. 2回目の安価な **verifier 呼び出し**が各候補の反証を試み、反証できた
   指摘は投稿前に落とされます。
4. PR ごとに **sticky コメント1つ**を維持します。1行の verdict、生き残った
   指摘、そしてラウンドをまたいで指摘の状態（`open`/`fixed`/`dismissed`）を
   運ぶ機械可読な **findings ledger** を含みます — 決着済みの論点は二度と
   蒸し返されません。実際にレビューが走ったラウンド（スキップされる push
   については次項）はPRの末尾に新規コメントを投稿し、それ以前のコメントを
   削除します。**スキップされたラウンドでも**、前回の削除失敗や競合で
   取り残された孤立マーカーコメントを掃除するので、次の本格レビューを
   待たずに重複が解消されます — 常に最新のレビュー状態は `ai-review` の
   コメントとしては最新（かつ唯一）のものになります。ただしスレッド全体の
   最後のコメントとは限りません。スキップされた push 自体は何も投稿しない
   ため、その後に人間のコメントが付くと sticky コメントより下に並ぶことが
   あります。スキップされなかったラウンドは既存コメントを編集するのでは
   なく毎回新規コメントを投稿するため、初回だけでなく該当ラウンドのたびに
   PR の購読者へ通知が飛びます。
5. 2回目以降の push では**新規コミットのみ**をレビューし（compare API に
   よる delta ラウンド）、コード PR へのドキュメントのみの push や既にレビュー
   済みの head への push は**投稿自体をスキップ**し、delta が不完全なときは
   安全側の full-diff ラウンドに切り替えます。
6. **ドキュメントのみの PR** は docs-mode に切り替わります: ドキュメントの
   正確さがレビュー対象になり、docs が言及するソースファイルを（PR head
   から）証拠として添付して、シグネチャ・デフォルト値・挙動の記述をコードと
   突き合わせます。

レビューは**アドバイザリ専用**です: すべての失敗経路が soft-fail するため、
このジョブが PR をブロックすることはありません。

## クイックスタート

1. リポジトリ（または organization）に **secrets** を2つ追加します:

   | Secret | 値 |
   |---|---|
   | `AI_REVIEW_ENDPOINT` | リソースルート（例 `https://<resource>.services.ai.azure.com`） |
   | `AI_REVIEW_API_KEY` | そのリソースの API キー |

   **実際の（リソース固有の）**エンドポイントホスト名は credential として
   扱ってください。エンジンはログでマスクしますが、コード・ドキュメント・
   issue にも書かないでください。上の `<resource>` のようなプレースホルダ
   例は問題ありません。

2. リポジトリに `.github/workflows/ai-review.yml` を作成します:

   ```yaml
   name: AI review
   on:
     pull_request:
       types: [opened, reopened, ready_for_review, synchronize]
   permissions:
     contents: read
     pull-requests: write
   concurrency:
     group: ai-review-${{ github.event.pull_request.number }}
     cancel-in-progress: true
   jobs:
     review:
       uses: shigechika/ai-review/.github/workflows/ai-review.yml@v1
       secrets:
         AI_REVIEW_ENDPOINT: ${{ secrets.AI_REVIEW_ENDPOINT }}
         AI_REVIEW_API_KEY: ${{ secrets.AI_REVIEW_API_KEY }}
   ```

   push ごとではなく PR ごとに1回のレビューにしたい場合は、`types` から
   `synchronize` を外してください。

これだけです。Draft PR・`release-please--*` ブランチ・Dependabot の PR は
エンジン側でスキップされます。

## 動作確認

実際の PR を1つ開いて `review` ジョブのログを見てください。draft・
dependabot の PR・同一リポジトリの `release-please--*` ブランチは、
いずれもエンジン自身がスキップするので確認には使えません。

- `::notice::guidance <file>: sent N of M bytes` — リポジトリにある
  ガイダンスファイルごとに1行表示されます。1行も出ない場合は、BASE
  リビジョンに `CLAUDE.md`・`AGENTS.md`・`.github/copilot-instructions.md`
  のどれも無いだけなので問題ありません。
- `::notice::ai-review context: docs_mode=… delta_mode=… diff=…B …` —
  モデルに実際に送った内容の要約が1行出ます。`diff=0B` になっていたり
  この行自体が出ていない場合は diff の取得に失敗しています。
- `::warning::AI_REVIEW_ENDPOINT / AI_REVIEW_API_KEY not set — skipping AI
  review` はそのまま、リポジトリに2つの secrets が未設定（または空）だと
  いうことです（fork からの PR は仕様上 secrets を受け取らないため、常に
  このメッセージになります）。
- sticky コメントも `::warning::` も何も出ていない場合は、たいてい
  `::notice::...skipping this round` のどれか（ドキュメントのみの push、
  または既にレビュー済みの head への push）が出ているはずです。バグを
  疑う前にまずログを確認してください。`review` ジョブ自体が一度も
  走っていない場合は、エンジンより手前 — caller 側の `on:` トリガーや
  ブランチ保護ルールを見直してください。

失敗経路はすべて `::warning::` を出すだけで、それ以外の影響は残しません
（アドバイザリ専用の設計です）。専用のヘルスチェック用エンドポイントや
ワークフローは用意していません。複数リポジトリでこのエンジンを運用して
いるなら、見るべきシグナルはレビュアーが普段見ているものと同じです —
直近の実 PR に sticky コメントが付いているかどうか、それだけです。

## 設定

すべて任意です。各設定は
**input → （呼び出し側リポジトリの）repository variable → 既定値**
の順に解決されます。

| Input | Repository variable | 既定値 | 意味 |
|---|---|---|---|
| `language` | `AI_REVIEW_LANG` | `en` | 指摘本文の言語（`en` か `ja`）。マーカー・severity・ledger はどちらでも英語のままです。 |
| `model` | `AI_REVIEW_MODEL` | `gpt-5.6-sol` | エンドポイントに送る deployment 名。 |
| `reasoning-effort` | `AI_REVIEW_EFFORT` | `high` | レビュアーの `reasoning_effort`。センチネル `off` でパラメータ送信を止めます（空文字は既定値へフォールバックするため off スイッチに**なりません**）。 |
| — | `AI_REVIEW_VERIFY_EFFORT` | `low` | verifier の `reasoning_effort`（同じ `off` センチネル）。 |
| `max-total-file-bytes` | — | `131072` | 添付する変更ファイル全文の合計バイト予算。 |

呼び出された（called）ワークフローの `vars.*` は**呼び出し側**リポジトリで
解決されるため、リポジトリごとの設定（例: `AI_REVIEW_LANG=ja`）に input の
配線は不要です。リポジトリに variable を置くだけで、そのリポジトリの
レビュー全部に効きます。

deployment が `reasoning_effort` を HTTP 400 で拒否した場合、エンジンは
パラメータなしで1回だけ再試行し、その旨をログに出します。

## セキュリティモデル

完全な理屈は [`ai-review.yml`](.github/workflows/ai-review.yml) のヘッダ
コメントを読んでください。要点:

- **`pull_request` を使い、`pull_request_target` は使わない** — 攻撃者が
  制御する head に対して secrets 付きでジョブを走らせてはならないため。
  帰結として fork PR には secrets がなくレビューも行われません（許容）。
- **checkout しない。** すべて GitHub API 経由で取得し、PR 由来のものが
  runner のディスク上のファイルになることはありません（symlink →
  `/proc/self/environ` の類の攻撃も同時に潰れます）。
- **ガイダンスは BASE リビジョンで読む** — モデルを*操縦する*ファイルは、
  レビュー対象の PR から書き換え可能であってはなりません。変更ファイルの
  添付は意図的に HEAD で読みます: それはレビューの*対象*であり、diff と
  同じ信頼クラスです。ガイダンスのパスは添付の deny-list にも載っており、
  PR が対象チャンネル経由で自分のガイダンス版を持ち込むことはできません。
- **サイズ上限より先に deny-list**: 機密の形をしたファイル（`.env` 系・
  `config.ini`・鍵素材・service-account JSON）はどんなに小さくても添付
  されません。バイナリとバルクデータもノイズとして除外されます。
- **モデル出力はコードではなくデータ**: ファイルに書いてパースするだけで、
  `eval` も workflow コマンドとしての echo もしません。findings ledger は
  再利用前にサニタイズされます（コメントの作者フィルタ・JSON の形状検証・
  ラウンド番号つき id）。
- ジョブに必要な権限は `contents: read` と `pull-requests: write` だけ。
  diff 経由のプロンプトインジェクションが成功しても、最悪の結果は誤った
  アドバイザリコメントです。

## バージョニング

- リリースは **release-please** が切ります: Conventional Commits を
  `main` にマージすると release PR が開くので、それをマージすると
  `vX.Y.Z` タグ・GitHub Release・changelog が発行されます。
- `v1` は**移動タグ**です: `@v1` にピンした caller にはエンジンの修正が
  自動で届きます（リリースワークフローが毎リリースで動かします）。
  インターフェースの破壊的変更ではメジャーを上げます。
- ピン留め・ロールバック用に不変の `vX.Y.Z` タグがあります
  （`git tag -f v1 <last-good>` で全 caller を一括ロールバック）。
- **このリポジトリは public を維持する必要があります** — reusable
  workflow は caller が読めるリポジトリからしか解決できないため、private
  化すると外部の caller が全て壊れます。

## ライセンス

[MIT](LICENSE)
