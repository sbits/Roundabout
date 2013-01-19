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
# Extracts paths (to be crawled) from CSS code.
#
# @author Christian Pedaschus <chris@sbits.ac>
#
class Roundabout::CssPathExtractor

	def run(doc)
		doc.map do |row|
			## extract url from "url(/foobar.url)"
			row[:value].match(/.*\(([^)]*)\)/).to_a[1]
		end.uniq.compact
	end

end
