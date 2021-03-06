#!/usr/bin/env ruby
# -*- coding: utf-8 -*-
require 'rubygems'
require 'iconv'
require 'fileutils'
require 'cgi'
require 'fastercsv'
require 'hpricot'
require 'activesupport' # for Date calculations
require File.expand_path(File.join(File.dirname( __FILE__),
                                   'scraper_common'))


class LegislatorDetailsScraper
  include ScrapingHelper

  def initialize(opts={})
    @options = opts

    # Base directory where parsed data is going to be stored
    @data_path = File.expand_path(@options[:data_dir])

    # Directory to store the raw HTML pages we're scraping
    @source_data_path = File.expand_path(@options[:source_data_dir])

    # Path for the CSV where we get the legislator names and chamber_ids
    @legislator_index_csv = File.join(@data_path, 'br', 'chamber', '2007-2010',
                                      'legislator_index.csv')

    # Detail pages come in iso-8859-1, we need utf-8
    @isolatin_to_utf8 = Iconv.new('UTF-8', 'iso-8859-1')

    @bio_base_url = "http://www2.camara.gov.br/internet/deputados/" +
      "biodeputado/index.html?nome=%s&leg=53"
    @bio_file_selector = File.join(@source_data_path,
                                   url_path(@bio_base_url),
                                   'index.html*')

    @detail_base_url = "http://www.camara.gov.br/internet/deputado/" +
      "Dep_Detalhe.asp?id=%d"
    @detail_file_selector = File.join(@source_data_path,
                                      url_path(@detail_base_url),
                                      'Dep_Detalhe.asp*')

    @photo_base_url = "http://www.camara.gov.br/internet/deputado/fotos/%s.jpg"
  end

  def url_escape(string)
    iconv = Iconv.new('iso-8859-1', 'utf-8')
    CGI.escape(iconv.iconv(string))
  end

  def run!
    get! unless @options[:noget]
    parse! unless @options[:noparse]
  end

  # convert 2-digit year string to Date object with year (Jan 1st)
  def to_date(two_digit_year)
    year = two_digit_year.to_i
    year > 69 ? Date.new(1900 + year) : Date.new(2000 + year)
  end

  def get!
    FasterCSV.foreach(@legislator_index_csv, :headers => true) do |row|
      Dir.chdir(@source_data_path) do
        bio_url = @bio_base_url % url_escape(row['nickname'])
        puts "Downloading bio for #{row['nickname']} " +
          "(chamber_id=#{row['chamber_id']})..."
        `wget -x "#{bio_url}"`

        detail_url = @detail_base_url % row['chamber_id']
        puts "Downloading details for #{row['nickname']} " +
          "(chamber_id=#{row['chamber_id']})..."
        `wget -x "#{detail_url}"`

        photo_name = strip_diacritics(row['nickname']).downcase.gsub(/\s/, '')
        photo_url = @photo_base_url % photo_name
        puts "Downloading photo for #{row['nickname']} " +
          "(chamber_id=#{row['chamber_id']})..."
        `wget -x "#{photo_url}"`
      end
    end
  end

  def parse!
    output_path = File.join(@data_path, 'br', 'chamber', '2007-2010',
                            'legislators')
    FileUtils.mkpath(output_path)

    legislators = []

    # Scrape profile details for each legislator
    Dir[@detail_file_selector].each do |filepath|
      legislator = {}
      legislator[:chamber_id] = File.basename(filepath).split('?id=').last.to_i

      puts "Parsing id #{legislator[:chamber_id]}"

      doc = Hpricot(@isolatin_to_utf8.iconv(File.read(filepath)))

      # Parsing political name.
      # - sample html:
      # <div id="depInfo"> <!-- *********************************************************** -->

      # <span style="font-size:1.3em"><strong>PERPÉTUA ALMEIDA                   </strong></span>
      legislator[:political_name] = doc.search('div#depInfo').search('span').
        first.inner_text.strip

      # Parsing info from the first paragraph.
      # - Sample url: http://www.camara.gov.br/internet/deputado/Dep_Detalhe.asp?id=520068
      # - Sample html:
      #     	<p>Nome Civil: <span>MARIA PERPÉTUA ALMEIDA</span><br>
      # Aniversário: <span>28 / 12</span> - Profissão: <span>Professora e Bancária</span><br>
      # Partido/UF: <span>PCdoB   </span> - <span>AC</span> - <span>Titular</span><br>

      #     Gabinete: <span>625</span> - Anexo: <span>IV</span>&nbsp; - Telefone:(61) <span>3215-5625</span> - Fax:(61) <span>3215-2625</span><br>

      # Legislaturas: <span>03/07 07/11 </span><br>
      #     	</p>
      paragraph = doc.search('p').first.inner_text

      regexps = {
        :full_name => /Nome Civil: (.*)/,
        :profession => /Profissão: (.*)/,
        :party_code => /Partido\/UF: (\w*)/,
        :state_code => /Partido\/UF:.*- ([A-Z]{2})/,
        :took_seat_as => /Partido\/UF:.*-.*- (.*)/,
        :phone_number => /Telefone:(\(\d{2}\) \d{4}-\d{4})/,
        :fax_number => /Fax:(\(\d{2}\) \d{4}-\d{4})/,
        :legislatures => /Legislaturas: (.*)/
      }

      regexps.each do |key, regexp|
        legislator[key] = nil

        paragraph.each do |line|
          if line =~ regexp
            legislator[key] = $1.strip
            break
          end
        end
      end

      legislator[:subscription_number] = doc.html =~ /nuMatricula=(\d+)/ ? $1 :
        nil
      legislator[:email_address] = doc.html =~ /mailto:(.+?\.br)/ ? $1 : nil

      legislator[:mailing_address] = (doc/'.depAreaConteudo').last.inner_text.
        map {|line| line.strip }.reject {|line| line.empty? }.join("\n")

      if legislator[:legislatures]
        legislator[:legislatures] = legislator[:legislatures].split(' ').
          map {|year_range|
          start, finish = year_range.split('/')

          # the 'finish' year is actually the year when the next
          # legislature begins, so we remove 1 day to get Dec 31st
          # from the previous year
          [to_date(start), to_date(finish) - 1.day]
        }
      end

      output_file_name = "#{legislator[:chamber_id]}-" +
        "#{strip_diacritics(legislator[:full_name]).downcase.gsub(/\s/, '-')}"

      output_file_path = File.join(output_path, output_file_name + '.json')
      File.open(output_file_path, 'w') {|f| f << legislator.to_json }

      puts "Parsed details for #{legislator[:full_name]} " +
           "(chamber_id=#{legislator[:chamber_id]})..."
      legislators << legislator
    end

    File.open(File.join(output_path, 'all.json'), 'w') do |f|
      f << JSON.generate(legislators)
    end
  end
end

if __FILE__ == $0
  options = ScraperOptions.parse(ARGV)
  puts ARGV.inspect
  puts options.inspect
  f = LegislatorDetailsScraper.new(options)
  f.run!
end
