#!/usr/bin/env ruby -rubygems
# NSCoding-inspired library for encoding ruby object graphs.
# Also includes JSCoder - encoder which decodes objects into a javascript function.
# Author: Oleg Andreev <oleganza@gmail.com>
# Updated: October 10, 2010
#
# Copyright (c) 2010 Oleg Andreev <oleganza@gmail.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

module Roaster
  
  class Coder
    
    # The object to start coding with
    attr_accessor :root_object 
    
    # The map from the object to its properties
    # Each property is encoded as a pair [name, value]
    # Properties are empty for NilClass, TrueClass, FalseClass, Numeric, String, Array and Hash classes
    attr_accessor :identity_map  # { object => [ [name, value], ... ] }
    
    # List of references for the currently encoded object when calling encode_with_coder
    attr_accessor :current_object_references
    
    # The selector which is used to encode the object's properties
    # By default it is :encode_with_coder, but can be changed for different encoding format or purpose
    attr_accessor :encode_selector
  
    def initialize(root_object = nil)
      self.root_object = root_object
      self.encode_selector = :encode_with_coder
    end
    
    def encode_if_needed
      return if self.identity_map # return if already encoded
      self.identity_map = Hash.new
      self.current_object_references = []
      @identity_map[root_object] = current_object_references
      root_object.send(encode_selector, self)
    end
    
    def encode_object_for_key(object, key)
      return if @identity_map[object]
      references = current_object_references # remember current references on stack
      references << [key, object] if key
      if object.is_coded_as_object?
        self.current_object_references = [] # replace with a new list for the new object
        @identity_map[object] = current_object_references
        object.send(encode_selector, self)
        self.current_object_references = references # restore value
      end
    end
    
  end # Coder


  
  class ::Object
    def encode_with_coder(coder)
      # noop, subclasses may encode their inner state as they want
    end
    def is_coded_as_object? # not true for primitive objects like nil, true, false, strings, symbols, numbers
      true
    end
  end

  class ::Array
    def encode_with_coder(coder)
      each do |item|
        # encode all the objects, but do not assign as references of the array
        coder.encode_object_for_key(item, nil)
      end
    end
  end

  class ::Hash
    def encode_with_coder(coder)
      each do |key, item|
        # encode all the objects, but do not assign as references of the hash
        coder.encode_object_for_key(item, nil)
      end      
    end
  end
  
  class ::NilClass
    def is_coded_as_object?; false; end
  end
  class ::FalseClass
    def is_coded_as_object?; false; end
  end
  class ::TrueClass
    def is_coded_as_object?; false; end
  end
  class ::Numeric
    def is_coded_as_object?; false; end
  end
  class ::String
    def is_coded_as_object?; false; end
  end
  class ::Symbol
    def is_coded_as_object?; false; end
  end



  # Batch encoding and DSL

  class Coder
    # batch-encoding
  
    # Example: coder.encode_properties_for_object([:name, :age], self)
    # Example: coder.encode_properties_for_object({:myname => :name, :myage => :age}, self)
    # Equivalent to coder.encode_dictionary({:name => self.name, :age => self.age})
    def encode_properties_for_object(names, object)
      if names.is_a?(Hash)
        names.each do |name, coding_key|
          encode_object_for_key(object.send(name), coding_key)
        end      
      else
        names.each do |name|
          encode_object_for_key(object.send(name), name)
        end
      end
    end

    # Example: coder.encode_dictionary({:name => name, :age => age})
    def encode_dictionary(dictionary)
      dictionary.each do |key, object|
        encode_object_for_key(object, key)
      end
    end
  end

  class ::Module
    def properties_for_coding(*properties, &blk)
      # we use a module instead of defining method on class itself to allow custom implementation
      m = ::Module.new
      if properties.size == 1 && properties.first.is_a?(Hash)
        mapping = properties[0]
        m.send(:define_method, :encode_with_coder) do |coder|
          super(coder)
          coder.encode_properties_for_object(mapping, self)
        end
      else
        m.send(:define_method, :encode_with_coder) do |coder|
          super(coder)
          coder.encode_properties_for_object(properties, self)
        end
        m.send(:define_method, :encoded_properties) do
          (super rescue []) + properties
        end
      end
      include m
      self
    end
    alias property_for_coding properties_for_coding
  
    def attr_accessor_with_coding(*attrs)
      if attrs.size == 1 && attrs.first.is_a?(Hash)
        attr_accessor(*(attrs.first.keys))
      else
        attr_accessor(*attrs)
      end
      properties_for_coding(*attrs)
    end
  end





  # JavaScript coding

  require 'json'
  class JSCoder < Coder
  
    def javascript_function
      encode_if_needed
      
      header_js = "(function(){\n"
      
      allocation_js = ""
      assignments_js = ""
      awakening_js = ""

      identity_map.each do |object, properties|
        variable_name = object.js_coder_variable_name
        allocation_js << %{var #{variable_name} = #{object.js_coder_allocation};\n}
        assignments_js << object.js_coder_assignments_for_properties(properties)
        awakening_js << object.js_coder_awake
      end
      
      if root_object.is_coded_as_object?
        r = root_object.js_coder_variable_name
        awakening_js << %{if(#{r} && #{r}.didAwakeAll) { #{r}.didAwakeAll(); }\n}
      end
      
      footer_js = "return #{root_object.js_coder_variable_name};\n})"
      
      header_js +
      allocation_js + 
      assignments_js + 
      awakening_js + 
      footer_js
    end
    
    
    class ::Object
      def js_coder_allocation
        %{new #{javascript_class_name}()}
      end
      def javascript_class_name
        self.class.name.to_s.gsub(/::/, ".")
      end
      def js_coder_variable_name
        @js_coder_variable_name ||= \
          self.javascript_class_name.split(".").last.gsub(/[a-z]+/,'').downcase + object_id.to_s
      end
      def js_coder_lvalue
        if is_coded_as_object?
          js_coder_variable_name
        else
          to_json
        end
      end
      def js_coder_assignments_for_properties(properties)
        properties.inject("") do |result, (name, value)|
          result << %{#{js_coder_variable_name}.#{name} = #{value.js_coder_lvalue};\n}
        end
      end
      def js_coder_awake
        if is_coded_as_object?
          v = js_coder_variable_name
          %{if(#{v} && #{v}.awake) { #{v}.awake(); }\n}
        else
          ""
        end
      end
    end # ::Object
    
    class ::Array
      def js_coder_allocation
        map do |value|
          if value.is_coded_as_object?
            nil # will be populated at the assignment stage
          else
            value
          end
        end.to_json
      end
      def js_coder_assignments_for_properties(properties)
        assignments_js = ""
        each_with_index do |value, index|
          if value.is_coded_as_object?
            assignments_js << %{#{js_coder_variable_name}[#{index}] = #{value.js_coder_lvalue};\n}
          end
        end
        super(properties) + assignments_js
      end
    end # ::Array
    
    class ::Hash
      def js_coder_allocation
        inject({}) do |h, (key,value)|
          if value.is_coded_as_object?
            h[key] = nil # will be populated at the assignment stage
          else
            h[key] = value
          end
          h
        end.to_json
      end
      def js_coder_assignments_for_properties(properties)
        assignments_js = ""
        each do |key, value|
          if value.is_coded_as_object?
            assignments_js << %{#{js_coder_variable_name}[#{key.to_json}] = #{value.js_coder_lvalue};\n}
          end
        end
        super(properties) + assignments_js
      end
    end # ::Hash
    
    class ::NilClass
      def js_coder_variable_name
        "n#{object_id}"
      end
      def js_coder_allocation
        "null"
      end
    end
    
    class ::FalseClass
      def js_coder_variable_name
        "f#{object_id}"
      end
      def js_coder_allocation
        "false"
      end
    end
    
    class ::TrueClass
      def js_coder_variable_name
        "t#{object_id}"
      end
      def js_coder_allocation
        "true"
      end
    end
    
    class ::Numeric
      def js_coder_variable_name
        "n#{object_id}"
      end
      def js_coder_allocation
        to_f
      end
    end
    
    class ::String
      def js_coder_variable_name
        "s#{object_id}"
      end
      def js_coder_allocation
        to_json
      end
    end
    
  end # JSCoder
  
end # Roaster




if $0 == __FILE__
  
  require 'json'
  include Roaster
  
  # Models

  
  class Shop
    properties_for_coding :highlighted_products, :main_shelf
    
    def highlighted_products
      @highlighted_products ||= main_shelf.products[0,2]
    end
    
    def main_shelf
      @main_shelf ||= Shelf.new
    end
  end
  
  class Shelf
    properties_for_coding :products, :config
    def products
      @products ||= [ Product.new("Apple"), Product.new("Orange"), Product.new("Banana") ]
    end
    
    def config
      @config ||= {
        :tint_color => "#ff4400",
        :height => 123,
        :default_product => products[1]
      }
    end
  end

  class Product
    attr_accessor_with_coding :title
    
    def initialize(title)
      self.title = title
    end
  end
  
  
  # Controllers
  
  class ShopController
    properties_for_coding :shop, :highlights_controller, :delegate, :struct
    
    def struct
      @struct ||= {:a => ['foo', 'bar', self, shop]}
    end
    
    def delegate
      self # testing cycle with a single object
    end
    
    def shop
      @shop ||= Shop.new
    end
    
    def highlights_controller
      @highlights_controller ||= HighlightsController.new
      @highlights_controller.delegate = self # testing cycle with intermediate object
      @highlights_controller
    end
    
  end
  
  class HighlightsController
    attr_accessor_with_coding :delegate
  end
  
  
  
  # Usage:
  
  controller = ShopController.new
  
  jscoder = JSCoder.new(controller)
  js = jscoder.javascript_function
  
  puts js

  puts "\n\n\n\n\n\nTests:\n\n"
  puts JSCoder.new(nil).javascript_function
  puts JSCoder.new(true).javascript_function
  puts JSCoder.new(false).javascript_function
  puts JSCoder.new(123.23).javascript_function
  puts JSCoder.new("string").javascript_function
  puts JSCoder.new(['foo', 'bar']).javascript_function
  puts JSCoder.new({:a => ['foo', 'bar']}).javascript_function
  
end

