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

# Methods added to this helper will be available to all templates in the application.

require 'benchmark'

module ApplicationHelper

  include Deltacloud

  def bread_crumb
    s = "<ul class='breadcrumb'><li class='first'><a href='#{url_for('/')}'>&#948</a></li>"
    url = request.path_info.split('?')  #remove extra query string parameters
    levels = url[0].split('/') #break up url into different levels
    levels.each_with_index do |level, index|
      unless level.blank?
        if index == levels.size-1 ||
           (level == levels[levels.size-2] && levels[levels.size-1].to_i > 0)
          s += "<li class='subsequent'>#{level.gsub(/_/, ' ')}</li>\n" unless level.to_i > 0
        else
            link = levels.slice(0, index+1).join("/")
            s += "<li class='subsequent'><a href=\"#{url_for(link)}\">#{level.gsub(/_/, ' ')}</a></li>\n"
        end
      end
    end
    s+="<li class='docs'>#{link_to_documentation}</li>"
    s+="</ul>"
  end

  def instance_action_method(action)
    action_method(action, :instances)
  end

  def action_method(action, collection)
    collections[collection].operations[action.to_sym].method
  end

  def driver_has_feature?(feature_name, collection_name = :instances)
    not driver.features(collection_name).select{ |f| f.name.eql?(feature_name) }.empty?
  end

  def driver_has_auth_features?
    driver_has_feature?(:authentication_password) || driver_has_feature?(:authentication_key)
  end

  def driver_auth_feature_name
    return 'key' if driver_has_feature?(:authentication_key)
    return 'password' if driver_has_feature?(:authentication_password)
  end

  def driver_has_bucket_location_feature?
    driver.features(:buckets).each do |feat|
      return true if feat.name == :bucket_location
    end
    false
  end

  def filter_all(model)
      filter = {}
      filter.merge!(:id => params[:id]) if params[:id]
      filter.merge!(:architecture => params[:architecture]) if params[:architecture]
      filter.merge!(:owner_id => params[:owner_id]) if params[:owner_id]
      filter.merge!(:state => params[:state]) if params[:state]
      filter = {} if filter.keys.size.eql?(0)
      singular = model.to_s.singularize.to_sym
      @benchmark = Benchmark.measure do
        @elements = driver.send(model.to_sym, credentials, filter)
      end
      headers['X-Backend-Runtime'] = @benchmark.real.to_s
      instance_variable_set(:"@#{model}", @elements)
      respond_to do |format|
        format.html { haml :"#{model}/index" }
        format.xml { haml :"#{model}/index" }
        format.json { convert_to_json(singular, @elements) }
      end
  end

  def show(model)
    @benchmark = Benchmark.measure do
      @element = driver.send(model, credentials, { :id => params[:id]} )
    end
    instance_variable_set("@#{model}", @element)
    if @element
      respond_to do |format|
        format.html { haml :"#{model.to_s.pluralize}/show" }
        format.xml { haml :"#{model.to_s.pluralize}/show" }
        format.json { convert_to_json(model, @element) }
      end
    else
        report_error(404)
    end
  end

  def report_error(code=nil)
    @error, @code = request.env['sinatra.error'], code
    @code = 500 if not @code and not @error.class.method_defined? :code
    if @error
      unless @error.class.method_defined? :cause
        @cause = nil
      else
        @cause = @error.cause
      end
    end
    response.status = @code || @error.code
    respond_to do |format|
      format.xml { haml :"errors/#{@code || @error.code}", :layout => false }
      format.html { haml :"errors/#{@code || @error.code}", :layout => :error }
    end
  end

  def instance_action(name)
    original_instance = driver.instance(credentials, :id => params[:id])

    # If original instance doesn't include called action
    # return with 405 error (Method is not Allowed)
    unless driver.instance_actions_for(original_instance.state).include?(name.to_sym)
      return report_error(405)
    end

    @instance = driver.send(:"#{name}_instance", credentials, params["id"])

    if name == :destroy or @instance.class!=Instance
      respond_to do |format|
        format.xml { return 204 }
        format.json { return 204 }
        format.html { return redirect(instances_url) }
      end
    end

    respond_to do |format|
      format.xml { haml :"instances/show" }
      format.html { haml :"instances/show" }
      format.json {convert_to_json(:instance, @instance) }
    end
  end

  def cdata(text = nil, &block)
    text ||= capture_haml(&block)
    "<![CDATA[#{text.strip}]]>"
  end

  def render_cdata(text)
    "<pem><![CDATA[#{text.strip}]]></pem>"
  end

  def link_to_action(action, url, method)
    capture_haml do
      haml_tag :form, :method => :post, :action => url, :class => [:link, method] do
        haml_tag :input, :type => :hidden, :name => '_method', :value => method
        haml_tag :button, :type => :submit do 
          haml_concat action
        end
      end
    end
  end

  def link_to_format(format)
    return '' unless request.env['REQUEST_URI']
    uri = request.env['REQUEST_URI']
    return if uri.include?('format=')
    if uri.include?('?')
      uri+="&format=#{format}"
    else
      uri+="?format=#{format}"
    end
    '<a href="%s">%s</a>' % [uri, "#{format}".upcase]
  end

  def link_to_documentation
    return '' unless request.env['REQUEST_URI']
    uri = request.env['REQUEST_URI'].dup
    uri.gsub!('/api', '/api/docs/') unless uri.include?("docs") #i.e. if already serving under /api/docs, leave it be
    '<a href="%s">[ Documentation ]</a>' % uri
  end

  def action_url
    if [:index].include?(@operation.name)
      url_for("/api/#{@collection.name.to_s}")
    elsif [:show, :stop, :start, :reboot, :attach, :detach].include?(@operation.name)
      url_for("/api/#{@collection.name.to_s}/:id/#{@operation.name}")
    elsif [:destroy].include?(@operation.name)
      url_for("/api/#{@collection.name.to_s}/:id")
    else
      url_for("/api/#{@collection.name}/#{@operation.name}")
    end
  end

  def image_for_state(state)
    state_img = "stopped" if (state!='RUNNING' or state!='PENDING')
    "<img src='/images/#{state.downcase}.png' title='#{state}'/>"
  end

  def truncate_words(text, length = 10)
    return nil unless text
    return text if text.length<=length
    end_string = "...#{text[(text.length-(length/2))..text.length]}"
    "#{text[0..(length/2)]}#{end_string}"
  end

  # Reverse the entrypoints hash for a driver from drivers.yaml; note that
  # +d+ is a hash, not an actual driver object
  def driver_provider(d)
    result = {}
    if d[:entrypoints]
      d[:entrypoints].each do |kind, details|
        details.each do |prov, url|
          result[prov] ||= {}
          result[prov][kind] = url
        end
      end
    end
    result
  end
end
