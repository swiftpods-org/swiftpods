# frozen_string_literal: true

require 'cocoapods-downloader/http'

module SwiftPods
  def self.content_cache(operation, payload)
    output, error, status = Open3.capture3(ENV.fetch('SWIFTPODS_EXECUTABLE'), '__cache', operation,
                                         ENV.fetch('SWIFTPODS_CACHE_ROOT'), '--json', :stdin_data => JSON.generate(payload))
    report = JSON.parse(output)
    unless status.success?
      diagnostic = report['diagnostic'] || {}
      raise Failure.new(diagnostic['code'] || 'SP-CACHE-ERROR', 'cache', diagnostic['message'] || error)
    end
    report
  end

  module HTTPContentCache
    def download_file(filename)
      safe_headers = Array(headers).reject { |header| header.to_s.split(':', 2).first.match?(/authorization|cookie|token|password|secret|credential|key/i) }
      origin = { 'url' => SwiftPods.origin_identity(url), 'sha256' => options[:sha256],
                 'sha1' => options[:sha1], 'headers' => safe_headers,
                 'identity_sha256' => Digest::SHA256.hexdigest(JSON.generate([url, Array(headers)])) }
      cached = SwiftPods.content_cache('get', 'origin' => origin)
      if cached['status'] == 'hit' && (ENV['SWIFTPODS_OFFLINE'] == '1' || options[:sha256])
        FileUtils.mkdir_p(File.dirname(filename))
        FileUtils.cp(cached.fetch('path'), filename)
        unless Digest::SHA256.file(filename).hexdigest == cached.fetch('sha256')
          raise Failure.new('SP-CACHE-INTEGRITY', 'cache', 'Raw archive changed while copying out of the immutable store')
        end
        # Copying immutable cache bytes creates an independent working file.
        File.chmod(0o600, filename)
        return
      end
      if ENV['SWIFTPODS_OFFLINE'] == '1'
        return super if SwiftPods.local_source?(url)
        raise Failure.new('SP-OFFLINE-MISSING', 'download', "Missing raw archive for #{SwiftPods.origin_identity(url)}")
      end
      super
      verify_checksum(filename)
      SwiftPods.content_cache('put', 'origin' => origin, 'path' => filename.to_s)
    end
  end
  Pod::Downloader::Http.prepend(HTTPContentCache)
end
