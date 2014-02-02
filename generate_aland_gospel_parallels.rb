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
    key = '8f1a04b76ba6af79'

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

    #File.open('debug.out', 'a') { |f| f.write("OUTPUTTING (#{reference}):\n#{doc.to_s}\n\n\n") }

    doc.css("div.block-indent").each do |div|
      blockquote_node = doc.create_element("blockquote")
      blockquote_node.inner_html = div.inner_html
      div.replace(blockquote_node)
    end

    doc.css("div.esv-text").each do |node|
      node.swap(node.children)
    end

    doc.css("span.indent, span.chapter-num").each do |node|
      node.remove
    end

    doc.xpath('//@class').remove
    doc.xpath('//@id').remove

    doc.root['class'] = "esv-text"

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

    output = ""
    doc.root.to_s.each_line do |line|
      output << line.sub(/^\s*/, '    ') if line != "\n"
    end

    output
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
    puts "\n<div id=\"gospel-synopsis\" markdown=\"1\">\n\n"
    puts "## Gospel Synopsis\n"

    current_section = ""
    @entries.each do |entry|
      if entry.section != current_section
        puts "\n### <a name=\"#{entry.section_url}\"></a>#{entry.section} <span class=\"toc-jump\">[&and;](##{entry.section_toc_url} \"Go to the Table of Contents\")</span>\n"
        current_section = entry.section
      end
      puts entry.to_markdown
    end
    puts "\n</div>\n"
  end

  def header_to_markdown
    puts "# A Harmony of the Gospel\n\n"
    puts "Derived from _Synopsis Quattuor Evangeliorum_ by **Kurt Aland**.\n"
  end

  def toc_to_markdown
    puts "\n<div id=\"table-of-contents\" markdown=\"1\">\n\n"
    puts "## <a name=\"toc\"></a>Table of Contents\n\n"

    current_section = ""
    @entries.each do |entry|
      if entry.section != current_section
        puts "+ <a name=\"#{entry.section_toc_url}\"></a>[#{entry.section}](##{entry.section_url})\n"
        current_section = entry.section
      end
      puts "    + <a name=\"#{entry.toc_url}\"></a>[#{entry.num}. #{entry.pericope}](##{entry.url})\n"
    end
    puts "\n</div>\n"
  end
end

class GospelParallelsEntry
  @@SEARCH_QUERY = "http://www.esvbible.org/"
  @@SIMPLE_SEARCH_QUERY = "http://www.gnpcb.org/esv/mobile/?q="

  attr_accessor :num, :pericope, :section
  attr_accessor :all_references, :essential_references, :additional_references

  def initialize entry_data
    @num = entry_data["gsx$no."]["$t"]
    @pericope = entry_data["gsx$pericope"]["$t"].split(" ").map(&:capitalize).join(" ").sub(/\(./) do |w|
      w.upcase
    end
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

  def to_markdown
    output = "\n+ #### <a name=\"#{self.url}\"></a>#{num}. #{pericope} <span class=\"toc-jump\">[&and;](##{self.toc_url} \"Go to the Table of Contents\")</span>"
    output << "\n\n    <p class=\"entry-references\" markdown=\"1\">"

    if @essential_references.count > 0 and @additional_references.count > 0
      output << "\n    Essential Verses:"
      @essential_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)} \"Read #{reference} on esvbible.org\");"
      end
      output.chop!
      output << " &mdash; [All](#{@@SEARCH_QUERY + URI.escape(@essential_references.join("; "))} \"Read essential verses on esvbible.org\")" if @essential_references.count > 1
      output << "  "
    end

    if @additional_references.count > 0 and @additional_references.count > 0
      output << "\n    Additional Verses:"
      @additional_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)} \"Read #{reference} on esvbible.org\");"
      end
      output.chop!
      output << " &mdash; [All](#{@@SEARCH_QUERY + URI.escape(@additional_references.join("; "))} \"Read additional verses on esvbible.org\")" if @additional_references.count > 1
      output << "  "
    end

    if true #@essential_references.count == 0 or @additional_references.count == 0
      (@additional_references.count > 0 and @additional_references.count > 0) ? output << "\n    All Verses:" : output << "\n    Verses:"
      @all_references.each do |reference|
        output << " [#{reference}](#{@@SEARCH_QUERY + URI.escape(reference)} \"Read #{reference} on esvbible.org\");"
      end
      output.chop!
      output << " &mdash; [All](#{@@SEARCH_QUERY + URI.escape(@all_references.join("; "))} \"Read all verses on esvbible.org\")" if @all_references.count > 1
    end
    output << "\n    </p>"

    output << "\n\n    <div class=\"entry-verses\">"
    @all_references.each do |reference|
      output << "\n\n    <h5>#{reference}</h5>"
      output << "\n#{ESVAPI.get(reference)}"
    end
    output << "\n\n    </div>"

    output
  end
end

if __FILE__ == $0
  generator = GospelParallelsGenerator.new
  generator.process_data
  generator.header_to_markdown
  generator.toc_to_markdown
  generator.entries_to_markdown
end
