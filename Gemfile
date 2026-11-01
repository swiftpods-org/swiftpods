source "https://rubygems.org"

# Keep the development/test dependency graph usable at the gem's declared
# minimum Ruby version. The exact interpreter and Bundler versions used by CI
# are pinned in .github/workflows/fastlane-plugin.yml.
gem "fastlane", "2.237.0"
gem "minitest", "5.26.1"

# Fastlane allows newer releases of these transitive gems whose Ruby minimum
# has moved above 3.0. Keep the frozen development graph inside the plugin's
# declared Ruby range; application Gemfiles remain free to resolve newer gems.
gem "CFPropertyList", "3.0.8"
gem "excon", "1.2.5"
gem "google-apis-androidpublisher_v3", "0.78.0"
gem "google-apis-iamcredentials_v1", "0.23.0"
gem "google-apis-playcustomapp_v1", "0.16.0"
gem "google-apis-storage_v1", "0.50.0"
gem "google-cloud-core", "1.8.0"
gem "google-cloud-errors", "1.6.0"
gem "google-logging-utils", "0.1.0"
gem "googleauth", "1.17.1"
gem "multi_json", "1.19.1"
gem "public_suffix", "6.0.2"
gem "signet", "0.19.0"

gemspec
