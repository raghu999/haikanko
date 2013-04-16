# encoding: utf-8
require 'tempfile'

def localhost
  `hostname`.chomp
end

def files_dir
  File.expand_path(APP_ROOT + '/pipework/files')
end

def templates_dir
  File.expand_path(APP_ROOT + '/pipework/templates')
end

def fluentd_dir
  File.expand_path(APP_ROOT + '/pipework/fluentd')
end

def mina_dir
  File.expand_path(APP_ROOT + '/pipework/mina')
end

def herb(name, options = {})
  path = File.join(templates_dir, "#{name}.erb")
  Tilt.new(path).render(self, options[:locals])
end

# Get namespace variable, e.g., haikanko from haikanko:install argument
def current_namespace
  ARGV.first.split(":").first.to_sym
end

def remote_crond_file(target_path, source_path = nil, &block)
  remote_file(target_path, source_path, &block)
  queue! %[sudo chmod 644 #{target_path}]
  queue! %[sudo chown root.root #{target_path}]
  queue! "sudo /etc/init.d/crond reload"
end

def remove_crond_file(target_path)
  queue! %[sudo rm -f "#{target_path}"]
  queue! "sudo /etc/init.d/crond reload"
end

def executable_file(target_path, source_path = nil, &block)
  remote_file(target_path, source_path, &block)
  queue! %[sudo chmod a+x #{target_path}]
end

def remove_remote_file(target_path)
  queue! %[sudo rm -f #{target_path}]
end

# Copy a file to remote host
#
# @param target_path The path to upload the file contents at remote host
# @param source_path The path of a file to update (relative_path from pipework/files)
# 
# If block_given?, the string generated by the block is uploaded. 
def remote_file(target_path, source_path = nil)
  contents = nil
  if block_given?
    contents = yield
    source_path = create_tempfile(contents)
  elsif source_path
    source_path = File.expand_path(source_path, files_dir)
  end
  queue! %[sudo mkdir -p $(dirname #{target_path})]
  queue! %[sudo rsync -a #{localhost}:#{source_path} #{target_path}]

  if simulate_mode?
    contents = File.read(source_path) unless contents
    queue! %[cat <<'EOT' < #{target_path}\n#{contents}\nEOT]
  else
    queue! %[sudo cat #{target_path}]
  end
end

# @param contents
# @return path
def create_tempfile(contents)
  @tempfiles ||= []
  file = Tempfile.new('', '/tmp')
  begin
    file.puts contents
    @tempfiles << file
  ensure
    file.close
  end
  file.path
end

# clean tempfile (ruby will automatically do, but should manually call after run!)
def clean_tempfile!
  @tempfiles.each {|f| f.unlink } if @tempfiles
  @tempfiles = []
end

# Generate a file from a template and put it to the remote host
#
# @param target_path The path to upload the file contents at remote host
# @param template_path The path of a template (relative_path from pipework/files)
# @param params The parameters used to expand the template file
def template_file(target_path, template_path, options = {})
  remote_file(target_path) do
    template_path = "#{template_path}.erb" unless File.extname(template_path) == ".erb"
    template_path = File.expand_path(template_path, templates_dir)
    Tilt.new(template_path).render(self, options[:locals])
  end
end

# Rsync a directory to the remote host
# @param target_path The path to upload at remote host
# @param source_path The path to be uploaded at localhost (relative_path from pipework/files)
def remote_directory(target_path, source_path)
  source_path = File.expand_path(source_path, files_dir)
  queue! %[sudo mkdir -p $(dirname #{target_path})]
  queue! %[sudo rsync -av --delete --exclude='.git' #{localhost}:#{source_path}/ #{target_path}/]
end

# Invoke the task in multiple hosts
#
# @param task Task name
# @param domains Hostnames
# @param args Task args if any
def multi_invoke(task, domains, args = [])
  isolate do
    domains.each_with_index do |domain, i|
      invoke_block(domain) { Rake::Task[task].invoke(args[i]) }
    end
  end
end

# Invoke the task given by a block reenably
#
# @param domain hostname
# @param block
def invoke_block(domain)
  begin
    set :domain, domain
    yield if block_given?
    run! if commands.any?
    Rake::Task.tasks.each {|t| t.reenable } # allows to invoke rake 2nd or more times
  rescue Mina::Failed => e
    $stderr.puts e.message
  ensure
    clean_tempfile!
  end
end

def status_daemontools(daemon_name)
  # Use if; then; fi rather than [ ] && because, otherwise, $? would be 1 and the script stops
  queue! %(if [ -d "/service/#{daemon_name}/log" ]; then sudo svstat "/service/#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo svstat "/service/#{daemon_name}"; fi)
end

def restart_daemontools(daemon_name)
  queue! %(if [ -d "/service/#{daemon_name}/log" ]; then sudo svc -dx "/service/#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo svc -dx "/service/#{daemon_name}"; fi)
end

def start_daemontools(daemon_name)
  queue! %(if [ -d "/service/#{daemon_name}/log" ]; then sudo svc -u "/service/#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo svc -u "/service/#{daemon_name}"; fi)
end

def stop_daemontools(daemon_name)
  queue! %(if [ -d "/service/#{daemon_name}/log" ]; then sudo svc -d "/service/#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo svc -d "/service/#{daemon_name}"; fi)
end

def remove_daemontools(daemon_name)
  queue! %(if [ -d "/service/#{daemon_name}/log" ]; then sudo svc -d "/service/#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo svc -d "/service/#{daemon_name}"; fi)
  queue! %(if [ -L "/service/#{daemon_name}" ]; then sudo mv "/service/#{daemon_name}" "/service/.#{daemon_name}"; fi)
  queue! %(if [ -d "/service/.#{daemon_name}/log" ]; then sudo svc -x "/service/.#{daemon_name}/log"; fi)
  queue! %(if [ -L "/service/.#{daemon_name}" ]; then sudo svc -x "/service/.#{daemon_name}"; fi)
  queue! %(if [ -L "/service/.#{daemon_name}" ]; then sudo rm "/service/.#{daemon_name}"; fi)
end

def yum_haikanko_install(rpm_name)
  remote_file("/etc/yum.repos.d/fluent-agent-lite-haikanko.repo", "fluent-agent-lite-haikanko.repo")
  remote_file("/etc/yum.repos.d/td.repo", "td.repo")
  queue! %[sudo yum -y --disablerepo='*' --enablerepo=fluent-agent-lite-haikanko,treasuredata install #{rpm_name}]
end

def yum_haikanko_remove(rpm_name)
  queue! %[sudo yum -y remove #{rpm_name}]
  queue! %[sudo rm -f /etc/yum.repos.d/fluent-agent-lite-haikanko.repo]
  queue! %[sudo rm -f /etc/yum.repos.d/td.repo]
end

def fluent_bundle(path)
  fluent_bin = %[/usr/lib$(uname -i | grep x86_64 > /dev/null && echo 64)/fluent/ruby/bin]
  queue! %[cd #{path}]
  queue! %["#{fluent_bin}/bundle" install]
end