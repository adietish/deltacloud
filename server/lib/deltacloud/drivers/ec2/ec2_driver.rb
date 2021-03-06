# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.  The
# ASF licenses this file to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance with the
# License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
# License for the specific language governing permissions and limitations
# under the License.
#

require 'deltacloud/base_driver'
require 'aws'

class Instance
  attr_accessor :keyname
  attr_accessor :authn_error

  def authn_feature_failed?
    return true unless authn_error.nil?
  end

end

module Deltacloud
  module Drivers
    module EC2
      class EC2Driver < Deltacloud::BaseDriver

        def supported_collections
          DEFAULT_COLLECTIONS + [ :keys, :buckets, :load_balancers, :addresses ]
        end

        feature :instances, :user_data
        feature :instances, :authentication_key
        feature :instances, :security_group
        feature :instances, :instance_count
        feature :images, :owner_id
        feature :buckets, :bucket_location
        feature :instances, :register_to_load_balancer
        feature :instances, :attach_snapshot

        DEFAULT_REGION = 'us-east-1'

        define_hardware_profile('t1.micro') do
          cpu                1
          memory             0.63 * 1024
          storage            160
          architecture       'i386'
        end

        define_hardware_profile('m1.small') do
          cpu                1
          memory             1.7 * 1024
          storage            160
          architecture       'i386'
        end

        define_hardware_profile('m1.large') do
          cpu                4
          memory             7.5 * 1024
          storage            850
          architecture       'x86_64'
        end

        define_hardware_profile('m1.xlarge') do
          cpu                8
          memory             15 * 1024
          storage            1690
          architecture       'x86_64'
        end

        define_hardware_profile('c1.medium') do
          cpu                5
          memory             1.7 * 1024
          storage            350
          architecture       'i386'
        end

        define_hardware_profile('c1.xlarge') do
          cpu                20
          memory             7 * 1024
          storage            1690
          architecture       'x86_64'
        end

        define_hardware_profile('m2.xlarge') do
          cpu                6.5
          memory             17.1 * 1024
          storage            420
          architecture       'x86_64'
        end

        define_hardware_profile('m2.2xlarge') do
          cpu                13
          memory             34.2 * 1024
          storage            850
          architecture       'x86_64'
        end

        define_hardware_profile('m2.4xlarge') do
          cpu                26
          memory             68.4 * 1024
          storage            1690
          architecture       'x86_64'
        end

        define_instance_states do
          start.to( :pending )          .automatically
          pending.to( :running )        .automatically
          pending.to( :stopping )       .on( :stop )
          pending.to( :stopped )        .automatically
          stopped.to( :running )        .on( :start )
          running.to( :running )        .on( :reboot )
          running.to( :stopping )       .on( :stop )
          shutting_down.to( :stopped )  .automatically
          stopped.to( :finish )         .automatically
        end

        # We do not allow users to set the endpoint through environment
        # variables. That that would work is an implementation detail.
        ENV.delete("EC2_URL")
        ENV.delete("S3_URL")
        ENV.delete("ELB_URL")

        def images(credentials, opts={})
          ec2 = new_client(credentials)
          img_arr = []
          opts ||= {}
          if opts[:id]
            safely do
              img_arr = ec2.describe_images(opts[:id]).collect do |image|
                convert_image(image)
              end
            end
            return img_arr
          end
          owner_id = opts[:owner_id] || default_image_owner
          safely do
            img_arr = ec2.describe_images_by_owner(owner_id, default_image_type).collect do |image|
              convert_image(image)
            end
          end
          img_arr = filter_on( img_arr, :architecture, opts )
          img_arr.sort_by { |e| [e.owner_id, e.name] }
        end

        def realms(credentials, opts={})
          ec2 = new_client(credentials)
          zone_id = opts ? opts[:id] : nil
          safely do
            return ec2.describe_availability_zones(zone_id).collect do |realm|
              convert_realm(realm)
            end
          end
        end

        def create_image(credentials, opts={})
          ec2 = new_client(credentials)
          instance = instance(credentials, :id => opts[:id])
          safely do
            new_image_id = ec2.create_image(instance.id, opts[:name], opts[:description])
            image(credentials, :id => new_image_id)
          end
        end

        def instances(credentials, opts={})
          ec2 = new_client(credentials)
          inst_arr = []
          safely do
            inst_arr = ec2.describe_instances.collect do |instance| 
              convert_instance(instance) if instance
            end.flatten
            if tagging?
              tags = ec2.describe_tags('Filter.1.Name' => 'resource-type',
                                       'Filter.1.Value' => 'instance')
              inst_arr.each do |inst|
                name_tag = tags.select do |t|
                  (t[:aws_resource_id] == inst.id) and t[:aws_key] == 'name'
                end
                unless name_tag.empty?
                  inst.name = name_tag.first[:aws_value]
                end
              end
              delete_unused_tags(credentials, inst_arr.collect {|inst| inst.id})
            end
          end
          inst_arr = filter_on( inst_arr, :id, opts )
          filter_on( inst_arr, :state, opts )
        end

        def create_instance(credentials, image_id, opts={})
          ec2 = new_client(credentials)
          instance_options = {}
          instance_options.merge!(:user_data => opts[:user_data]) if opts[:user_data]
          instance_options.merge!(:key_name => opts[:keyname]) if opts[:keyname]
          instance_options.merge!(:availability_zone => opts[:realm_id]) if opts[:realm_id]
          instance_options.merge!(:instance_type => opts[:hwp_id]) if opts[:hwp_id] && opts[:hwp_id].length > 0
          instance_options.merge!(:group_ids => opts[:security_group]) if opts[:security_group]
          instance_options.merge!(
            :min_count => opts[:instance_count],
            :max_count => opts[:instance_count]
          ) if opts[:instance_count] and opts[:instance_count].length!=0
          if opts[:snapshot_id] and opts[:device_name]
            instance_options.merge!(:block_device_mappings => [{
              :snapshot_id => opts[:snapshot_id],
              :device_name => opts[:device_name]
            }])
          end
          safely do
            new_instance = convert_instance(ec2.launch_instances(image_id, instance_options).first)
            # TODO: Rework this to use client_id for name instead of tag
            #       Tags should be keept as an optional feature
            tag_instance(credentials, new_instance, opts[:name])
            # Register Instance to Load Balancer if load_balancer_id is set.
            # This parameter is a feature parameter
            if opts[:load_balancer_id] and opts[:load_balancer_id]!=""
              lb = lb_register_instance(credentials,
                                        {'id' => opts[:load_balancer_id],
                                         'instance_id' => new_instance.id})
            end
            new_instance
          end
        end

        def run_on_instance(credentials, opts={})
          target = instance(credentials, :id => opts[:id])
          param = {}
          param[:credentials] = {
            :username => 'root', # Default for EC2 Linux instances
          }
          param[:port] = opts[:port] || '22'
          param[:ip] = target.public_addresses
          param[:private_key] = (opts[:private_key].length > 1) ? opts[:private_key] : nil
          safely do
            Deltacloud::Runner.execute(opts[:cmd], param)
          end
        end
    
        def reboot_instance(credentials, instance_id)
          ec2 = new_client(credentials)
          if ec2.reboot_instances([instance_id])
            instance(credentials, instance_id)
          else
            raise Deltacloud::BackendError.new(500, "Instance", "Instance reboot failed", "")
          end
        end

        def destroy_instance(credentials, instance_id)
          ec2 = new_client(credentials)
          instance_id = instance_id
          if ec2.terminate_instances([instance_id])
            untag_instance(credentials, instance_id)
            instance(credentials, instance_id)
          else
            raise Deltacloud::BackendError.new(500, "Instance", "Instance cannot be terminated", "")
          end
        end

        alias :stop_instance :destroy_instance

        def keys(credentials, opts={})
          ec2 = new_client(credentials)
          opts ||= {}
          safely do
            ec2.describe_key_pairs(opts[:id] || nil).collect do |key|
              convert_key(key)
            end
          end
        end

        def create_key(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            convert_key(ec2.create_key_pair(opts[:key_name]))
          end
        end

        def destroy_key(credentials, opts={})
          ec2 = new_client(credentials)
          original_key = key(credentials, opts)
          safely do
            ec2.delete_key_pair(original_key.id)
            original_key= original_key.state = "DELETED"
          end
          original_key
        end

        def load_balancer(credentials, opts={})
          load_balancers(credentials, {
            :names => [opts[:id]]
          }).first
        end

        def load_balancers(credentials, opts=nil)
          ec2 = new_client( credentials, :elb )
          result = []
          safely do
            loadbalancers = ec2.describe_load_balancers(opts || {})
            loadbalancers.each do |loadbalancer|
              result << convert_load_balancer(credentials, loadbalancer)
            end
          end
          return result
        end

        def create_load_balancer(credentials, opts={})
          ec2 = new_client( credentials, :elb )
          safely do
            ec2.create_load_balancer(opts['name'], [opts['realm_id']],
              [{:load_balancer_port => opts['listener_balancer_port'],
                :instance_port => opts['listener_instance_port'],
                :protocol => opts['listener_protocol']}]
            )
            return load_balancer(credentials, opts['name'])
          end
        end

        def destroy_load_balancer(credentials, id)
          ec2 = new_client( credentials, :elb )
          safely do
            ec2.delete_load_balancer(id)
          end
        end

        def lb_register_instance(credentials, opts={})
          ec2 = new_client( credentials, :elb)
          safely do
            ec2.register_instances_with_load_balancer(opts['id'], [opts['instance_id']])
            load_balancer(credentials, :id => opts[:id])
          end
        end

        def lb_unregister_instance(credentials, opts={})
          ec2 = new_client( credentials, :elb)
          safely do
            ec2.deregister_instances_from_load_balancer(opts['id'], [opts['instance_id']])
            load_balancer(credentials, :id => opts['id'])
          end
        end

        def buckets(credentials, opts={})
          buckets = []
          safely do
            s3_client = new_client(credentials, :s3)
            unless (opts[:id].nil?)
              bucket = s3_client.bucket(opts[:id])
              buckets << convert_bucket(bucket)
            else
              bucket_list = s3_client.buckets
              bucket_list.each do |current|
                buckets << Bucket.new({:name => current.name, :id => current.name})
              end #bucket_list.each
            end #if
          end #safely
          filter_on(buckets, :id, opts)
        end

        def create_bucket(credentials, name, opts={})
          bucket = nil
          safely do
            s3_client = new_client(credentials, :s3)
            bucket_location = opts['location']
            if bucket_location
              bucket = Aws::S3::Bucket.create(s3_client, name, true, nil, :location => bucket_location)
            else
              bucket = Aws::S3::Bucket.create(s3_client, name, true)
            end
          end
          convert_bucket(bucket)
        end

        def delete_bucket(credentials, name, opts={})
          s3_client = new_client(credentials, :s3)
          safely do
            s3_client.interface.delete_bucket(name)
          end
        end

        def blobs(credentials, opts = {})
          s3_client = new_client(credentials, :s3)
          blobs = []
          safely do
            s3_bucket = s3_client.bucket(opts['bucket'])
            s3_bucket.keys({}, true).each do |s3_object|
              blobs << convert_object(s3_object)
            end
          end
          blobs = filter_on(blobs, :id, opts)
          blobs
        end

        #--
        # Create Blob
        #--
        def create_blob(credentials, bucket_id, blob_id, data = nil, opts = {})
          s3_client = new_client(credentials, :s3)
          #data is a construct with the temporary file created by server @.tempfile
          #also file[:type] will give us the content-type
          res = nil
          # File stream needs to be reopened in binary mode for whatever reason
          file = File::open(data[:tempfile].path, 'rb')
          #insert ec2-specific header for user metadata ... x-amz-meta-KEY = VALUE
          opts.gsub_keys('HTTP_X_Deltacloud_Blobmeta_', 'x-amz-meta-')
          opts["Content-Type"] = data[:type]
          safely do
            res = s3_client.interface.put(bucket_id, 
                                        blob_id, 
                                        file, 
                                        opts)
          end
          #create a new Blob object and return that
          Blob.new( { :id => blob_id,
                      :bucket => bucket_id,
                      :content_length => data[:tempfile].length,
                      :content_type => data[:type],
                      :last_modified => '',
                      :user_metadata => opts.select{|k,v| k.match(/^x-amz-meta-/i)}
                    }
                  )
        end

        #--
        # Delete Blob
        #--  
        def delete_blob(credentials, bucket_id, blob_id, opts={})
          s3_client = new_client(credentials, :s3)
          safely do
            s3_client.interface.delete(bucket_id, blob_id)
          end
        end


        def blob_data(credentials, bucket_id, blob_id, opts={})
          s3_client = new_client(credentials, :s3)
          safely do
            s3_client.interface.get(bucket_id, blob_id) do |chunk|
              yield chunk
            end
          end
        end

        def storage_volumes(credentials, opts={})
          ec2 = new_client( credentials )
          volume_list = (opts and opts[:id]) ? opts[:id] : nil
          safely do
            ec2.describe_volumes(volume_list).collect do |volume|
              convert_volume(volume)
            end
          end
        end

        def create_storage_volume(credentials, opts=nil)
          ec2 = new_client(credentials)
          opts ||= {}
          opts[:snapshot_id] ||= ""
          opts[:capacity] ||= "1"
          opts[:realm_id] ||= realms(credentials).first.id
          safely do
            convert_volume(ec2.create_volume(opts[:snapshot_id], opts[:capacity], opts[:realm_id]))
          end
        end

        def destroy_storage_volume(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            unless ec2.delete_volume(opts[:id]) 
              raise Deltacloud::BackendError.new(500, "StorageVolume", "Cannot delete storage volume")
            end
            storage_volume(credentials, opts[:id])
          end
        end

        def attach_storage_volume(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            convert_volume(ec2.attach_volume(opts[:id], opts[:instance_id], opts[:device]))
          end
        end

        def detach_storage_volume(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            convert_volume(ec2.detach_volume(opts[:id], opts[:instance_id], opts[:device], true))
          end
        end

        def storage_snapshots(credentials, opts={})
          ec2 = new_client(credentials)
          snapshot_list = (opts and opts[:id]) ? opts[:id] : []
          safely do
            ec2.describe_snapshots(snapshot_list).collect do |snapshot|
              convert_snapshot(snapshot)
            end
          end
        end

        def create_storage_snapshot(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            convert_snapshot(ec2.try_create_snapshot(opts[:volume_id]))
          end
        end

        def destroy_storage_snapshot(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            unless ec2.delete_snapshot(opts[:id])
              raise Deltacloud::BackendError.new(500, "StorageSnapshot", "Cannot destroy this snapshot")
            end
          end
        end

        def addresses(credentials, opts={})
          ec2 = new_client(credentials)
          address_id = (opts and opts[:id]) ? [opts[:id]] : []
          safely do
            begin
              ec2.describe_addresses(address_id).collect do |address|
                Address.new(:id => address[:public_ip], :instance_id => address[:instance_id])
              end
            rescue Exception => e
              return [] if e.message =~ /InvalidAddress\.NotFound:/
              raise e
            end
          end
        end

        def address(credentials, opts={})
          addresses(credentials, :id => opts[:id]).first
        end

        def create_address(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            Address.new(:id => ec2.allocate_address)
          end
        end

        def destroy_address(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            ec2.release_address(opts[:id])
          end
        end

        def associate_address(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            if ec2.associate_address(opts[:instance_id], opts[:id])
              Address.new(:id => opts[:id], :instance_id => opts[:instance_id])
            else
              raise "ERROR: Cannot associate IP address to an Instance"
            end
          end
        end

        def disassociate_address(credentials, opts={})
          ec2 = new_client(credentials)
          safely do
            if ec2.disassociate_address(opts[:id])
              Address.new(:id => opts[:id])
            else
              raise "ERROR: Cannot disassociate an IP address from the Instance"
            end
          end
        end

        def valid_credentials?(credentials)
          retval = true
          begin
            realms(credentials)
          rescue Deltacloud::BackendError
            retval = false
          end
          retval
        end

        private

        def new_client(credentials, type = :ec2)
          klass = case type
                    when :elb then Aws::Elb
                    when :ec2 then Aws::Ec2
                    when :s3 then Aws::S3
                  end
          klass.new(credentials.user, credentials.password, {:server => endpoint_for_service(type), :connection_mode => :per_thread})
        end

        def default_image_owner
          "amazon"
        end

        def default_image_type
          "machine"
        end

        def tagging?
          true
        end

        def endpoint_for_service(service)
          endpoint = (Thread.current[:provider] || ENV['API_PROVIDER'] || DEFAULT_REGION)
          # return the endpoint if it does not map to a default endpoint, allowing
          # the endpoint to be a full hostname instead of a region.
          Deltacloud::Drivers::driver_config[:ec2][:entrypoints][service.to_s][endpoint] || endpoint
        end

        def tag_instance(credentials, instance, name)
          if name
            ec2 = new_client(credentials)
            safely do
              ec2.create_tag(instance.id, 'name', name)
            end
          end
        end

        def untag_instance(credentials, instance_id)
          ec2 = new_client(credentials)
          safely do
            ec2.delete_tag(instance_id, 'name')
          end
        end

        def delete_unused_tags(credentials, inst_ids)
          ec2 = new_client(credentials)
          tags = []
          safely do
            tags = ec2.describe_tags('Filter.1.Name' => 'resource-type', 'Filter.1.Value' => 'instance')
            tags.collect! { |t| t[:aws_resource_id] }
            inst_ids.each do |inst_id|
              unless tags.include?(inst_id)
                ec2.delete_tag(inst_id, 'name')
              end
            end
          end
        end
        
        def convert_bucket(s3_bucket)
          #get blob list:
          blob_list = []
          s3_bucket.keys.each do |s3_object|
            blob_list << s3_object.name
          end
          #can use AWS::S3::Owner.current.display_name or current.id
          Bucket.new(
            :id => s3_bucket.name,
            :name => s3_bucket.name,
            :size => blob_list.length,
            :blob_list => blob_list
          )
        end

        def convert_object(s3_object)
          Blob.new(
            :id => s3_object.name,
            :bucket => s3_object.bucket.name.to_s,
            :content_length => s3_object.headers['content-length'],
            :content_type => s3_object.headers['content-type'],
            :last_modified => s3_object.last_modified,
            :user_metadata => s3_object.meta_headers
          )  
        end

        def convert_realm(realm)
          Realm.new(
            :id => realm[:zone_name],
            :name => realm[:zone_name],
            :state => realm[:zone_state],
            :limit => realm[:zone_state].eql?('available') ? :unlimited : 0
          )
        end

        def convert_image(image)
          # There is not support for 'name' for now
          Image.new(
            :id => image[:aws_id],
            :name => image[:aws_name] || image[:aws_id],
            :description => image[:aws_description] || image[:aws_location],
            :owner_id => image[:aws_owner],
            :architecture => image[:aws_architecture],
            :state => image[:state]
          )
        end

        def convert_instance(instance)
          can_create_image = 'ebs'.eql?(instance[:root_device_type]) and 'RUNNING'.eql?(convert_state(instance[:aws_state]))
          Instance.new(
            :id => instance[:aws_instance_id],
            :name => instance[:aws_image_id],
            :state => convert_state(instance[:aws_state]),
            :image_id => instance[:aws_image_id],
            :owner_id => instance[:aws_owner],
            :actions => instance_actions_for(convert_state(instance[:aws_state])),
            :key_name => instance[:ssh_key_name],
            :launch_time => instance[:aws_launch_time],
            :instance_profile => InstanceProfile.new(instance[:aws_instance_type]),
            :realm_id => instance[:aws_availability_zone],
            :private_addresses => instance[:private_dns_name],
            :public_addresses => instance[:dns_name],
            :create_image => can_create_image
          )
        end

        def convert_key(key)
          Key.new(
            :id => key[:aws_key_name],
            :fingerprint => key[:aws_fingerprint],
            :credential_type => :key,
            :pem_rsa_key => key[:aws_material],
            :state => "AVAILABLE"
          )
        end

        def convert_volume(volume)
          StorageVolume.new(
            :id => volume[:aws_id],
            :created => volume[:aws_created_at],
            :state => volume[:aws_status] ? volume[:aws_status].upcase : 'unknown',
            :capacity => volume[:aws_size],
            :instance_id => volume[:aws_instance_id],
            :realm_id => volume[:zone],
            :device => volume[:aws_device],
            # TODO: the available actions should be tied to the current
            # volume state                
            :actions => [:attach, :detach, :destroy] 
          )
        end

        def convert_snapshot(snapshot)
          StorageSnapshot.new(
            :id => snapshot[:aws_id],
            :state => snapshot[:aws_status],
            :storage_volume_id => snapshot[:aws_volume_id],
            :created => snapshot[:aws_started_at]
          )
        end

        def convert_load_balancer(credentials, loadbalancer)
          puts loadbalancer.inspect
          realms = []
          balancer_realms = loadbalancer[:availability_zones].each do |zone|
            realms << realm(credentials, zone)
          end
          balancer = LoadBalancer.new({
            :id => loadbalancer[:name],
            :created_at => loadbalancer[:created_time],
            :public_addresses => [loadbalancer[:dns_name]],
            :realms => realms
          })
          balancer.listeners = []
          balancer.instances = []
          loadbalancer[:listeners].each do |listener|
            balancer.add_listener(listener)
          end
          loadbalancer[:instances].each do |instance|
            balancer.instances << instance(credentials, :id => instance[:id])
          end
          balancer
        end

        def convert_state(ec2_state)
          case ec2_state
            when "terminated"
              "STOPPED"
            when "stopped"
              "STOPPED"
            when "running"
              "RUNNING"
            when "pending"
              "PENDING"
            when "shutting-down"
              "STOPPED"
          end
        end

        exceptions do
          on /(AuthFailure|InvalidAccessKeyId)/ do
            status 401
          end

          on /Error/ do
            status 502
          end

          on /Deltacloud::Runner::(\w+)/ do
            status 500
          end
        end

      end
    end
  end
end
