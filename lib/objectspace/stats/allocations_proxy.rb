# Copyright 2013 Google Inc. All Rights Reserved.
# Licensed under the Apache License, Version 2.0, found in the LICENSE file.

class ObjectSpace::Stats
  # AllocationsProxy acts as a proxy for an array of Allocation objects. The
  # idea behind this class is merely to provide some domain-specific methods
  # for transforming (filtering, sorting, and grouping) allocation information.
  # This class uses the Command pattern heavily, in order to build and maintain
  # the list of transforms it will ultimately perform, before retrieving the
  # transformed collection of Allocations.
  #
  # Chaining
  # ========
  #
  # Use of the Command pattern and Procs allows for transform-chaining in any
  # order. Apply methods such as {#from} and {#group_by} to build the internal
  # list of transforms. The transforms will not be applied to the collection of
  # Allocations until a call to {#to_a} ({#all}) resolves them.
  #
  # Filtering Transforms
  # --------------------
  #
  # Methods that filter the collection of Allocations will add a transform to
  # an Array, `@wheres`. When the result set is finally retrieved, each where
  # is applied serially, so that `@wheres` represents a logical conjunction
  # (_"and"_) of of filtering transforms. Presently there is no way to _"or"_
  # filtering transforms together with a logical disjunction.
  #
  # Mapping Transforms
  # ------------------
  #
  # Grouping Transform
  # ------------------
  #
  # Only one method will allow a grouping transform: {#group_by}. Only one
  # grouping transform is allowed; subsequent calls to {#group_by} will only
  # replace the previous grouping transform.
  class AllocationsProxy

    # Instantiate an {AllocationsProxy} with an array of Allocations. {AllocationProxy's} view of `pwd` is set at instantiation.
    #
    # @param [Array<Allocation>] allocations array of Allocation objects
    def initialize(allocations)
      @allocations = allocations
      @pwd = Dir.pwd
      @wheres = []
      @group_by = nil
      @mappers  = []
    end

    def to_a
      results = @allocations

      @wheres.each do |where|
        results = where.call(results)
      end

      # First apply group_by
      results = @group_by.call(results) if @group_by

      # Apply each mapper
      @mappers.each do |mapper|
        results = mapper.call(results)
      end

      results
    end
    alias :all :to_a

    def sorted_by_size
      @mappers << Proc.new do |allocations|
        allocations.sort_by { |key, value| -value.size }
      end

      self
    end

    # Select allocations for which the {Allocation#sourcefile sourcefile}
    # includes `pattern`.
    #
    # `#from` can be called multiple times, adding to `@wheres`. See
    # documentation for {AllocationsProxy} for more information about chaining.
    #
    # @param [String] pattern the partial file path to match against, in the
    #   {Allocation#sourcefile Allocation's sourcefile}.
    def from(pattern)
      @wheres << Proc.new do |allocations|
        allocations.select { |allocation| allocation.sourcefile[pattern] }
      end

      self
    end

    # Select allocations for which the {Allocation#sourcefile sourcefile} does
    # not include `pattern`.
    #
    # `#not_from` can be called multiple times, adding to `@wheres`. See
    # documentation for {AllocationsProxy} for more information about chaining.
    #
    # @param [String] pattern the partial file path to match against, in the
    #   {Allocation#sourcefile Allocation's sourcefile}.
    def not_from(pattern)
      @wheres << Proc.new do |allocations|
        allocations.reject { |allocation| allocation.sourcefile[pattern] }
      end

      self
    end

    # Select allocations for which the {Allocation#sourcefile sourcefile}
    # includes the present working directory.
    #
    # `#from_pwd` can be called multiple times, adding to `@wheres`. See
    # documentation for {AllocationsProxy} for more information about chaining.
    def from_pwd
      @wheres << Proc.new do |allocations|
        allocations.select { |allocation| allocation.sourcefile[@pwd] }
      end

      self
    end

    def group_by(*args)
      @group_by = Proc.new do |allocations|
        getters = attribute_getters(args)

        allocations.group_by do |allocation|
          getters.map { |getter| getter.call(allocation) }
        end
      end

      self
    end

    def where(hash)
      @wheres << Proc.new do |allocations|
        conditions = hash.inject({}) do |h, pair|
          faux, value = *pair
          getter = attribute_getters([faux]).first
          h.merge(getter => value)
        end

        allocations.select do |allocation|
          conditions.all? { |getter, value| getter.call(allocation) == value }
        end
      end

      self
    end

    def attribute_getters(faux_attributes)
      faux_attributes.map do |faux|
        if faux.to_s[0] == "@"
          # use the public API rather than that instance_variable; don't want false nils
          lambda { |allocation| allocation.send(faux.to_s[1..-1].to_sym) }
        elsif Allocation::Helpers.include? faux
          lambda { |allocation| allocation.send(faux) }
        else
          lambda { |allocation| allocation.object.send(faux) }
        end
      end
    end
    private :attribute_getters

    # Map to bytes via {Allocation#memsize #memsize}. This is done in one of two ways:
    #
    # * If the current result set is an Array, then this transform just maps
    #   each Allocation to its `#memsize`.
    # * If the current result set is a Hash (meaning it has been grouped), then
    #   this transform maps each value in the Hash (which is an Array of
    #   Allocations) to the sum of the Allocation `#memsizes` within.
    def bytes
      @mappers << Proc.new do |allocations|
        if allocations.is_a? Array
          allocations.map(&:memsize)
        elsif allocations.is_a? Hash
          bytes_h = {}
          allocations.each do |key, allocations|
            bytes_h[key] = allocations.inject(0) { |sum, allocation| sum + allocation.memsize }
          end
          bytes_h
        end
      end

      self
    end

    DEFAULT_COLUMNS = [:sourcefile, :sourceline, :class_path, :method_id, :memsize, :class]
    NUMERIC_COLUMNS = [:sourceline, :memsize]
    def to_text
      resolved = to_a

      widths = DEFAULT_COLUMNS.map do |attr|
        if attr == :class
          max_length_among(resolved.map { |a| a.object.class } << attr.to_s)
        else
          max_length_among(resolved.map(&attr) << attr.to_s)
        end
      end

      text = DEFAULT_COLUMNS.each_with_index.map { |attr, idx|
        attr.to_s.center(widths[idx])
      }.join("  ").rstrip << "\n"

      text << widths.map { |width|
        "-" * width
      }.join("  ") << "\n"

      text << resolved.map { |allocation|
        DEFAULT_COLUMNS.each_with_index.map { |attr, idx|
          if NUMERIC_COLUMNS.include? attr
            allocation.send(attr).to_s.rjust(widths[idx])
          else
            if attr == :class
              allocation.object.send(attr).to_s.ljust(widths[idx])
            else
              allocation.send(attr).to_s.ljust(widths[idx])
            end
          end
        }.join("  ").rstrip << "\n"
      }.join("")
    end

    def max_length_among(ary)
      ary.inject(0) {|max, el| max > el.to_s.size ? max : el.to_s.size }
    end
    private :max_length_among
  end
end