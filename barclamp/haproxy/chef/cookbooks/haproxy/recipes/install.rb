#
# Cookbook Name:: git
# Recipe:: install
#
# Copyright 2011, Dell, Inc.
# Copyright 2012, Dell, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

execute "createhaproxydir" do
  command "mkdir -p /var/lib/haproxy"
end

package "haproxy" do
  action :install
end

service "haproxy" do
  supports :restart => true
  action [:enable, :start]
end


package "keepalived" do
  action :install
end

service "keepalived" do
  supports :restart => true
  action [:enable, :start]
end

if node[:roles].include?("haproxy")
  env_filter = "#{env_filter} AND roles:slave"
  is_master = true
else
  env_filter = "#{env_filter} AND roles:haproxy"
  is_master = false
end


admin_net = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "admin")
public_net = Chef::Recipe::Barclamp::Inventory.get_network_by_type(node, "public")
admin_iface = admin_net.interface
public_iface = public_net.interface
public_net_db = data_bag_item('crowbar', 'public_network')
admin_net_db = data_bag_item('crowbar', 'admin_network')
service_name = node[:haproxy][:config][:environment]
proposal_name = service_name.split('-')
bcproposal = "bc-haproxy-"+proposal_name[2]
domain = node[:domain]
public_ip = public_net_db["allocated_by_name"]["#{service_name}.#{domain}"]["address"]
admin_ip = admin_net_db["allocated_by_name"]["#{service_name}.#{domain}"]["address"]
public_vlan = public_net_db["network"]["vlan"]

node.set["haproxy"]["public_ip"] = public_ip
node.set["haproxy"]["admin_ip"] = admin_ip
#lets leave here an entity for hosts wich may be helpfull when we going to introduce ssl support for lb
node.set["haproxy"]["public_host"] = "public.#{service_name}.#{domain}"
node.set["haproxy"]["admin_host"] = "#{service_name}.#{domain}"

node.save

adminfixedip_db = data_bag_item('crowbar', bcproposal)
admincont1 = adminfixedip_db["deployment"]["haproxy"]["elements"]["haproxy"][0]
admincont2 = adminfixedip_db["deployment"]["haproxy"]["elements"]["slave"][0]
admincont3 = adminfixedip_db["deployment"]["haproxy"]["elements"]["slave"][1]
cont1_db = data_bag_item('crowbar', 'admin_network')
cont1_admin_ip = cont1_db["allocated_by_name"]["#{admincont1}"]["address"]
cont2_admin_ip = cont1_db["allocated_by_name"]["#{admincont2}"]["address"]
cont3_admin_ip = cont1_db["allocated_by_name"]["#{admincont3}"]["address"]

template "/etc/keepalived/keepalived.conf" do
  source "keepalived.conf.erb"
  mode "0644"
  variables( {
    :is_master => is_master, 
    :admin_iface => admin_iface,
    :admin_ip => admin_ip,
    :public_iface => public_iface + "." + public_vlan.to_s,
    :public_ip => public_ip 
  } )
  notifies :restart, resources(:service => "keepalived")
end

template "/etc/haproxy/haproxy.cfg" do
  source "haproxy.cfg.erb"
  mode "0644"
  variables( {
    :admin_ip => admin_ip,
    :admincont1 => admincont1,
    :admincont2 => admincont2,
    :admincont3 => admincont3,
    :cont1_admin_ip => cont1_admin_ip,
    :cont2_admin_ip => cont2_admin_ip,
    :cont3_admin_ip => cont3_admin_ip,
    :public_ip => public_ip 
  } )
   notifies :restart, resources(:service => "haproxy")
end

unless `ps -N |grep haproxy` != ""
   execute "starthaproxy" do
     command "haproxy -f /etc/haproxy/haproxy.cfg"
   end
end

