=begin
    Copyright 2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

		All adjustments made by @author Christian Pedaschus <chris@sbits.ac>
		use the original license. Thanks 'Zapotek' :)

=end

require 'ap'
require 'nokogiri'
require 'sass'
require 'fileutils'


## Monkey Patch Sass so we can parse CSS3, found on stackoverflow, thanks
class Sass::Tree::Visitors::ToArray < Sass::Tree::Visitors::Base
  protected

  def initialize
    @array = []
  end

  def visit(node, parent = false)
    if node_name(parent) == "root"
      @media = "all"
    end

    method = "visit_#{node_name(node)}"

    if self.respond_to?(method, true)
      self.send(method, node)
    else
      visit_children(node)
    end

    @array
  end

  def visit_children(parent)
    parent.children.map {|c| visit(c, parent)}
  end

  def visit_root(node)
    visit_children(node)
  end

  def visit_media(node)
    @media = node.query.join('')
    visit_children(node)
  end

  def visit_rule(node)
    @selector = node.rule[0]
    visit_children(node)
  end

  def visit_prop(node)
    return unless node.value

    @array << {
      media: @media,
      selector: @selector,
      property: node.name[0],
      value: node.value.to_sass
    }
  end
end

class Sass::Tree::Node
  def to_a
    Sass::Tree::Visitors::ToArray.visit(self)
  end
end

