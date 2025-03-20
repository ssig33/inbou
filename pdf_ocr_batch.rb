#!/usr/bin/env ruby
# encoding: utf-8

require 'bundler/inline'

# 必要なライブラリをインストール
gemfile do
  source 'https://rubygems.org'
  gem 'ruby-openai'
  gem 'json'
  gem 'fileutils'
  gem 'base64'
  gem 'thor'
end

require 'json'
require 'fileutils'
require 'openai'
require 'base64'
require 'tempfile'
require 'thor'

# OpenAI APIクライアントの設定
OPENAI_API_KEY = ENV['OPENAI_API_KEY']
if OPENAI_API_KEY.nil? || OPENAI_API_KEY.empty?
  puts "エラー: OPENAI_API_KEYが設定されていません。"
  puts "以下のコマンドを実行してください: export OPENAI_API_KEY='your-api-key'"
  exit 1
end

# OpenAI APIクライアントの初期化
$client = OpenAI::Client.new(access_token: OPENAI_API_KEY)

# 出力ディレクトリの確認
MARKDOWN_DIR = 'markdowns'
FileUtils.mkdir_p(MARKDOWN_DIR) unless Dir.exist?(MARKDOWN_DIR)

# 一時ディレクトリの作成
TEMP_DIR = File.join(Dir.tmpdir, "pdf_ocr_#{Time.now.to_i}")
FileUtils.mkdir_p(TEMP_DIR)

# PDFを画像に変換する関数
def convert_pdf_to_images(pdf_path, output_dir)
  puts "PDFを画像に変換中: #{pdf_path}"
  
  # PDFのファイル名（拡張子なし）を取得
  pdf_basename = File.basename(pdf_path, '.pdf')
  
  # 出力ディレクトリを作成
  FileUtils.mkdir_p(output_dir)
  
  # Popplerのpdftoppmを使用してPDFを画像に変換
  # -r 300: 解像度を300 DPIに設定（OCRの精度向上のため高解像度に設定）
  # -png: PNG形式で出力
  cmd = "pdftoppm -r 300 -png \"#{pdf_path}\" \"#{output_dir}/#{pdf_basename}\""
  
  puts "実行コマンド: #{cmd}"
  result = system(cmd)
  
  unless result
    puts "エラー: PDFの変換に失敗しました。Popplerがインストールされているか確認してください。"
    puts "インストール方法: sudo apt-get install poppler-utils (Ubuntu) または brew install poppler (macOS)"
    raise
  end
  
  # 生成された画像ファイルのパスを返す
  Dir.glob(File.join(output_dir, "#{pdf_basename}-*.png")).sort
end

# 画像をBase64エンコードする関数
def encode_image_to_base64(image_path)
  File.open(image_path, 'rb') do |img|
    Base64.strict_encode64(img.read)
  end
end

