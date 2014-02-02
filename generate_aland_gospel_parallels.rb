#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'nokogiri'
require 'string-urlize'
require 'uri'

class ESVAPI
  def self.is_blank? node
    (node.text? && node.content.strip == '') || (node.element? && node.name == 'br')
  end

  def self.all_children_are_blank? node
    node.children.all? {|child| self.is_blank?(child)}
  end

  def self.get reference
    key = 'beff9d1aa1762bbd'

    # Replace " " with "+"; ":" with "%3A". Required for ESV API request.
    modified_reference = reference.gsub(/\s/, '+').gsub(/:/, '%3A')

    # Build ESV API request URL.
    uri = URI.parse("http://www.esvapi.org/v2/rest/passageQuery?key=#{key}&passage=#{modified_reference}&include-passage-references=false&include-first-verse-numbers=false&include-verse-numbers=false&include-footnotes=false&include-short-copyright=false&include-headings=false&include-subheadings=false")
    http = Net::HTTP.new(uri.host, uri.port)
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    html = ""
    if response.code == "200"
      html = response.body.gsub(/\d+:1&nbsp;/, "")
    end

    doc = Nokogiri::XML(html)
    doc.css("div.block-indent").each do |div|
      blockquote_node = doc.create_element("blockquote")
      blockquote_node.inner_html = div.inner_html
      div.replace(blockquote_node)
    end

    #doc.css("p.line-group").each do |node|
    #  node.swap(node.children)
    #end

    doc.css("span.indent").each do |node|
      node.remove
    end

    #doc.css("p").find_all {|p| self.all_children_are_blank?(p)}.each do |p|
    #  p.remove
    #end

    # http://stackoverflow.com/questions/8937846/how-do-i-wrap-html-untagged-text-with-p-tag-using-nokogiri
    #doc.search("//br/preceding-sibling::text()|//br/following-sibling::text()").each do |node|
    #  if node.content !~ /\A\s*\Z/
    #    node.replace(doc.create_element('p', node))
    #  end
    #end
    #
    #doc.css("br").remove

    doc.root.to_s
  end
end

class GospelParallelsGenerator
  attr_accessor :json_string, :data
  attr_accessor :entries

  def initialize
    @entries = []
    load_data
  end

  def load_data
    uri = URI.parse("https://spreadsheets.google.com/feeds/list/0Ap3gNqa5sPMqdF8tVXZNcGViOFQxTm5tUFM5ZXcyZ1E/od6/public/values?alt=json")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)

    if response.code == "200"
      @json_string = response.body
      @data = JSON.parse(response.body)
    end
  end

  def process_data limit = -1
    count = 0
    @data['feed']['entry'].each do |entry_data|
      break if count == limit

      entry = GospelParallelsEntry.new(entry_data)
      @entries.push(entry)

      count += 1
    end
  end

  def entries_to_markdown
    puts "# Gospel Parallels\n\n"

    current_section = ""
    @entries.each do |entry|
      if entry.section != current_section
        puts "## #{entry.section} ([\^](##{entry.section_toc_url}))<a name=\"#{entry.section_url}\"></a>\n"
        current_section = entry.section
      end
      puts entry.to_markdown
    end
  end

  def toc_to_markdown
    puts "# Table of Contents<a name=\"pericopetoc\"></a>\n\n"

    current_section = ""
    @entries.each do |entry|
      if entry.section != current_section
        puts "+ [#{entry.section}](##{entry.section_url})<a name=\"#{entry.section_toc_url}\"></a>\n"
        current_section = entry.section
      end
      puts "    + [#{entry.num}. #{entry.pericope}](##{entry.url})<a name=\"#{entry.toc_url}\"></a>\n"
    end
    puts "\n"
  end
end

class GospelParallelsEntry
  @@SEARCH_QUERY = "http://www.esvbible.org/"
  @@SIMPLE_SEARCH_QUERY = "http://www.gnpcb.org/esv/mobile/?q="

  attr_accessor :num, :pericope, :section
  attr_accessor :all_references, :essential_references, :additional_references

  def initialize entry_data
    @num = entry_data["gsx$no."]["$t"]
    @pericope = entry_data["gsx$pericope"]["$t"].split(" ").map(&:capitalize).join(" ")
    @section = entry_data["gsx$section"]["$t"]
    @all_references = []
    @essential_references = []
    @additional_references = []

    references = {}
    references[:matthew] = entry_data["gsx$matthew"]["$t"].strip
    references[:mark] = entry_data["gsx$mark"]["$t"].strip
    references[:luke] = entry_data["gsx$luke"]["$t"].strip
    references[:john] = entry_data["gsx$john"]["$t"].strip

    process_references(references)
  end

  def process_references references
    references.each do |key, value|
      book = key.to_s.capitalize
      book_references = value.split(';')
      if book_references.count > 1
        book_references.collect {|book_reference| book_reference.strip!}
      end

      if value.start_with?("1 Cor.")
        @all_references.push(value)
        @essential_references.push(value)
      else
        book_references.each do |book_reference|
          if book_reference.include?("*")
            @all_references.push("#{book} #{book_reference.chop}")
            @essential_references.push("#{book} #{book_reference.chop}")
          else
            @all_references.push("#{book} #{book_reference}")
            @additional_references.push("#{book} #{book_reference}")
          end
        end
      end
    end
  end

  def url
    "entry-#{num}"
  end

  def toc_url
    "entry-#{num}-toc"
  end

  def section_url
    "section-#{@section.urlize}"
  end

  def section_toc_url
    "section-#{@section.urlize}-toc"
  end

  def to_debug
    output = "No. #{num}: #{pericope}"
    output << "\nESSENTIAL: " + @@SEARCH_QUERY + URI.escape(@essential_references.join("; ")) unless @essential_references.empty?
    output << "\nADDITIONAL: " + @@SEARCH_QUERY + URI.escape(@additional_references.join("; ")) unless @additional_references.empty?
    output << "\nALL: " + @@SEARCH_QUERY + URI.escape((@all_references).join("; ")) unless @all_references.empty?
    output << "\n"
  end

  def to_markdown
    output = "\n### #{num}. #{pericope}<a name=\"#{self.url}\"></a> ([^](##{self.toc_url}))"

    if @essential_references.count > 0 and @additional_references.count > 0
      output << "\nEssential Verses:"
      @essential_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)});"
      end
      output.chop!
      output << " ([All](#{@@SEARCH_QUERY + URI.escape(@essential_references.join("; "))}))" if @essential_references.count > 1
    end

    if @additional_references.count > 0 and @additional_references.count > 0
      output << "\nAdditional Verses:"
      @additional_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)});"
      end
      output.chop!
      output << " ([All](#{@@SEARCH_QUERY + URI.escape(@additional_references.join("; "))}))" if @additional_references.count > 1
    end

    if true #@essential_references.count == 0 or @additional_references.count == 0
      output << "\nAll Verses:"
      @all_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)});"
      end
      output.chop!
      output << " ([All](#{@@SEARCH_QUERY + URI.escape(@all_references.join("; "))}))"
    end

    @all_references.each do |reference|
      output << "\n\n#### #{reference}"
      output << "\n#{ESVAPI.get(reference)}"
    end

    output
  end
end

if __FILE__ == $0
  generator = GospelParallelsGenerator.new
  generator.process_data
  generator.toc_to_markdown
  generator.entries_to_markdown
end
