module Gitolite
  class GitoliteAdmin

    attr_accessor :repo

    CONF_DIR    = "conf"
    KEY_DIR     = "keydir"

    CONFIG_FILE = "gitolite.conf"
    CONFIG_PATH = File.join(CONF_DIR, "gitolite.conf")


    # Default settings
    DEFAULT_SETTINGS = {
      # clone/push url settings
      git_user: 'git', 
      hostname: 'localhost',

      # Commit settings
      author_name: 'gitolite-rugged gem',
      author_email: 'gitolite-rugged@localhost',
      commit_msg: 'Commited by the gitolite-rugged gem'
    }

    class << self

      # Checks if the given path is a gitolite-admin repository
      # A valid repository contains a conf folder, keydir folder,
      # and a configuration file within the conf folder
      def is_gitolite_admin_repo?(dir)
        # First check if it is a git repository
        begin
          repo = Rugged::Repository.new(dir)
          return false if repo.empty?
        rescue Rugged::RepositoryError
          return false
        end

        # Check if config file, key directory exist
        [ File.join(dir, CONF_DIR), File.join(dir, KEY_DIR),
          File.join(dir, CONFIG_PATH)
        ].each { |f| return false unless File.exists?(f) }

        true
      end

      def admin_url(settings)
        [settings[:git_user], '@', settings[:host], '/gitolite-admin.git'].join
      end
    end

    # Intialize with the path to
    # the gitolite-admin repository
    #
    # Settings:
    # :git_user: The git user to SSH to (:git_user@localhost:gitolite-admin.git), defaults to 'git'
    # :private_key: The key file containing the private SSH key for :git_user
    # :public_key: The key file containing the public SSH key for :git_user
    # :host: Hostname for clone url. Defaults to 'localhost'
    # The settings hash is forwarded to +GitoliteAdmin.new+ as options.
    def initialize(path, settings = {})
      @path = path
      @settings = DEFAULT_SETTINGS.merge(settings)

      # Ensure SSH key settings exist
      @settings.fetch(:public_key)
      @settings.fetch(:private_key)

      # setup credentials
      @credentials = Rugged::Credentials::SshKey.new(
        username: settings[:git_user], publickey: settings[:public_key], 
        privatekey: settings[:private_key] )
      
      @repo = 
      if self.class.is_gitolite_admin_repo?(path)
        Rugged::Repository.new(path)
      else
        clone
      end

      @config_file_path = File.join(@path, CONF_DIR, CONFIG_FILE)
      @conf_dir_path    = File.join(@path, CONF_DIR)
      @key_dir_path     = File.join(@path, KEY_DIR)

      @commit_author = { email: settings[:author_email], name: settings[:author_name] }

      reload!
    end

    def config
      @config ||= load_config
    end


    def config=(config)
      @config = config
    end


    def ssh_keys
      @ssh_keys ||= load_keys
    end


    def add_key(key)
      unless key.instance_of? Gitolite::SSHKey
        raise GitoliteAdminError, "Key must be of type Gitolite::SSHKey!"
      end

      ssh_keys[key.owner] << key
    end


    def rm_key(key)
      unless key.instance_of? Gitolite::SSHKey
        raise GitoliteAdminError, "Key must be of type Gitolite::SSHKey!"
      end

      ssh_keys[key.owner].delete key
    end


    # This method will destroy all local tracked changes, resetting the local gitolite
    # git repo to HEAD and reloading the entire repository
    def reset!
      @repo.reset('origin/master', :hard)
      reload!
    end


    # This method will destroy the in-memory data structures and reload everything
    # from the file system
    def reload!
      @ssh_keys = load_keys
      @config = load_config
    end


    # Writes all changed aspects out to the file system
    # will also stage all changes then commit
    def save()

      # Add all changes to index (staging area)
      index = @repo.index

      #Process config file (if loaded, i.e. may be modified)
      if @config
        new_conf = @config.to_file(@conf_dir_path)

        # Rugged wants relative paths
        index.add(CONFIG_PATH)
      end

      #Process ssh keys (if loaded, i.e. may be modified)
      if @ssh_keys
        files = list_keys.map{|f| File.basename f}
        keys  = @ssh_keys.values.map{|f| f.map {|t| t.filename}}.flatten

        to_remove = (files - keys).map { |f| File.join(@key_dir, f) }
        to_remove.each do |key|
          File.unlink key
          index.remove key
        end

        @ssh_keys.each_value do |key|
          # Write only keys from sets that has been modified
          next if key.respond_to?(:dirty?) && !key.dirty?
          key.each do |k|
            new_key = k.to_file(@key_dir_path)
            index.add new_key
          end
        end
      end

      # Write index to git and resync fs
      commit_tree = index.write_tree @repo
      index.write

      commit_author = { email: 'wee@example.org', name: 'gitolite-rugged gem', time: Time.now }

      Rugged::Commit.create(@repo,
        author: commit_author,
        committer: commit_author,
        message: @settings[:commit_msg],
        parents: [repo.head.target],
        tree: commit_tree,
        update_ref: 'HEAD'
      )
    end


    # Push back to origin
    def apply
      @repo.push 'origin', ['refs/heads/master']
    end


    # Commits all staged changes and pushes back to origin
    def save_and_apply()
      save
      apply
    end


    # Updates the repo with changes from remote master
    # Warning: This resets the repo before pulling in the changes.
    def update(settings = {})
      reset!

      # Currently, this only supports merging origin/master into master.
      master = repo.branches["master"].target
      origin_master = repo.branches["origin/master"].target

      # Create the merged index in memory
      merge_index = repo.merge_commits(master, origin_master)

      # Complete the merge by comitting it
      merge_commit = Rugged::Commit.create(@repo, 
        parents: [ master, origin_master ],
        tree: merge_index.write_tree(@repo),
        message: '[gitolite-rugged] Merged `origin/master` into `master`',
        author: @commit_author,
        committer: @commit_author,
        update_ref: 'master'
      )

      reload!
    end


    private


    # Clone the gitolite-admin repo
    # to the given path.  
    # 
    # The repo is cloned from the url
    # +(:git_user)@(:hostname)/gitolite-admin.git+
    #
    # The hostname may use an optional :port to allow for custom SSH ports.
    # E.g., +git@localhost:2222/gitolite-admin.git+
    #
    def clone()
      Rugged::Repository.clone_at(admin_url(@settings), File.expand_path(@path), credentials: @creds)
    end    


    def load_config
      Config.new(@config_file_path)
    end


    def list_keys
      Dir.glob(@key_dir_path + '/**/*.pub')
    end


    # Loads all .pub files in the gitolite-admin
    # keydir directory
    def load_keys
      keys = Hash.new {|k,v| k[v] = DirtyProxy.new([])}

      list_keys.each do |key|
        new_key = SSHKey.from_file(key)
        owner = new_key.owner

        keys[owner] << new_key
      end

      # Mark key sets as unmodified (for dirty checking)
      keys.values.each{|set| set.clean_up!}

      keys
    end
  end
end
