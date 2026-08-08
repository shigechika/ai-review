# ai-review

[English README](README.md)

Pull Requestを**アドバイザリなAIコードレビュー**にかける、再利用可能な
GitHub Actionsワークフローです。自前のOpenAI互換エンドポイント（Azure AI
Foundry v1 APIで検証済み）を使用します。中央に置いた1つのエンジンを、各
リポジトリから約20行のcallerで呼び出す構成のため、エンジン側の修正はタグを
動かすだけで全callerに届きます。ワークフローファイルをリポジトリごとに
コピーして回る必要はありません。

## 何をするか

PRが開かれるたびに（callerが`synchronize`を有効にしていれば、pushの
たびにも）、エンジンは次の処理を行います。

1. PRのタイトル・説明、**リポジトリのガイダンスファイル**（`CLAUDE.md`・
   `AGENTS.md`・`.github/copilot-instructions.md`）、**変更されたファイル
   の全文**、そしてdiffからレビュー用のプロンプトを組み立てます。
2. モデルに最大3件までの指摘を求めます。各指摘には、具体的にどの入力・
   状態で失敗するかの説明、重大度（`blocking`または`advisory`）、そして
   厳密な出力フォーマットが要求されます。
3. 2回目の、コストの低い**verifier呼び出し**を行い、各候補の指摘に対して
   反証を試みます。反証できた指摘は、投稿される前に取り除かれます。
4. PRごとに**1件のsticky comment**を維持します。このコメントには、1行の
   verdict（判定）、生き残った指摘、そしてラウンドをまたいで指摘の状態
   （`open`／`fixed`／`dismissed`）を保持する機械可読な**findings
   ledger**が含まれます。一度決着した論点が蒸し返されることはありません。
   実際にレビューが走ったラウンド（スキップされるpushについては次の項目を
   参照）は、PRの末尾に新しいコメントを投稿し、それより前のコメントを
   削除します。**スキップされたラウンドであっても**、前のラウンドで削除に
   失敗したり競合したりして取り残された孤立マーカーコメントは掃除するため、
   次のラウンドを待たずに重複が解消されます（ただし削除の失敗自体は
   warningを出すだけで処理を止めないため、ラウンドの間だけ一時的に
   重複が残ることはあります）。したがって、常に最新のレビュー状態は
   `ai-review`のコメントとしては最新のものになります。ただし、スレッド
   全体の一番下のコメントとは限りません。
   スキップされたpush自体は何も投稿しないため、その後に人間がコメントを
   付けると、sticky commentより下に並ぶことがあります。また、スキップ
   されなかったラウンドは既存のコメントを編集するのではなく毎回新しい
   コメントを投稿するため、初回だけでなく該当するラウンドのたびにPRの
   購読者へ通知が飛びます。
5. 2回目以降のpushでは**新しいコミットのみ**をレビュー対象にします
   （compare APIによるdeltaラウンド）。コードのPRに対するドキュメントのみ
   のpushや、すでにレビュー済みのheadへのpushでは**投稿自体を省略**し、
   deltaの情報が不完全な場合は安全側に倒してfull-diffのラウンドに切り
   替えます。
6. **ドキュメントのみのPR**では、docs-modeに切り替わります。この場合は
   ドキュメントの正確さそのものがレビュー対象になり、ドキュメントが
   言及しているソースファイルを（PRのhead時点で）証拠として添付し、
   シグネチャ・デフォルト値・挙動に関する記述をコードと突き合わせます。

このレビューは**アドバイザリ専用**です。すべての失敗経路がsoft-fail
（黙って諦める）するよう設計されているため、このジョブがPRをブロックする
ことは決してありません。

## クイックスタート

1. リポジトリ（またはorganization）に**secrets**を2つ追加します。

   | Secret | 値 |
   |---|---|
   | `AI_REVIEW_ENDPOINT` | リソースルート（例: `https://<resource>.services.ai.azure.com`） |
   | `AI_REVIEW_API_KEY` | そのリソースのAPIキー |

   **実際の（リソース固有の）**エンドポイントのホスト名はcredentialとして
   扱ってください。エンジン側ではログ出力時にマスクしますが、コード・
   ドキュメント・issueにも書かないようにしてください。上記の`<resource>`
   のようなプレースホルダーであれば問題ありません。

2. リポジトリに`.github/workflows/ai-review.yml`を作成します。

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

   pushのたびではなくPRごとに1回だけレビューしたい場合は、`types`から
   `synchronize`を外してください。

レビュー機能自体はこれで完成です。Draft PR・`release-please--*`ブランチ・
DependabotのPRは、エンジン側で自動的にスキップされます。

