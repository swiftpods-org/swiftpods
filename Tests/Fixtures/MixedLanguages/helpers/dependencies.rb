def fixture_dependencies
  dependencies = { 'GameCore' => './Modules/GameCore' }
  dependencies.each { |name, path| pod name, :path => path }
end

def fixture_phase(name)
  File.write('hook-trace.txt', '') if name == 'pre_install'
  File.open('hook-trace.txt', 'a') { |file| file.puts(name) }
end