# 画像をOCRして内容を抽出する関数
def ocr_images_with_gpt4o(client, image_paths, chunk_index = nil, total_chunks = nil)
  chunk_info = ""
  if chunk_index && total_chunks
    chunk_info = "（チャンク #{chunk_index}/#{total_chunks}）"
  end
  
  puts "画像をOCR処理中...#{chunk_info}"
  
  # 各画像をBase64エンコードしてメッセージに追加
  messages = [
    {
      role: "system",
      content: "あなたはPDFドキュメントのOCR処理を行うアシスタントです。提供された画像からテキストを抽出し、必ず日本語に翻訳して以下の情報を提供してください：\n
1. 文書の発信者（「発」）があれば抽出\n
2. 文書の受信者（「着」）があれば抽出\n
3. 文書の日付・時刻（「日時」）があれば抽出\n
4. 文書の主題・タイトル\n
5. 文書の本文全体\n\n
以下のMarkdown形式「だけ」で結果を返してください：\n
# [文書の主題・タイトル]

**発信者（発）:** [発信者情報（あれば）]
**受信者（着）:** [受信者情報（あれば）]
**日時:** [日付・時刻情報（あれば）]

[本文全体]

発信者、受信者、日時の情報がない場合は、該当する行を省略してください。できるだけ多くのテキストを抽出し、元の文書の構造を保持してください。\n\n
最重要指示：文書の内容は必ず日本語に翻訳してください。英語や他の言語で書かれている場合は、日本語に翻訳してください。ただし、人名（John F. Kennedy、Lee Harvey Oswaldなど）、組織名（CIA、FBIなど）、地名（Dallas、Texasなど）などの固有名詞や専門用語はそのままアルファベットで保持してください。\n\n
純粋なMarkdownテキスト「だけ」を返してください。```markdownのようなコードブロック記法で囲まないでください。説明や注釈は一切含めないでください。余計なコメントや「以下が抽出結果です」などの文言は不要です。
もういちど！！！言いますが！！！日本語で出力してください！！！翻訳しろ！！！！！！！！！！
"
    }
  ]
  
  # 各画像をメッセージに追加
  image_paths.each_with_index do |image_path, index|
    base64_image = encode_image_to_base64(image_path)
    
    # 最初の画像の場合は質問を含める
    if index == 0
      content = [
        {
          type: "text",
          text: "この画像からテキストを抽出し、発信者（発）、受信者（着）、日時、主題、本文を識別してください。かならず日本語で出力すること"
        },
        {
          type: "image_url",
          image_url: {
            url: "data:image/png;base64,#{base64_image}"
          }
        }
      ]
    else
      content = [
        {
          type: "text",
          text: "これはドキュメントの続きのページです。"
        },
        {
          type: "image_url",
          image_url: {
            url: "data:image/png;base64,#{base64_image}"
          }
        }
      ]
    end
    
    messages << { role: "user", content: content }
    
  end
  
  # 最後に抽出結果を返すように指示
  messages << {
    role: "user",
    content: "以上の画像からテキストを抽出し、指示通りに処理して結果を返してください。"
  }
  
  # リトライ処理を追加（最大5回）
  max_retries = 5
  retries = 0
  result = nil
  
  while retries < max_retries
    begin
      puts "OCR処理実行中... (試行回数: #{retries + 1}/#{max_retries})"
      
      # GPT-4o-miniに送信
      response = client.chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: messages,
          temperature: 0.2,
          max_tokens: 4000
        }
      )
      
      # レスポンスからMarkdownを抽出
      result = response.dig("choices", 0, "message", "content")
      
      # 結果が取得できたら終了
      break if result && !result.empty?
      
      puts "空の結果が返されました。リトライします。"
    rescue => e
      puts "エラーが発生しました: #{e.message}"
    end
    
    retries += 1
    puts "#{retries}回目のリトライ..." if retries < max_retries
    sleep(2) # リトライ前に少し待機
  end
  
  if result.nil? || result.empty?
    puts "#{max_retries}回リトライしましたが、OCR処理に失敗しました。"
  end
  
  result
end

# 複数のチャンクを統合する関数
def integrate_chunks_with_gpt4o(client, chunks)
  puts "複数のチャンクを統合中..."
  
  messages = [
    { 
      role: "system", 
      content: "あなたはPDFドキュメントの内容を統合するアシスタントです。複数のチャンクに分割された文書の内容を受け取り、それらを一つの統一された文書にまとめてください。\n\n
文書の冒頭には必ず以下の情報を含めてください：\n
1. 文書の主題・タイトル（# で始まる見出し）\n
2. 発信者（発）の情報（あれば「**発信者（発）:** 〜」の形式で）\n
3. 受信者（着）の情報（あれば「**受信者（着）:** 〜」の形式で）\n
4. 日時の情報（あれば「**日時:** 〜」の形式で）\n\n
その後に本文を記載してください。重複する情報は削除し、内容を整理してください。できるだけ多くの情報を保持し、文書の全体像が分かるようにしてください。\n\n
最重要指示：文書の内容は必ず日本語に翻訳してください。英語や他の言語で書かれている場合は、日本語に翻訳してください。ただし、人名（John F. Kennedy、Lee Harvey Oswaldなど）、組織名（CIA、FBIなど）、地名（Dallas、Texasなど）などの固有名詞や専門用語はそのままアルファベットで保持してください。\n\n
純粋なMarkdownテキスト「だけ」を返してください。```markdownのようなコードブロック記法で囲まないでください。説明や注釈は一切含めないでください。余計なコメントや「以下が統合結果です」などの文言は不要です。"
    }
  ]
  
  # 各チャンクの内容をメッセージに追加
  chunks.each_with_index do |chunk, index|
    messages << { 
      role: "user", 
      content: "これは文書のチャンク #{index + 1}/#{chunks.size} です：\n\n#{chunk}"
    }
  end
  
  # 統合指示
  messages << {
    role: "user",
    content: "以上のチャンクを統合して、一つの統一されたMarkdown文書を作成してください。"
  }
  
  # リトライ処理を追加（最大5回）
  max_retries = 5
  retries = 0
  result = nil
  
  while retries < max_retries
    begin
      puts "チャンク統合処理実行中... (試行回数: #{retries + 1}/#{max_retries})"
      
      # GPT-4o-miniに送信
      response = client.chat(
        parameters: {
          model: "gpt-4o-mini",
          messages: messages,
          temperature: 0.2,
          max_tokens: 4000
        }
      )
      
      # レスポンスからMarkdownを抽出
      result = response.dig("choices", 0, "message", "content")
      
      # 結果が取得できたら終了
      break if result && !result.empty?
      
      puts "空の結果が返されました。リトライします。"
    rescue => e
      puts "エラーが発生しました: #{e.message}"
    end
    
    retries += 1
    puts "#{retries}回目のリトライ..." if retries < max_retries
    sleep(2) # リトライ前に少し待機
  end
  
  if result.nil? || result.empty?
    puts "#{max_retries}回リトライしましたが、チャンク統合処理に失敗しました。"
  end
  
  result
