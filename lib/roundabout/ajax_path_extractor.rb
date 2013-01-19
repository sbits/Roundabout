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

#
# Extracts AJAX paths (to be crawled) from HTML code.
#
# @author Christian Pedaschus <chris@sbits.ac>
#
class Roundabout::AjaxPathExtractor

	def run(doc)
		doc.search("//a[@href and @data-remote='true']").map do |a|
			a['href'].dup << ".js"
		end
	end

end