#
# Crawls the target webapp until there are no new paths left.
#
# Path extraction and distribution are handled by outside agents.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Roundabout::Crawler
	include Roundabout::Utilities

	# @return [Hash]    instance options
	attr_reader :opts

	# @return [Set]    live sitemap, constantly updated during the crawl
	attr_reader :sitemap

	# @return HTTP interface in use
	attr_reader :http
	# @return path extractor in use
	attr_reader :path_extractor
	# @return ajax path extractor in use
	attr_reader :ajax_path_extractor
	# @return css path extractor in use
	attr_reader :css_path_extractor
	# @return distributor in use
	attr_reader :distributor

	#
	# @param    [Hash]  opts    instance options
	#                               * url: url to crawl
	#
	# @param    [Hash]  interfaces  custom interfaces to use
	#                               * http: must implement {Roundabout::HTTP} (defaults to {Roundabout::HTTP})
	#                               * path_extractor: must implement {Roundabout::PathExtractor} (defaults to {Roundabout::PathExtractor})
	#                               * css_path_extractor: must implement {Roundabout::CssPathExtractor} (defaults to {Roundabout::CssPathExtractor})
	#                               * distributor: must implement {Roundabout::Distributor} (defaults to {Roundabout::Distributor})
	#                               if no Distributor is provided no other nodes will be utilised.
	#
	def initialize(opts, interfaces = {})
		@opts = opts
		@url = @opts[:url]
		@now = Time.now
		@sitemap = Set.new
		@paths = [@url]
		@html_paths = []

		@http = interfaces[:http] || Roundabout::HTTP.new(@opts)
		@path_extractor = interfaces[:path_extractor] || Roundabout::PathExtractor.new
		@ajax_path_extractor = interfaces[:ajax_path_extractor] || Roundabout::AjaxPathExtractor.new
		@css_path_extractor = interfaces[:css_path_extractor] || Roundabout::CssPathExtractor.new
		@distributor = interfaces[:distributor] || Roundabout::Distributor.new([self])

		@on_complete_block = nil
		@after_run_block = nil

		FileUtils.rm_rf(store_path) if Dir.exists?(store_path)

		@done = false
		http.on_complete {
			next if !@paths.empty?
			@done = true
			@on_complete_block.call if @on_complete_block
		}
	end

	# @return   [TrueClass, FalseClass]  true if crawl is done, false otherwise
	def done?
		@done
	end

	# @return   [Array<String>]  crawled URLs
	def sitemap_as_array
		sitemap.to_a
	end

	# @param    [Block] block   to be run once the crawl completes
	def on_complete(&block)
		raise 'Required block missing!' if !block_given?
		@on_complete_block = block
	end

	# @return   [String]    self url
	def peer_url
		@opts[:host] + ':' + @opts[:port].to_s
	end

	# @param    [Block] block   to be run at the end of {#run}
	def after_run(&block)
		raise 'Required block missing!' if !block_given?
		@after_run_block = block
	end

	#
	# Performs the crawl
	#
	def run
		while url = @paths.pop
			puts "got url: #{url}"
			@done = false
			visited(url)

			http.get(url) do |response|
				headers = response.headers
				type = headers["Content-Type"].split(";").first
				new_paths = []
				store = false
				case type
					when "text/html"
						paths = extract_paths(response.body)
						ajax_paths = extract_ajax_paths(response.body)
						#puts "Collected ajax path: #{ajax_paths.awesome_inspect}"
						new_paths += (paths + ajax_paths)
						@html_paths += paths
						rewrite_html_urls(response.body, @html_paths)
						store = true

					when "text/css"
						css_pathes = extract_css_paths(response.body)
						new_paths += css_pathes
						rewrite_css_urls(response.body, css_pathes)
						store = true

					when "text/javascript", "application/javascript", "application/pdf", "image/jpeg", "image/png", "image/webp", "image/vnd.microsoft.icon", "image/x-icon"
						## just store the file
						store = true

					else
						puts "Dont know howto parse content-type: #{type.inspect}, skipping"
						## dont do anything with the file
						store = false
				end
				store_file(response, type) if store
				distributor.distribute(new_paths)
			end
		end

		@after_run_block.call if @after_run_block
		true
	end

	#
	# Pushes more paths to be crawled and wakes up the crawler
	#
	# @param    [String, Array<String>]     paths
	#
	def push(paths)
		@paths |= dedup([paths])
		run # wake it up if it has stopped
	end

	#
	# Rejects filter
	#
	# @param    [Block]     block   rejects URLs based on its return value
	#
	def reject(&block)
		raise 'Required block missing!' if !block_given?
		@reject_block = block
	end

	#
	# Decides whether or not to skip the given URL based on 3 factors:
	# * has the URL already been {#visited?}
	# * is the URL in the same domain? ({#in_domain?})
	# * does the URL get past the given {#reject} block? ({#reject?})
	#
	# @param    [String]    url
	#
	# @return   [TrueClass, FalseClass]
	#
	# @see #reject?
	# @see #reject
	# @see #visited?
	# @see #in_domain?
	#
	def skip?(url)
		!in_domain?(url) || visited?(url) || reject?(url)
	end

	#
	# @return   [TrueClass, FalseClass] does the URL get past the given {#reject} block?
	#
	# @see #reject
	#
	def reject?(url)
		return false if !@reject_block
		@reject_block.call(url)
	end

	#
	# @return   [TrueClass, FalseClass] is the URL in the same domain?
	#
	def in_domain?(url)
		begin
			@host ||= uri_parse(@url).host
			@host == uri_parse(url).host
		rescue Exception
			false
		end
	end

	#
	# @return   [TrueClass, FalseClass] has the URL already been visited?
	#
	def visited?(url)
		sitemap.include?(url)
	end

	def store_path
		@store_path ||= File.join(File.expand_path(File.dirname(File.dirname(__FILE__))), "../dumps/#{@now.strftime("%F")}/#{subfolder}")
	end


	def subfolder
		"/v2"
	end

	private

	def check_content_type_suffix(file, content_type)
		case content_type
			when "text/html"
				return "index.html" if file.nil?
				return "index.html#{file}" if !file.nil? && file[0] == "?"
				file << ".html" unless file.match(/\.html$/)
			#else
			#	puts "shall we change the file.suffix for content-type: #{content_type} on file: #{file}"
		end
		file
	end

	def parse_file_path(url, content_type)
		path = url.gsub(@url, "").gsub(/$\//, "")
		file, dirs = *path.split("/").reverse
		file = check_content_type_suffix(file, content_type)
		dirs.compact! if dirs && dirs.is_a?(Array)
		filepath = File.join(store_path, *dirs)
		FileUtils.mkdir_p(filepath) unless Dir.exists?(filepath)
		#puts "Storing file: #{file} at dir: #{filepath}"
		return [file, filepath]
	end

	def rewrite_html_urls(body, urls)
		urls.uniq.each do |url|
			relative_url = url.gsub(@url, "")
			parts = relative_url.split(".").to_a
			path = parts[0]
			suffix = parts[1]
			## catch special cases where the link is empty (which means index.html)
			if path[0] == "/" && path.size == 1
				new_url = "#{subfolder}/index.html"
			## catch special cases where the link is only "?paramA=foo&amp;paramB=bar" (which means index.html?paramA...)
			elsif path[1] == "?"
				new_url = "#{subfolder}/index.html#{path[1..path.size-1]}"
			else
				## dont attach a suffix if there already is one
				if !suffix || suffix == ""
					new_url = "#{subfolder}/#{relative_url}.html"
				else
					new_url = "#{subfolder}/#{relative_url}"
				end
			end
			## add '' around the urls, or it'll double-replace all '/' hrefs
			old_url = '"'+relative_url+'"'
			final_url = '"'+ new_url.squeeze("/") +'"'

			if( body.match(old_url) )
				#puts "Url: #{relative_url} => #{final_url}"
				body.gsub!(old_url, final_url)
			#else
			#	puts "NOT FOUND: url: #{old_url}"
			end

		end
		#puts "rewrote #{urls.size} html urls"
		body
	end

	def rewrite_css_urls(body, urls)
		urls.each do |url|
			new_url = "#{subfolder}/#{url}"
			body.gsub!(url, new_url)
		end
		puts "rewrote #{urls.size} css urls"
		body
	end

	def store_file(response, content_type)
		if response.code == 200
			filename, filepath = parse_file_path(response.url, content_type)
			path = File.join(filepath, filename)
			File.open(path, "w") do |file|
				file.puts response.body
			end
			puts "wrote file: #{path} with #{File.size?(path)} bytes"
		else
			puts "Status.code: #{response.code} signals an error (!= 200), wont store file: #{response.url}"
		end
	end

	def visited(url)
		sitemap << url
	end

	def to_absolute(relative_url)
		begin
			# remove anchor
			relative_url = uri_encode(relative_url.to_s.gsub(/#[a-zA-Z0-9_-]*$/, ''))

			return relative_url if uri_parser.parse(relative_url).host
		rescue Exception => e
			#ap e
			#ap e.backtrace
			return nil
		end

		begin
			base_url = uri_parse(@url)
			relative = uri_parse(relative_url)
			absolute = base_url.merge(relative)

			absolute.path = '/' if absolute.path && absolute.path.empty?

			absolute.to_s
		rescue Exception => e
			#ap e
			#ap e.backtrace
			return nil
		end
	end

	def extract_paths(html)
		dedup( path_extractor.run(Nokogiri::HTML(html)) ) rescue []
	end

	def extract_ajax_paths(html)
		dedup( ajax_path_extractor.run(Nokogiri::HTML(html)) ) rescue []
	end

	def extract_css_paths(css)
		sass = Sass::Engine.new(css, :syntax => :scss)
		images = sass.to_tree.to_a.find_all{|a| a[:property] == 'background-image' && a[:value].match( /url\(/ )}
		css_path_extractor.run( images )
	end

	#dedup(
	#		#path_extractor.run(Nokogiri::HTML(html))
	#		css_path_extractor.run( CSSPool.CSS( open(css) ) )
	#) # rescue []

	def dedup(urls)
		urls.flatten.compact.uniq.map { |path| to_absolute(path) }.
				reject { |p| skip?(p) }
	end

end
