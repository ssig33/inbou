# PDF分析ツール

このツールは、PDFファイルを分析し、ジョン・Fケネディ大統領暗殺事件に関連する重要な情報を抽出するためのものです。

## 機能

- PDFファイルを画像に変換
- OpenAIのGPT-4o-miniを使用して画像を分析
- 分析結果をJSON形式で保存
- 複数のPDFファイルを一括処理
- 長いPDFの処理制限（30ページを超える場合は最初の30ページのみ分析）

## 必要なもの

- Ruby 2.6以上
- Poppler（PDFを画像に変換するために必要）
- OpenAI API キー

## インストール

1. Popplerをインストールします：

```bash
# Ubuntuの場合
sudo apt-get install poppler-utils

# macOSの場合
brew install poppler
```

2. 必要なRubyのgemは自動的にインストールされます（bundler/inlineを使用）

## 使い方

### 1. OpenAI APIキーを設定

```bash
export OPENAI_API_KEY='your-api-key'
```

### 2. 単一のPDFファイルを分析
 
```bash
./pdf_analyzer.rb pdfs/example.pdf
```

### 3. 複数のPDFファイルを一括処理

```bash
./batch_analyze.rb [コマンド] [オプション]
```

#### バッチ処理のコマンドとオプション

- `analyze`: PDFファイルを分析します（デフォルトコマンド）
  - `-f, --force`: 強制的に全ファイルを再処理します（既に処理済みのファイルも含む）
  - `-m, --max=N`: 処理する最大ファイル数を指定します
- `version`: バージョン情報を表示します
- `help [コマンド]`: ヘルプメッセージを表示します

例：
```bash
# 通常の処理（未処理のファイルのみ）
./batch_analyze.rb

# 強制的に全ファイルを再処理
./batch_analyze.rb analyze --force

# 最大10ファイルのみ処理
./batch_analyze.rb analyze --max=10

# 強制再処理かつ最大5ファイルのみ処理
./batch_analyze.rb analyze --force --max=5

# ヘルプを表示
./batch_analyze.rb help

# analyzeコマンドのヘルプを表示
./batch_analyze.rb help analyze

# バージョン情報を表示
./batch_analyze.rb version
```

## 出力形式

分析結果は `outputs` ディレクトリに保存されます。各PDFファイルに対して、同じ名前のJSONファイルが生成されます。

JSONファイルの形式：

```json
{
  "is_kennedy_assassination": true,
  "important": true,
  "title": "文書のわかりやすいタイトル",
  "summary": "Markdown形式の要約",
  "page_info": {
    "total_pages": 45,
    "analyzed_pages": 30,
    "note": "ページ数が30を超えるため、最初の30ページのみを分析しました"
  }
}
```

重要でないと判断された場合は、簡略化された形式で保存されます：

```json
{
  "important": false,
  "page_info": {
    "total_pages": 45,
    "analyzed_pages": 30,
    "note": "ページ数が30を超えるため、最初の30ページのみを分析しました"
  }
}
```

※ `page_info` フィールドはページ数が30を超える場合のみ含まれます。

## 注意事項

- PDFファイルのサイズや複雑さによっては、処理に時間がかかる場合があります
- ページ数が30を超えるPDFファイルは、最初の30ページのみが分析されます
- OpenAI APIの使用には料金が発生する場合があります
- 大量のPDFファイルを処理する場合は、APIの利用制限に注意してください