3. **任意 — 公開リポジトリ向けの受け入れ管理。** `pr-gate.yml`は、独立した
   もう1つのreusable workflowです。maintainer・member・collaboratorの
   いずれでもない作成者からのPRを、理由を説明する定型コメントとともに
   クローズし、受け入れられたPRには`ai-review`ラベルを付与します。
   `ai-review.yml`とは完全に独立しており、導入してもレビューの動作や
   タイミングは一切変わりません。目的はスパムや勧誘目的の未承諾PRが
   開いたまま残るのを防ぐことで、付与されるラベルはbranch protectionや
   別のworkflowのトリガーなど、好きな用途に使えます。

   専用のトリガーが必要です。**上記step 2の`pull_request`トリガーを
   流用しても動作しません。** フォークのPRをクローズしたりラベル付けし
   たりするには、ベースリポジトリの権限を持つtokenが必要ですが、通常の
   `pull_request`イベントはフォークに対してread-onlyのtokenしか渡し
   ません。そのため流用した場合、エラーにすらならず、このjobが毎回黙って
   スキップされるだけになります。

   ```yaml
   name: PR Gate
   on:
     pull_request_target:
       types: [opened, reopened, closed]
   permissions:
     contents: read
     pull-requests: write
     issues: write
   concurrency:
     group: pr-gate-${{ github.event.pull_request.number }}
     cancel-in-progress: false
   jobs:
     gate:
       uses: shigechika/ai-review/.github/workflows/pr-gate.yml@v1
   ```

   信頼できるかどうかの判定には、GitHub組み込みの`author_association`
   （`OWNER`／`MEMBER`／`COLLABORATOR`）という、その場で取得できる指標
   だけを使います。それに加えて、`dependabot[bot]`・`github-actions[bot]`、
   および同一リポジトリの`release-please--*`ブランチは組み込みの許可
   リストで常に除外されるため、通常の依存関係更新やリリースのPRが
   クローズされることはありませんし、`ai-review.yml`自身のスキップ
   ロジックによってどのみちレビューされないPRに紛らわしいラベルが付く
   こともありません。却下された作成者本人がPRをreopenした場合は同じ
   判定が再実行され、再びクローズされます。一方、それ以外の誰かが
   reopenした場合はその判断を尊重します。GitHubはそもそも十分な権限を
   持つ人物にしかreopenという操作自体を許可しないため、こちら側で改めて
   権限を照会する必要がありません。リポジトリ変数
   `AI_REVIEW_DISABLE_GATE`を`true`に設定すると、callerファイルを残した
   ままこのworkflowを無効化できます。

これで完了です。

## 動作確認

実際のPRを1つ開き、`review`ジョブのログを確認してください。draft・
DependabotのPR・同一リポジトリの`release-please--*`ブランチは、いずれも
エンジン自身がスキップするため確認には使えません。

- `::notice::guidance <file>: sent N of M bytes` — リポジトリに存在する
  ガイダンスファイルごとに1行表示されます。1行も表示されない場合は、
  BASEリビジョンに`CLAUDE.md`・`AGENTS.md`・
  `.github/copilot-instructions.md`のいずれも存在しないというだけなので、
  問題ありません。
- `::notice::ai-review context: docs_mode=… delta_mode=… diff=…B …` —
  実際にモデルへ送った内容を要約した行が1行出力されます。`diff=0B`に
  なっていたり、この行自体が出力されていない場合は、diffの取得に失敗して
  います。
- `::warning::AI_REVIEW_ENDPOINT / AI_REVIEW_API_KEY not set — skipping AI
  review`は、文字通りの意味です。リポジトリに2つのsecretsが設定されて
  いない（または空になっている）か、あるいはこのPRがフォークからのもの
  です（フォークからのPRは仕様上secretsを受け取らないため、常にこの
  メッセージになります）。
- sticky commentも`::warning::`もどちらも出ていない場合は、たいてい
  `::notice::...skipping this round`系のいずれか（ドキュメントのみの
  push、またはすでにレビュー済みのheadへのpush）が出力されています。
  バグを疑う前に、まずログを確認してください。`review`ジョブ自体が
  一度も実行されていない場合は、原因はエンジンより手前にあります。
  caller側の`on:`トリガーの設定や、branch protectionのルールを見直して
  ください。

すべての失敗経路は`::warning::`を出力するだけで、それ以外の目に見える
影響を残しません（アドバイザリ専用という設計によるものです）。専用の
ヘルスチェック用エンドポイントやワークフローは用意していません。複数の
リポジトリでこのエンジンを運用している場合、頼りになるシグナルはレビュ
アーが普段から見ているものと同じです — 直近の実際のPRにsticky comment
が付いているかどうか、それだけです。

## 設定

すべての設定項目は任意です。各設定値は次の順序で解決されます。

**input → （呼び出し元リポジトリの）repository variable → デフォルト値**

