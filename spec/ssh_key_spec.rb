require 'spec_helper'

describe Gitolite::SSHKey do
  let(:key_root) { File.join(File.dirname(__FILE__), 'fixtures', 'keys') }
  let(:key_path) { File.join(key_root, 'bob', 'bob.pub') }

  let(:valid_key) { File.read(key_path) }
  let(:invalid_key) { 'not_a_real_key' }

  let(:output_dir) { '/tmp' }

  describe '#from_string' do
    it 'should construct an SSH key from a string' do
      s = Gitolite::SSHKey.from_string(valid_key, { owner: 'bob' })

      expect(s.owner).to eq('bob')
      expect(s.location).to eq(Gitolite::GitoliteAdmin::DEFAULTS[:location])

      parts = valid_key.split
      expect(s.type).to eq(parts[0])
      expect(s.blob).to eq(parts[1])
      expect(s.email).to eq(parts[2])
    end

    it 'should raise an ArgumentError when an owner isnt specified' do
      expect { Gitolite::SSHKey.from_string(valid_key) }.to raise_error
    end

    it 'should raise an ArgumentError when the key is invalid' do
      expect { Gitolite::SSHKey.from_string(invalid_key, { owner: 'bob' }) }.to raise_error
    end

    it 'should use the location when one is specified' do
      s = Gitolite::SSHKey.from_string(valid_key, { owner: 'bob', location: 'home' })

      expect(s.owner).to eq('bob')
      expect(s.location).to eq('home')
      expect(s.blob).to eq(valid_key.split[1])
    end
  end

  describe '#from_file' do
    let(:sshkey) { Gitolite::SSHKey.from_file(key_root, key_path) }

    context 'with key in root' do
      let(:key_path) {  File.join(key_root, 'alice.pub') }
      it 'should load a basic key directly in the keydir' do
        expect(sshkey.owner).to eq('alice')
        expect(sshkey.location).to eq(Gitolite::GitoliteAdmin::DEFAULTS[:location])
        expect(sshkey.subfolders).to eq([])
      end
    end

    it 'should load an old-style key from a file' do
      expect(sshkey.owner).to eq('bob')
      expect(sshkey.blob).to eq(valid_key.split[1])
      expect(sshkey.location).to eq(Gitolite::GitoliteAdmin::DEFAULTS[:location])
      expect(sshkey.subfolders).to eq(['bob'])
    end

    context 'with arbitrary subfolders and location' do
      let(:key_path) { File.join(key_root, 'bob', 'deploy', 'server1', 'bob_deploy.pub') }

      it 'should load a key correctly' do
        expect(sshkey.owner).to eq('bob_deploy')
        expect(sshkey.location).to eq('server1')
        expect(sshkey.subfolders).to eq(['bob', 'deploy'])
      end
    end

    context 'with an email as filename' do
      let(:key_path) { File.join(key_root, 'bob', 'bob@example.com.pub') }

      it 'should load a key with an e-mail owner from a file' do
        expect(sshkey.owner).to eq('bob@example.com')
        expect(sshkey.email).to eq('bob@example.com')

        # parent does not match old-style owner directories,
        # thus it is expected to be a location
        expect(sshkey.location).to eq('bob')
        expect(sshkey.subfolders).to eq([])
      end
    end

    context 'with subfolder and location' do
      let(:key_path) { File.join(key_root, 'bob', 'desktop', 'bob.pub') }

      it 'should load a key from a file within location' do
        expect(sshkey.owner).to eq('bob')
        expect(sshkey.location).to eq('desktop')
        expect(sshkey.subfolders).to eq(['bob'])
      end
    end
  end

  describe 'with forged data' do
    let(:type) { 'ssh-rsa' }
    let(:blob) { Forgery::Basic.text(at_least: 372, at_most: 372) }
    let(:email) { Forgery::Internet.email_address }
    let(:owner) { Forgery::Name.first_name }
    let(:location) { Forgery::Name.location }

    describe '#new' do
      it 'should create a valid ssh key' do
        s = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob })

        expect(s.to_s).to eq([type, blob, email].join(' '))
        expect(s.owner).to eq(email)
      end

      it 'should create a valid ssh key while specifying an owner and location' do
        s = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob, location: location })

        expect(s.to_s).to eq([type, blob, email].join(' '))
        expect(s.owner).to eq(email)
        expect(s.location).to eq(location)
      end
    end

    describe '#filename' do
      it 'should create a filename that is the <email>.pub' do
        s = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob })

        expect(s.filename).to eq("#{email}.pub")
      end
    end

    describe '#relative_path' do
      it 'should include the location' do
        sshkey = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob, location: location })
        expect(sshkey.relative_path).to eq(File.join(location, "#{email}.pub"))
      end

      it 'should include subfolders' do
        sshkey = Gitolite::SSHKey.new(
          {
            owner: email,
            type: type, blob: blob,
            subfolders: ['foo', 'bar'], location: location
          }
        )
        expect(sshkey.relative_path).to eq(File.join('foo', 'bar', location, "#{email}.pub"))
      end
    end

    describe '#to_file' do
      let(:sshkey) { Gitolite::SSHKey.new({ owner: owner, type: type, blob: blob, location: location }) }

      it 'should write a "valid" SSH public key to the file system' do
        path = sshkey.to_file(output_dir)
        expected_path = File.join(output_dir, location, "#{owner}.pub")
        expect(path).to eq(expected_path)

        ## compare raw string with written file
        expect(sshkey.to_s).to eq(File.read(expected_path))
      end
    end

    describe '==' do
      it 'should have two keys equalling one another' do
        type = 'ssh-rsa'
        s1 = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob })
        s2 = Gitolite::SSHKey.new({ owner: email, type: type, blob: blob })

        expect(s1).to eq(s2)
      end
    end
  end
end
