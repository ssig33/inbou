# bundler/inline を使ってライブラリをインストール
# 必要なライブラリをbundlerでインストールする
# インラインでライブラリを指定する

# gem "nokogiri" を指定
# gem "open-uri" と "uri" は標準ライブラリなので、指定しなくてもよい
require 'bundler/inline'

# 必要なライブラリをインストールする
gemfile do
  source 'https://rubygems.org'
  gem 'nokogiri'
end

# HTMLファイルの処理
require 'nokogiri'
require 'open-uri'
require 'uri'

# 引数で指定されたファイルパスを取得
file_path = ARGV[0]
if file_path.nil? || !File.exist?(file_path)
  puts "エラー: ファイルが指定されていないか存在しません。"
  exit
end

# HTMLファイルを読み込む
html_content = File.read(file_path)
doc = Nokogiri::HTML(html_content)

# PDFリンクを抽出
pdf_links = doc.css('a').map { |link| link['href'] }.select { |href| href =~ /\.pdf$/i }

# PDFを保存するディレクトリを作成
pdfs_dir = "pdfs"
Dir.mkdir(pdfs_dir) unless Dir.exist?(pdfs_dir)

# 進捗状況を表示するための変数
total_pdfs = pdf_links.size
current_pdf = 0
skipped_count = 0

# PDFリンクをwgetでダウンロード（最大5回リトライ）
pdf_links.each do |link|
  current_pdf += 1
  
  # 相対パスか絶対パスかを判断
  uri_str = if link.start_with?('http://', 'https://')
    link
  else
    "https://www.archives.gov#{link}"
  end
  
  # URLをエスケープして安全にする
  uri_str = URI.encode_www_form_component(uri_str)
  uri_str = uri_str.gsub('%2F', '/').gsub('%3A', ':')  # スラッシュとコロンは戻す
  uri = URI(uri_str)
  
  # ファイル名を取得（元のリンクから取得）
  filename = File.basename(link)
  output_path = File.join(pdfs_dir, filename)
  
  # 進捗率を計算して表示
  progress_percent = (current_pdf.to_f / total_pdfs * 100).round(2)
  progress_bar = "["
  progress_bar += "=" * (progress_percent / 5).to_i
  progress_bar += " " * (20 - (progress_percent / 5).to_i)
  progress_bar += "]"
  
  # ファイルが既に存在するかチェック
  if File.exist?(output_path) && File.size(output_path) > 0
    skipped_count += 1
    puts "#{progress_bar} #{progress_percent}% (#{current_pdf}/#{total_pdfs}) スキップ: #{filename} (既に存在します)"
    next
  end
  
  download_success = false
  retries = 0

  while retries < 5 && !download_success
    retries += 1
    puts "#{progress_bar} #{progress_percent}% (#{current_pdf}/#{total_pdfs}) ダウンロード中: #{filename} (試行回数: #{retries})"
    
    # --quietオプションを追加してwgetのログを抑制
    system("wget --quiet --tries=1 --timeout=30 -O \"#{output_path}\" \"#{uri}\"")

    # 成功した場合
    if $?.exitstatus == 0
      download_success = true
      puts "#{progress_bar} #{progress_percent}% (#{current_pdf}/#{total_pdfs}) 成功: #{filename}"
    else
      puts "#{progress_bar} #{progress_percent}% (#{current_pdf}/#{total_pdfs}) 失敗: #{filename} - 再試行します..."
    end
  end

  unless download_success
    puts "#{progress_bar} #{progress_percent}% (#{current_pdf}/#{total_pdfs}) 失敗: #{filename} - 最大試行回数に達しました"
  end
end

# 最終結果の表示
puts "\n処理完了:"
puts "合計: #{total_pdfs}ファイル"
puts "ダウンロード: #{total_pdfs - skipped_count}ファイル"
puts "スキップ: #{skipped_count}ファイル"
