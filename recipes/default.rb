#
# Cookbook Name:: documentcloud
# Recipe:: default

include_recipe 'user'
include_recipe 'apt'

# First, remove unneeded packages
DEPS = \
  %w{ build-essential libcurl4-openssl-dev libssl-dev zlib1g-dev libpcre3-dev ruby1.8 rubygems        } +
  %w{ postgresql libpq-dev git sqlite3 libsqlite3-dev libpcre3-dev lzop libxml2-dev curl         } +
  %w{ libxslt-dev libcurl4-gnutls-dev libitext-java graphicsmagick pdftk xpdf poppler-utils   } #+
#   %{ libreofice libreoffice-java-common tesseract-ocr ghostscript }
DEPS.each do | pkg |
  package pkg
end

# %w{ eng deu spa fra chi-sim chi-tra }.each do | language_code |
#   package 'tesseract-ocr-' + language_code
# end

# Install passenger
gem_package 'passenger' do
  gem_binary '/usr/bin/gem'
  action :upgrade
  if node['nginx']['passenger']['version']
    version node['nginx']['passenger']['version']
  end
end

nginx_path  = Pathname.new node[:nginx][:install_path]
nginx_conf  = nginx_path.join( 'conf','nginx.conf' )
install_dir = Pathname.new node[:documentcloud][:directory]
user_id     = node[:account][:login]


bash "install passenger/nginx" do
  user "root"
  code "passenger-install-nginx-module --auto --auto-download --prefix=#{nginx_path}  --extra-configure-flags='#{node[:nginx][:config_flags]}'"
  not_if do
    File.exists?( nginx_conf )
  end
end

FileUtils.mkdir_p "#{nginx_path}/conf/sites-enabled"

template nginx_conf.to_s do
  source 'nginx.conf.erb'
  mode   '0664'
  variables(
    :passenger_root => lambda{ `passenger-config --root`.chomp },
    :passenger_ruby_path => lambda{ '/usr/bin/ruby' }
    )
  notifies :enable, "service[nginx]"
  notifies :start, "service[nginx]"
end

service "nginx" do
  supports :restart => true, :start => true, :stop => true, :reload => true
  action :nothing
end

template '/etc/init.d/nginx' do
  source 'nginx.init.erb'
  mode   '0711'
end

template nginx_path.join('conf','sites-enabled','default.conf').to_s do
  source 'nginx_site.conf.erb'
  mode   '0664'
  notifies :enable, "service[nginx]"
  notifies :start, "service[nginx]"
end
template nginx_path.join('conf','documentcloud.conf').to_s do
  source 'documentcloud.conf.erb'
  mode   '0664'
  notifies :enable, "service[nginx]"
  notifies :start, "service[nginx]"
end

template "/etc/motd.tail" do
  source 'motd.tail.erb'
  owner  'root'
  mode   '0664'
end

user_account 'Document Cloud User Account' do
  username     user_id
  create_group true
  ssh_keygen   true
  ssh_keys     node[:account][:ssh_keys]
end

ssh_known_hosts_entry 'github.com'

git install_dir.to_s do
  repository node.documentcloud.git.repository
  revision  node.documentcloud.git.branch
  user user_id
  action :checkout
end

ruby_block "copy-server-secrets" do
  block do
    require 'fileutils'
    FileUtils.cp_r( install_dir.join('config','server','secrets'), install_dir ) unless install_dir.join('secrets').exist?
  end
end



directory node.nginx.log_directory do
  owner node[:nginx][:user]
  group node[:nginx][:group]
  mode 0644
  action :create
  not_if do
    File.exists?( node.nginx.log_directory )
  end
end

include_recipe 'postgresql::server'

template "#{node['postgresql']['dir']}/pg_hba.conf" do
  source "pg_hba.conf.erb"
  owner "postgres"
  group "postgres"
  mode 00600
  notifies :reload, 'service[postgresql]', :immediately
end

ruby_block 'setup_db' do

  notifies :create, "template[#{node['postgresql']['dir']}/pg_hba.conf]", :immediately

  block do
    require 'erb'
    require 'yaml'
    class Rails;   def self.root;  @@root;  end    end
    Rails.send :class_variable_set, :@@root, install_dir
    config = YAML.load( ERB.new(File.read( install_dir.join('config','database.yml') ) ).result(binding) )[ node.documentcloud.rails_env ]

#    STDERR.puts config.to_yaml

    bash = Chef::Resource::Script::Bash.new('create-db-account',run_context)
    bash.user 'postgres'
    code =  "createuser --no-createrole --no-superuser --no-createdb #{config['username']}\n"
    node['dbname'] = config['database']

    node['postgresql']['pg_hba'] << {
      :type => 'local', :db => config['database'], :user => config['username'], :addr => nil, :method => 'trust'
    }

    if config['password']
      code << "psql -c \"ALTER USER #{config['username']} WITH PASSWORD '#{config['password']}'\""
    end
    bash.code code
    bash.not_if  "psql -c \"\\du\" | grep #{config['username']}"
    bash.run_action(:run)

    bash = Chef::Resource::Script::Bash.new('create-database',run_context)
    bash.user 'postgres'
    bash.cwd install_dir.to_s
    bash.code <<-EOS
      createdb -O #{config['username']} #{config['database']}
      psql -U #{config['username']} #{config['database']} < db/development_structure.sql
      tables=`psql -qAt -c "select tablename from pg_tables where schemaname = 'public';" #{config['database']}`
      for tbl in $tables ; do
        psql -c "alter table $tbl owner to #{config['username']}" #{config['database']};
      done

    EOS
    bash.not_if "psql -l | grep -c #{config['database']}"
    bash.run_action(:run)

  end
end

bash "install-rails" do
  user "root"
  cwd install_dir.to_s
  code <<-EOS
    /usr/bin/gem install --no-ri --no-rdoc rails -v `grep -E -o \'RAILS_GEM_VERSION.*[0-9]+\.[0-9]+\.[0-9]+\' config/environment.rb | cut -d\\' -f2`
    gem install --no-ri --no-rdoc pg sanitize right_aws json
    rake gems:install
  EOS
  not_if <<-EOS
    gem list rails | grep -c `grep -E -o 'RAILS_GEM_VERSION.*[0-9]+\.[0-9]+\.[0-9]+' config/environment.rb | cut -d\' -f2`
  EOS
end

include_recipe 'rake'

rake 'migrate-db' do
  working_directory install_dir.to_s
  arguments 'db:migrate'
  action :run
end

rake 'run-cloud-crowd' do
  working_directory install_dir.to_s
  arguments 'crowd:node:start'
  action :run
end