| Input | Repository variable | デフォルト値 | 意味 |
|---|---|---|---|
| `language` | `AI_REVIEW_LANG` | `en` | 指摘本文の言語（`en`または`ja`）。マーカー・severity・ledgerはどちらの場合も英語のままです。 |
| `model` | `AI_REVIEW_MODEL` | `gpt-5.6-sol` | エンドポイントに送信するdeployment名。 |
| `reasoning-effort` | `AI_REVIEW_EFFORT` | `high` | レビュアー呼び出しの`reasoning_effort`。センチネル値`off`を指定するとパラメータ自体を送信しなくなります（空文字列はデフォルト値にフォールバックしてしまうため、offスイッチとしては機能**しません**）。 |
| — | `AI_REVIEW_VERIFY_EFFORT` | `low` | verifier呼び出しの`reasoning_effort`（同じ`off`センチネルが使えます）。 |
| `max-total-file-bytes` | — | `131072` | 添付する変更ファイル全文の合計バイト数の上限。 |

呼び出されるワークフロー内の`vars.*`は**呼び出し元**リポジトリを基準に
解決されるため、リポジトリごとの設定（例: `AI_REVIEW_LANG=ja`）にinputの
配線は不要です。リポジトリにvariableを設定するだけで、そのリポジトリの
すべてのレビューに反映されます。

deploymentが`reasoning_effort`をHTTP 400で拒否した場合、エンジンはこの
パラメータなしで1回だけ再試行し、その旨をログに出力します。

## セキュリティモデル

完全な理屈は[`ai-review.yml`](.github/workflows/ai-review.yml)のヘッダー
コメントを参照してください。要点は次のとおりです。

- **`pull_request`を使用し、`pull_request_target`は使用しません。**
  攻撃者が制御できるheadに対して、secretsを持った状態でジョブを実行して
  はならないためです。結果として、フォークからのPRにはsecretsが渡らず、
  レビューも行われません（これは意図した挙動です）。
- **PRの内容をcheckoutしません。** diffと変更ファイルの内容はGitHub API
  経由で取得し、プロンプトを組み立てるためだけにワークフロー自身が名前を
  決めたプレーンテキストファイルへ書き出します。しかしPRのブランチが
  gitのworking treeとしてcheckoutされることはないため、ファイルのパスや
  種類をPR側が制御することは決してできません（symlinkから
  `/proc/self/environ`を読むといった類の攻撃を防いでいるのはこの点です）。
- **ガイダンスはBASEリビジョンで読み込みます。** モデルを*操縦する*側の
  ファイルは、レビュー対象のPRによって書き換え可能であってはならない
  からです。一方、変更されたファイルの添付は意図的にHEADで読み込みます。
  こちらはレビューの*対象*であり、diffと同じ信頼レベルとして扱います。
  ガイダンスのパスは添付ファイルのdeny-listにも含まれているため、PRが
  対象ファイルという経路を使って自分自身のガイダンスを持ち込むことも
  できません。
- **サイズ上限より先にdeny-listを適用します。** 機密情報の形をした
  ファイル（`.env`系・`config.ini`・鍵素材・service accountのJSONなど）
  は、どれだけ小さくても添付されません。バイナリやバルクデータもノイズ
  として除外されます。
- **モデルの出力はコードではなくデータとして扱います。** ファイルに書き
  出してパースするだけで、`eval`することも、workflowコマンドとしてecho
  することもありません。findings ledgerは、再利用される前にサニタイズ
  されます（コメント投稿者によるフィルタリング、JSONの形状検証、ラウンド
  番号付きのid検証）。
- ジョブに必要な権限は`contents: read`と`pull-requests: write`だけです。
  diff経由のプロンプトインジェクションが仮に成功したとしても、起こり
  得る最悪の結果は誤ったアドバイザリコメントが投稿される程度です。

## バージョニング

- リリースは**release-please**が担当します。Conventional Commitsを
  `main`にマージすると、release-pleaseがrelease PRを開くので、それを
  マージすると`vX.Y.Z`タグ・GitHub Release・changelogが生成されます。
- `v1`は**移動タグ**です。`@v1`にピン留めしているcallerには、エンジン
  側の修正が自動的に届きます（リリースワークフローがリリースのたびに
  このタグを動かします）。インターフェースを破壊するような変更を行う
  場合は、メジャーバージョンを上げます。
- ピン留めやロールバック用に、不変の`vX.Y.Z`タグも用意されています。
  `git tag -f v1 <last-good> && git push -f origin v1`とすることで、
  全callerを一括でロールバックできます。ローカルでタグを動かすだけでは
  何も起きません — callerはGitHub上のタグを解決しにいくため、実際に
  効くのはforce pushの部分です。
- **このリポジトリは公開状態を維持する必要があります。** GitHubは
  reusable workflowを、呼び出し元が読み取れるリポジトリからしか解決
  できないため、非公開にすると外部のcallerがすべて壊れてしまいます。

## ライセンス

[MIT](LICENSE)
