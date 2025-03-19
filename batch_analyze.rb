#!/usr/bin/env ruby
# encoding: utf-8

# PDFファイルを一括処理するスクリプト

require 'bundler/inline'

# 必要なライブラリをインストール
gemfile do
  source 'https://rubygems.org'
  gem 'thor'
  gem 'fileutils'
end

require 'thor'
require 'fileutils'

class BatchAnalyze < Thor
  desc "analyze", "PDFファイルを一括処理する（30ページを超えるPDFは最初の30ページのみ処理）"
  option :force, type: :boolean, aliases: "-f", desc: "強制的に全ファイルを再処理する"
  option :max, type: :numeric, aliases: "-m", desc: "処理する最大ファイル数"
  def analyze
    # PDFディレクトリとoutputsディレクトリの設定
    pdf_dir = 'pdfs'
    output_dir = 'outputs'

    # outputsディレクトリが存在しない場合は作成
    FileUtils.mkdir_p(output_dir) unless Dir.exist?(output_dir)

    # PDFファイルの一覧を取得
    pdf_files = Dir.glob(File.join(pdf_dir, '*.pdf')).sort

    if pdf_files.empty?
      puts "エラー: #{pdf_dir}ディレクトリにPDFファイルが見つかりません。"
      exit 1
    end

    puts "#{pdf_files.size}個のPDFファイルが見つかりました。"

    # 処理対象のファイルを決定
    if options[:force]
      # 強制再処理モードの場合は全ファイルを処理
      to_process = pdf_files
      puts "強制再処理モード: 全ファイルを処理します。"
    else
      # 通常モードの場合は未処理のファイルのみを処理
      processed_files = Dir.glob(File.join(output_dir, '*.json')).map { |f| File.basename(f, '.json') }
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
      
      # 進捗率を計算して表示
      progress_percent = (current_file.to_f / total_files * 100).round(2)
      progress_bar = "["
      progress_bar += "=" * (progress_percent / 5).to_i
      progress_bar += " " * (20 - (progress_percent / 5).to_i)
      progress_bar += "]"
      
      puts "\n#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 処理中: #{pdf_basename}"
      
      # pdf_analyzer.rbを実行
      begin
        command = "OPENAI_API_KEY='#{ENV['OPENAI_API_KEY']}' ruby pdf_analyzer.rb \"#{pdf_path}\""
        puts "実行コマンド: #{command}"
        
        # コマンドを実行
        result = system(command)
        
        if result
          success_count += 1
          puts "#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 成功: #{pdf_basename}"
        else
          error_count += 1
          puts "#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) 失敗: #{pdf_basename}"
        end
      rescue => e
        error_count += 1
        puts "#{progress_bar} #{progress_percent}% (#{current_file}/#{total_files}) エラー: #{pdf_basename} - #{e.message}"
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
    
    puts "\n注意: 30ページを超えるPDFファイルは最初の30ページのみが処理されます"
  end

  desc "version", "バージョン情報を表示する"
  def version
    puts "BatchAnalyze v1.0.0"
  end

  default_task :analyze
end

BatchAnalyze.start(ARGV)