end

# 結果をMarkdownファイルに保存する関数
def save_result_to_markdown(result, pdf_path)
  pdf_basename = File.basename(pdf_path, '.pdf')
  output_path = File.join(MARKDOWN_DIR, "#{pdf_basename}.md")
  
  File.write(output_path, result)
  
  puts "Markdownファイルを保存しました: #{output_path}"
  
  # 結果を返す
  {
    path: output_path,
    content: result
  }
end

# 単一のPDFファイルを処理する関数
def process_pdf(pdf_path)
  begin
    # PDFを画像に変換
    image_paths = convert_pdf_to_images(pdf_path, TEMP_DIR)
    total_pages = image_paths.size
    puts "#{total_pages}ページの画像を生成しました"
    
    # 20ページを超える場合はチャンクに分割して処理
    if total_pages > 20
      puts "ページ数が20を超えるため、チャンクに分割して処理します"
      
      # チャンクに分割
      chunks = []
      chunk_size = 20
      num_chunks = (total_pages.to_f / chunk_size).ceil
      
      (0...num_chunks).each do |chunk_index|
        start_idx = chunk_index * chunk_size
        end_idx = [start_idx + chunk_size - 1, total_pages - 1].min
        chunk_images = image_paths[start_idx..end_idx]
        
        puts "チャンク #{chunk_index + 1}/#{num_chunks} を処理中 (ページ #{start_idx + 1}～#{end_idx + 1})"
        chunk_result = ocr_images_with_gpt4o($client, chunk_images, chunk_index + 1, num_chunks)
        chunks << chunk_result
      end
      
      # チャンクを統合
      result = integrate_chunks_with_gpt4o($client, chunks)
    else
      # 20ページ以下の場合は一度に処理
      result = ocr_images_with_gpt4o($client, image_paths)
    end
    
    # 結果をMarkdownファイルに保存
    saved_result = save_result_to_markdown(result, pdf_path)
    
    # 一時ファイルを削除
    FileUtils.rm_rf(TEMP_DIR)
    
    puts "処理が完了しました"
    return saved_result
  rescue => e
    puts "エラーが発生しました: #{e.message}"
    puts e.backtrace
    return nil
  end
