require 'fileutils'
module Gitolite
  # Models an SSH key within gitolite
  # provides support for multikeys
  #
  # For an optional subdirectory in the keydir <folder>, we may
  # save keys for a single user:
  #
  # Types of multi keys:
  #   username: bob => <keydir>/<folder>/default/bob.pub
  #   username: bob, location: desktop => <keydir>/<folder>/desktop/bob.pub

  class SSHKey
    attr_accessor :subfolders, :owner, :location, :type, :blob, :email

    def initialize(args)
      # kwargs with required params
      # are only available for 2.1+,
      # thus we use the old style
      @owner = args.fetch(:owner)
      @type = args.fetch(:type)
      @blob = args.fetch(:blob)

      @email = args.fetch(:email, @owner)
      @location = args[:location] || GitoliteAdmin::DEFAULTS[:location]
      @subfolders = args[:subfolders] ||  []
    end

    class << self
      ##
      # Construct a SSHKey from a string
      def from_string(key_string, args)
        # Get parts of the key
        type, blob, email = key_string.split

        # We need at least a type or key
        if type.nil? || blob.nil?
          raise ArgumentError, "'#{key_string} is not a valid SSH key string"
        end

        new args.merge(
          {
            type: type,
            blob: blob,
            email: email
          }
        )
      end

      def from_file(key_root, key)
        raise "#{key} does not exist!" unless File.exists?(key)

        # Owner is the basename of the key
        # i.e., <folder>/<location>/<owner>.pub
        owner = File.basename(key, '.pub')

        location, subfolders = extract_structure(key_root, key, owner)

        # Use string key constructor
        from_string(File.read(key), { owner: owner, location: location, subfolders: subfolders })
      end

      ##
      # Parse the remaining values of the key
      # (location, subfolders)
      def extract_structure(key_root, key, owner)
        root_path = Pathname.new(key_root).expand_path
        key_path = Pathname.new(key).expand_path

        # Basic case: No subdirectories
        if key_path.parent == root_path
          return nil
        end

        # Location is the middle section of the path
        location_dir = key_path.parent
        location = location_dir.basename.to_s

        # Update remaining owners from old-style structure
        if owner == location
          return [GitoliteAdmin::DEFAULTS[:location], [owner]]
        end

        # Extract folder, if any
        subfolders = get_key_folders(location_dir.parent, root_path)

        [location, subfolders]
      end

      ##
      # Parse the key path above the key to be read.
      def get_key_folders(key_parent, root_path)
        if key_parent == root_path
          []
        else
          relative_path = key_parent.relative_path_from(root_path)
          relative_path.each_filename.to_a
        end
      end

      def delete_dir_if_empty(dir)
        if dir.directory? && Dir["#{dir}/*"].empty?
          dir.rmdir
        end
      rescue => e
        STDERR.puts("Warning: Couldn't delete directory '#{dir}': #{e.message}")
      end

      # Remove a key given a relative path
      #
      # Unlinks the key file and removes any empty parent directory
      # below key_dir
      def remove(key_root, relative_key)
        key_path = Pathname.new(File.join(key_root, relative_key)).expand_path
        root_path = Pathname.new(key_root).expand_path

        key = from_file(key_root, key_path)

        # Remove the file itself
        key_path.unlink

        # Remove the location, if it exists and is empty
        location_dir = key_path.parent
        if key.location == location_dir.basename
          delete_dir_if_empty(location_dir)
        end

        # Remove any empty subfolders this key may have created
        remove_remaining_parents(key, location_dir.parent, root_path)
      end

      def remove_remaining_parents(key, remaining, root_path)
        key.subfolders.reverse.each do |folder|
          if remaining != root_path && remaining.basename == folder
            delete_dir_if_empty(remaining)
            remaining = remaining.parent
          else
            return
          end
        end
      end
    end

    def to_s
      [@type, @blob, @email].join(' ')
    end

    def to_file(key_root)
      # Ensure multi-key directory structure
      # <subfolders>/<location?>/<owner>.pub
      key_file = File.join(key_root, relative_path)
      key_dir  = File.dirname(key_file)

      # Ensure subdirs exist
      FileUtils.mkdir_p(key_dir) unless File.directory?(key_dir)

      File.open(key_file, 'w') do |f|
        f.sync = true
        f.write(to_s)
      end
      key_file
    end

    def relative_path
      # both entries may be empty, which yields a / in File.join
      possible_segments = [@subfolders, @location, filename]
      filtered = possible_segments.select { |p| !p.nil? && !p.empty? }

      File.join(filtered)
    end

    def filename
      [@owner, '.pub'].join
    end

    def ==(key)
      @type == key.type &&
        @blob == key.blob &&
        @email == key.email &&
        @owner == key.owner &&
        @location == key.location &&
        @subfolders = key.subfolders
    end

    def hash
      [@owner, @location, @type, @blob, @email, @subfolders].hash
    end
  end
end
