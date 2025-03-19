#!/usr/bin/env ruby
require 'json'
require 'nokogiri'

# Get all PDF files in the pdfs directory
pdf_files = Dir.glob('pdfs/*.pdf').map { |path| File.basename(path) }
puts "Found #{pdf_files.size} PDF files in pdfs/ directory"

# Parse the index.html file to extract PDF links
html_content = File.read('index.html')
doc = Nokogiri::HTML(html_content)

# Extract all PDF links from the table
pdf_links = {}
doc.css('table.datatable a').each do |link|
  href = link.attr('href')
  filename = link.text.strip
  
  # Skip if not a PDF link
  next unless href && href.end_with?('.pdf')
  
  # Store the full URL (base + path)
  base_url = "https://www.archives.gov"
  full_url = base_url + href
  
  pdf_links[filename] = full_url
end

puts "Found #{pdf_links.size} PDF links in index.html"

# Create mapping between local PDFs and URLs
pdf_mapping = {}
pdf_files.each do |pdf_file|
  if pdf_links.key?(pdf_file)
    pdf_mapping[pdf_file] = pdf_links[pdf_file]
  else
    # Try to find a match with different formatting or special characters
    matching_key = pdf_links.keys.find { |k| k.gsub(/\s+|\(|\)/, '') == pdf_file.gsub(/\s+|\(|\)/, '') }
    if matching_key
      pdf_mapping[pdf_file] = pdf_links[matching_key]
    else
      puts "No URL found for: #{pdf_file}"
      pdf_mapping[pdf_file] = nil
    end
  end
end

# Write the mapping to pdf_link.json
File.write('pdf_link.json', JSON.pretty_generate(pdf_mapping))
puts "Created pdf_link.json with #{pdf_mapping.size} entries"