end

# PDFファイルのサイズを取得する関数
def get_pdf_size(pdf_path)
  File.size(pdf_path)
end

# バッチ処理用のThorクラス
class PdfOcrBatch < Thor
  desc "ocr", "PDFファイルをOCRしてMarkdownに変換する（20ページを超えるPDFはチャンクに分割して処理）"
  option :force, type: :boolean, aliases: "-f", desc: "強制的に全ファイルを再処理する"
  option :max, type: :numeric, aliases: "-m", desc: "処理する最大ファイル数"
  def ocr
    # PDFディレクトリの設定
    pdf_dir = 'pdfs'
    
    # PDFファイルの一覧を取得
    pdf_files = Dir.glob(File.join(pdf_dir, '*.pdf'))
    
    if pdf_files.empty?
      puts "エラー: #{pdf_dir}ディレクトリにPDFファイルが見つかりません。"
      exit 1
    end
    
    puts "#{pdf_files.size}個のPDFファイルが見つかりました。"
    
    # PDFファイルをサイズ順（小さい順）にソート
    pdf_files.sort_by! { |pdf_path| get_pdf_size(pdf_path) }
    
    # 処理対象のファイルを決定
    if options[:force]
      # 強制再処理モードの場合は全ファイルを処理
      to_process = pdf_files
      puts "強制再処理モード: 全ファイルを処理します。"
    else
      # 通常モードの場合は未処理のファイルのみを処理
      processed_files = Dir.glob(File.join(MARKDOWN_DIR, '*.md')).map { |f| File.basename(f, '.md') }
      to_process = pdf_files.reject { |f| processed_files.include?(File.basename(f, '.pdf')) }
      
      puts "#{processed_files.size}個のファイルは既に処理済みです。"
      puts "#{to_process.size}個のファイルを処理します。"
    end
    
    # 最大処理ファイル数の制限
    if options[:max] && options[:max] > 0 && options[:max] < to_process.size
      original_count = to_process.size
      to_process = to_process.first(options[:max])
      puts "最大処理ファイル数の制限: #{original_count}個から#{to_process.size}個に制限しました。"
    end
    
    # 進捗状況を表示するための変数
    total_files = to_process.size
    current_file = 0
    success_count = 0
    error_count = 0
    
    # 各PDFファイルを処理
    to_process.each do |pdf_path|
      current_file += 1
      pdf_basename = File.basename(pdf_path)
      
      # 既にMarkdownファイルが存在する場合はスキップ
      markdown_path = File.join(MARKDOWN_DIR, "#{File.basename(pdf_path, '.pdf')}.md")
      if File.exist?(markdown_path) && !options[:force]
        puts "スキップ: #{pdf_basename} (既にMarkdownファイルが存在します)"
        next
      end
      
      # 進捗率を計算して表示
      progress_percent = (current_file.to_f / total_files * 100).round(2)
      progress_bar = "["
      progress_bar += "=" * (progress_percent / 5).to_i
      progress_bar += " " * (20 - (progress_percent / 5).to_i)
      progress_bar += "]"
      
      puts "\n#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 処理中: #{pdf_basename}"
      
      # PDFを処理
      if process_pdf(pdf_path)
        success_count += 1
        puts "#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 成功: #{pdf_basename}"
      else
        error_count += 1
        puts "#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 失敗: #{pdf_basename}"
      end
    end
    
    # 最終結果の表示
    puts "\n処理完了:"
    puts "合計: #{total_files}ファイル"
    puts "成功: #{success_count}ファイル"
    puts "失敗: #{error_count}ファイル"
    if !options[:force]
      puts "既に処理済み: #{processed_files.size}ファイル"
    end
  end
  
  desc "version", "バージョン情報を表示する"
  def version
    puts "PdfOcrBatch v1.0.0"
  end
  
  default_task :ocr
end

# スクリプトの実行
PdfOcrBatch.start(ARGV)
