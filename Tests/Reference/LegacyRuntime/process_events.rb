# frozen_string_literal: true

module SwiftPods
  module ExternalProcessEvents
    def popen3(bin, command, stdout, stderr)
      status = super
      record_process(bin, status)
      status
    end

    def execute_command(*args)
      Thread.current[:swiftpods_process_status] = nil
      super
    rescue StandardError
      report_process_failure
      raise
    end

    def capture_command(executable, command, **kwargs)
      Thread.current[:swiftpods_process_status] = nil
      result = super
      status = result.is_a?(Array) ? result.last : result
      record_process(executable, status) if status.is_a?(Process::Status)
      result
    end

    def capture_command!(executable, command, **kwargs)
      super
    rescue StandardError
      report_process_failure
      raise
    end

    private

    def record_process(executable, status)
      frames = caller_locations(2, 20).map(&:to_s)
      stage = if frames.any? { |frame| frame.include?('pod_source_preparer') }
                'prepare'
              elsif frames.any? { |frame| frame.include?('remote_file') }
                'extract'
              elsif frames.any? { |frame| frame.include?('downloader') }
                'download'
              else 'external_process'
              end
      row = { 'stage' => stage, 'executable' => File.basename(executable.to_s),
              'exit_status' => status.exitstatus || 128 + status.termsig, 'signal' => status.termsig }
      Thread.current[:swiftpods_process_status] = row
      SwiftPods.emit('process_exit', row)
    end

    def report_process_failure
      row = Thread.current[:swiftpods_process_status]
      return unless row && row['exit_status'] != 0
      SwiftPods.emit('diagnostic', row.merge('code' => 'SP-PROCESS-EXIT', 'message' => "#{row['executable']} failed with exit status #{row['exit_status']}"))
    end
  end
  Pod::Executable.singleton_class.prepend(ExternalProcessEvents)
end
