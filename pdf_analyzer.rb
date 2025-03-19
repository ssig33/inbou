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
end

require 'json'
require 'fileutils'
require 'openai'
require 'base64'
require 'tempfile'

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
OUTPUT_DIR = 'outputs'
FileUtils.mkdir_p(OUTPUT_DIR) unless Dir.exist?(OUTPUT_DIR)

# 一時ディレクトリの作成
TEMP_DIR = File.join(Dir.tmpdir, "pdf_analyzer_#{Time.now.to_i}")
FileUtils.mkdir_p(TEMP_DIR)

# PDFを画像に変換する関数
def convert_pdf_to_images(pdf_path, output_dir)
  puts "PDFを画像に変換中: #{pdf_path}"
  
  # PDFのファイル名（拡張子なし）を取得
  pdf_basename = File.basename(pdf_path, '.pdf')
  
  # 出力ディレクトリを作成
  FileUtils.mkdir_p(output_dir)
  
  # Popplerのpdftoppmを使用してPDFを画像に変換
  # -r 150: 解像度を150 DPIに設定
  # -png: PNG形式で出力
  # -singlefile: 各ページを個別のファイルとして出力
  # 最後の引数はプレフィックス（出力ファイル名の先頭部分）
  cmd = "pdftoppm -r 150 -png \"#{pdf_path}\" \"#{output_dir}/#{pdf_basename}\""
  
  puts "実行コマンド: #{cmd}"
  result = system(cmd)
  
  unless result
    puts "エラー: PDFの変換に失敗しました。Popplerがインストールされているか確認してください。"
    puts "インストール方法: sudo apt-get install poppler-utils (Ubuntu) または brew install poppler (macOS)"
    exit 1
  end
  
  # 生成された画像ファイルのパスを返す
  # pdftoppmは「プレフィックス-ページ番号.png」という形式でファイルを生成する
  # 例: basename-1.png, basename-2.png, ...
  Dir.glob(File.join(output_dir, "#{pdf_basename}-*.png")).sort
end

# 画像をBase64エンコードする関数
def encode_image_to_base64(image_path)
  File.open(image_path, 'rb') do |img|
    Base64.strict_encode64(img.read)
  end
end

# 画像をGPT-4o-miniで分析する関数
def analyze_images_with_gpt4o_mini(client, image_paths)
  puts "画像を分析中..."
  
  # 各画像をBase64エンコードしてメッセージに追加
  messages = [
    { role: "system", content: "あなたはPDFドキュメントの分析を行うアシスタントです。提供された画像を分析し、以下の情報を日本語で提供してください：\n1. これはジョン・Fケネディ大統領暗殺事件に関連するファイルかどうか\n2. ケネディ暗殺の顛末を知る上で重要なファイルかどうか（boolean）\n3. 重要な場合は、内容の要約（構造化されたMarkdown形式）\n4. 重要な場合は、文書のわかりやすいタイトル" }
  ]
  
  # 各画像をメッセージに追加
  image_paths.each_with_index do |image_path, index|
    base64_image = encode_image_to_base64(image_path)
    
    # 最初の画像の場合は質問を含める
    if index == 0
      content = [
        { type: "text", text: "このPDFドキュメントを分析してください。これはジョン・Fケネディ大統領暗殺事件に関連するファイルですか？ケネディ暗殺の顛末を知る上で重要なファイルですか？" },
        { type: "image_url", image_url: { url: "data:image/png;base64,#{base64_image}" } }
      ]
    else
      content = [
        { type: "text", text: "これはドキュメントの続きのページです。" },
        { type: "image_url", image_url: { url: "data:image/png;base64,#{base64_image}" } }
      ]
    end
    
    messages << { role: "user", content: content }
  end
  
  # 最後に分析結果をJSON形式で返すように指示
  messages << { 
    role: "user", 
    content: "以上の画像を分析して、以下のJSON形式で結果を返してください：\n```json\n{\n  \"is_kennedy_assassination\": boolean,\n  \"important\": boolean,\n  \"title\": \"重要な場合のみタイトル\",\n  \"summary\": \"重要な場合のみMarkdown形式の要約。ある程度具体的な事実も分かりやすく示すこと。\"\n}\n```" 
  }
  
  # GPT-4o-miniに送信
  response = client.chat(
    parameters: {
      model: "gpt-4o-mini",
      messages: messages,
      temperature: 0.2,
      response_format: { type: "json_object" }
    }
  )
  
  # レスポンスからJSONを抽出
  json_response = response.dig("choices", 0, "message", "content")
  begin
    JSON.parse(json_response)
  rescue JSON::ParserError => e
    puts "エラー: JSONの解析に失敗しました: #{e.message}"
    puts "レスポンス: #{json_response}"
    { "error" => "JSONの解析に失敗しました", "raw_response" => json_response }
  end
end

# 結果をファイルに保存する関数
def save_result_to_file(result, pdf_path, total_pages = nil, limited_pages = nil)
  pdf_basename = File.basename(pdf_path, '.pdf')
  output_path = File.join(OUTPUT_DIR, "#{pdf_basename}.json")
  
  # ページ数制限の情報を追加
  if total_pages && limited_pages && total_pages > limited_pages
    result["page_info"] = {
      "total_pages" => total_pages,
      "analyzed_pages" => limited_pages,
      "note" => "ページ数が#{limited_pages}を超えるため、最初の#{limited_pages}ページのみを分析しました"
    }
  end
  
  # 重要でない場合は簡略化した結果を保存
  if result["important"] == false
    simplified_result = { "important" => false }
    # ページ数制限の情報があれば追加
    simplified_result["page_info"] = result["page_info"] if result["page_info"]
    File.write(output_path, JSON.pretty_generate(simplified_result))
  else
    File.write(output_path, JSON.pretty_generate(result))
  end
  
  puts "分析結果を保存しました: #{output_path}"
end

# メイン処理
def main
  # コマンドライン引数からPDFファイルのパスを取得
  pdf_path = ARGV[0]
  
  if pdf_path.nil? || !File.exist?(pdf_path)
    puts "使用方法: ruby pdf_analyzer.rb <pdf_file_path>"
    puts "例: ruby pdf_analyzer.rb pdfs/document.pdf"
    exit 1
  end
  
  begin
    # PDFを画像に変換
    image_paths = convert_pdf_to_images(pdf_path, TEMP_DIR)
    total_pages = image_paths.size
    puts "#{total_pages}ページの画像を生成しました"
    
    # ページ数が30を超える場合は最初の30ページのみを処理
    if total_pages > 30
      puts "ページ数が30を超えるため、最初の30ページのみを処理します"
      image_paths = image_paths.first(30)
    end
    
    # 画像を分析
    result = analyze_images_with_gpt4o_mini($client, image_paths)
    puts "分析結果: #{result.inspect}"
    
    # 結果を保存（ページ数情報を含める）
    save_result_to_file(result, pdf_path, total_pages, image_paths.size)
    
    # 一時ファイルを削除
    FileUtils.rm_rf(TEMP_DIR)
    
    puts "処理が完了しました"
  rescue => e
    puts "エラーが発生しました: #{e.message}"
    puts e.backtrace
    exit 1
  end
end

# スクリプトの実行
main