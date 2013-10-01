# Copyright 2011, Dell 
# Copyright 2012, Dell
# 
# Licensed under the Apache License, Version 2.0 (the "License"); 
# you may not use this file except in compliance with the License. 
# You may obtain a copy of the License at 
# 
#  http://www.apache.org/licenses/LICENSE-2.0 
# 
# Unless required by applicable law or agreed to in writing, software 
# distributed under the License is distributed on an "AS IS" BASIS, 
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
# See the License for the specific language governing permissions and 
# limitations under the License. 
# 

class HaproxyService < ServiceObject

  def initialize(thelogger)
    @bc_name = "haproxy"
    @logger = thelogger
  end

  def self.allow_multiple_proposals?
    false
  end

  def create_proposal
    @logger.debug("haproxy create_proposal: entering")
    base = super
    @logger.debug("haproxy create_proposal: done with base")

    nodes = NodeObject.all
    nodes.delete_if { |n| n.nil? }
    nodes.delete_if { |n| n.admin? } if nodes.size > 1
    head = nodes.shift
    nodes = [ head ] if nodes.empty?
    base["deployment"]["haproxy"]["elements"] = {
      "haproxy" => [ head.name ],
      "slave" => nodes.map { |x| x.name }
    }

    @logger.debug("haproxy create_proposal: exiting")
    base
  end

  def acquire_ip_lock
    acquire_lock "ip"
  end

  def release_ip_lock(f)
    release_lock f
  end


  def allocate_ip_by_type(bc_instance, network, range, object, type, suggestion = nil)
    @logger.debug("Network allocate ip for #{type}: entering #{object} #{network} #{range}")
    return [404, "No network specified"] if network.nil?
    return [404, "No range specified"] if range.nil?
    return [404, "No object specified"] if object.nil?
    return [404, "No type specified"] if type.nil?

    if type == :node
      node = NodeObject.find_node_by_name object
      @logger.error("Network allocate ip from node: return node not found: #{object} #{network}") if node.nil?
      return [404, "No node found"] if node.nil?
      name = node.name.to_s
    else
      name = object.to_s
    end

    role = RoleObject.find_role_by_name "network-config-#{bc_instance}"
    @logger.error("Network allocate ip by type: No network data found: #{object} #{network} #{range}") if role.nil?
    return [404, "No network data found"] if role.nil?

    net_info = {}
    found = false
    begin
      f = acquire_ip_lock
      db = ProposalObject.find_data_bag_item "crowbar/#{network}_network"
      net_info = build_net_info(network, name, db)

      rangeH = db["network"]["ranges"][range]
      rangeH = db["network"]["ranges"]["host"] if rangeH.nil?

      index = IPAddr.new(rangeH["start"]) & ~IPAddr.new(net_info["netmask"])
      index = index.to_i
      stop_address = IPAddr.new(rangeH["end"]) & ~IPAddr.new(net_info["netmask"])
      stop_address = IPAddr.new(net_info["subnet"]) | (stop_address.to_i + 1)
      address = IPAddr.new(net_info["subnet"]) | index

      if suggestion
        @logger.info("Allocating with suggestion: #{suggestion}")
        subsug = IPAddr.new(suggestion) & IPAddr.new(net_info["netmask"])
        subnet = IPAddr.new(net_info["subnet"]) & IPAddr.new(net_info["netmask"])
        if subnet == subsug
          if db["allocated"][suggestion].nil?
            @logger.info("Using suggestion for #{type}: #{name} #{network} #{suggestion}")
            address = suggestion
            found = true
          end
        end
      end

      unless found
        # Did we already allocate this, but the node lose it?
        unless db["allocated_by_name"][name].nil?
          found = true
          address = db["allocated_by_name"][name]["address"]
        end
      end


      # Let's search for an empty one.
      while !found do
        if db["allocated"][address.to_s].nil?
          found = true
          break
        end
        index = index + 1
        address = IPAddr.new(net_info["subnet"]) | index
        break if address == stop_address
      end


      if found
        net_info["address"] = address.to_s
        db["allocated_by_name"][name] = { "machine" => name, "interface" => net_info["conduit"], "address" => address.to_s }
        db["allocated"][address.to_s] = { "machine" => name, "interface" => net_info["conduit"], "address" => address.to_s }
        db.save
      end
    rescue Exception => e
      @logger.error("Error finding address: #{e.message}")
    ensure
      release_ip_lock(f)
    end

    @logger.info("Network allocate ip for #{type}: no address available: #{name} #{network} #{range}") if !found
    return [404, "No Address Available"] if !found

    if type == :node
      # Save the information.
      node.crowbar["crowbar"]["network"][network] = net_info
      node.save
    end

    @logger.info("Network allocate ip for #{type}: Assigned: #{name} #{network} #{range} #{net_info["address"]}")
    [200, net_info]
  end

  def allocate_virtual_ip(bc_instance, network, range, service, suggestion = nil)
    allocate_ip_by_type(bc_instance, network, range, service, :virtual, suggestion)
  end

  def allocate_ip(bc_instance, network, range, name, suggestion = nil)
    allocate_ip_by_type(bc_instance, network, range, name, :node, suggestion)
  end

  def build_net_info(network, name, db = nil)
    db = ProposalObject.find_data_bag_item "crowbar/#{network}_network" unless db

    net_info = {}
    db["network"].each { |k,v|
      net_info[k] = v unless v.nil?
    }
    net_info["usage"]= network
    net_info["node"] = name
    net_info
  end



  def apply_role_pre_chef_call(old_role, role, all_nodes)
    @logger.debug("haproxy apply_role_pre_chef_call: entering #{all_nodes.inspect}")
    return if all_nodes.empty?

    @logger.debug("haproxy create_proposal: allocate Public IP address")
    net_svc = NetworkService.new @logger
    network_proposal = ProposalObject.find_proposal(net_svc.bc_name, "default")
    tnodes = role.override_attributes["haproxy"]["elements"]["haproxy"]
    unless tnodes.nil? or tnodes.empty?
      tnodes.each do |n|
        allocate_ip "default", "public", "host",n
      end
      @logger.info("haproxy create_proposal: allocate Public IP address")

     if all_nodes.size > 0
         n = NodeObject.find_node_by_name all_nodes.first
         @logger.info("cfg=#{role.name}")
         @logger.info("domain=#{n[:domain]}")
         service_name=role.name
         domain=n[:domain]
         # allocate new public ip address for the virtual node
         allocate_virtual_ip "default", "public", "host", "#{service_name}.#{domain}"
         # allocate new admin ip for the virtual node
         allocate_virtual_ip "default", "admin", "host", "#{service_name}.#{domain}"
      end
    end
    tnodes = role.override_attributes["haproxy"]["elements"]["slave"]
    unless tnodes.nil? or tnodes.empty?
      tnodes.each do |n|
        allocate_ip "default", "public", "host",n
      end
    end	
    @logger.debug("haproxy create_proposal: Allocated Pulic IP address")
    @logger.debug("haproxy apply_role_pre_chef_call: leaving")
  end
end

