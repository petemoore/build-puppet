## imported from https://github.com/glarizza/puppet-1/tree/bug/master/12833_OSX_PBKDF2_UPDATE
## THIS FILE IS TEMPORARY - it should be removed when this support is present in puppet
require 'puppet'
require 'puppet/provider/nameservice'
require 'facter/util/plist'
require 'fileutils'

class Puppet::Provider::NameService::CustomDirectoryService < Puppet::Provider::NameService
  # JJM: Dive into the singleton_class
  class << self
    # JJM: This allows us to pass information when calling
    #      Puppet::Type.type
    #  e.g. Puppet::Type.type(:user).provide :directoryservice, :ds_path => "Users"
    #  This is referenced in the get_ds_path class method
    attr_writer :ds_path
    attr_writer :macosx_version_major
  end

  initvars

  commands :dscl => "/usr/bin/dscl"
  commands :dseditgroup => "/usr/sbin/dseditgroup"
  commands :sw_vers => "/usr/bin/sw_vers"
  commands :plutil => '/usr/bin/plutil'
  confine :operatingsystem => :darwin
  defaultfor :operatingsystem => :darwin


  # JJM 2007-07-25: This map is used to map NameService attributes to their
  #     corresponding DirectoryService attribute names.
  #     See: http://images.apple.com/server/docs.Open_Directory_v10.4.pdf
  # JJM: Note, this is de-coupled from the Puppet::Type, and must
  #     be actively maintained.  There may also be collisions with different
  #     types (Users, Groups, Mounts, Hosts, etc...)
  def ds_to_ns_attribute_map; self.class.ds_to_ns_attribute_map; end
  def self.ds_to_ns_attribute_map
    {
      'RecordName' => :name,
      'PrimaryGroupID' => :gid,
      'NFSHomeDirectory' => :home,
      'UserShell' => :shell,
      'UniqueID' => :uid,
      'RealName' => :comment,
      'Password' => :password,
      'GeneratedUID' => :guid,
      'IPAddress'    => :ip_address,
      'ENetAddress'  => :en_address,
      'GroupMembership' => :members,
    }
  end

  # JJM The same table as above, inverted.
  def ns_to_ds_attribute_map; self.class.ns_to_ds_attribute_map end
  def self.ns_to_ds_attribute_map
    @ns_to_ds_attribute_map ||= ds_to_ns_attribute_map.invert
  end

  def self.password_hash_dir
    '/var/db/shadow/hash'
  end

  def self.users_plist_dir
    '/var/db/dslocal/nodes/Default/users'
  end

  def self.instances
    # JJM Class method that provides an array of instance objects of this
    #     type.
    # JJM: Properties are dependent on the Puppet::Type we're managine.
    type_property_array = [:name] + @resource_type.validproperties

    # Create a new instance of this Puppet::Type for each object present
    #    on the system.
    list_all_present.collect do |name_string|
      self.new(single_report(name_string, *type_property_array))
    end
  end

  def self.get_ds_path
    # JJM: 2007-07-24 This method dynamically returns the DS path we're concerned with.
    #      For example, if we're working with an user type, this will be /Users
    #      with a group type, this will be /Groups.
    #   @ds_path is an attribute of the class itself.
    return @ds_path if defined?(@ds_path)
    # JJM: "Users" or "Groups" etc ...  (Based on the Puppet::Type)
    #       Remember this is a class method, so self.class is Class
    #       Also, @resource_type seems to be the reference to the
    #       Puppet::Type this class object is providing for.
    #### XXX but of course 'Darwinusers' isn't what we want
    if @resource_type.name == 'group'
        'Groups'
    else
        'Users'
    end
  end

  def self.get_macosx_version_major
    return @macosx_version_major if defined?(@macosx_version_major)
    begin
      # Make sure we've loaded all of the facts
      Facter.loadfacts

      if Facter.value(:macosx_productversion_major)
        product_version_major = Facter.value(:macosx_productversion_major)
      else
        # TODO: remove this code chunk once we require Facter 1.5.5 or higher.
        Puppet.warning("DEPRECATION WARNING: Future versions of the directoryservice provider will require Facter 1.5.5 or newer.")
        product_version = Facter.value(:macosx_productversion)
        fail("Could not determine OS X version from Facter") if product_version.nil?
        product_version_major = product_version.scan(/(\d+)\.(\d+)./).join(".")
      end
      fail("#{product_version_major} is not supported by the directoryservice provider") if %w{10.0 10.1 10.2 10.3 10.4}.include?(product_version_major)
      @macosx_version_major = product_version_major
      return @macosx_version_major
    rescue Puppet::ExecutionFailure => detail
      fail("Could not determine OS X version: #{detail}")
    end
  end


  def self.list_all_present
    # JJM: List all objects of this Puppet::Type already present on the system.
    begin
      dscl_output = execute(get_exec_preamble("-list"))
    rescue Puppet::ExecutionFailure => detail
      fail("Could not get #{@resource_type.name} list from DirectoryService")
    end
    dscl_output.split("\n")
  end

  def self.parse_dscl_plist_data(dscl_output)
    Plist.parse_xml(dscl_output)
  end

  def self.generate_attribute_hash(input_hash, *type_properties)
    attribute_hash = {}
    input_hash.keys.each do |key|
      ds_attribute = key.sub("dsAttrTypeStandard:", "")
      next unless (ds_to_ns_attribute_map.keys.include?(ds_attribute) and type_properties.include? ds_to_ns_attribute_map[ds_attribute])
      ds_value = input_hash[key]
      case ds_to_ns_attribute_map[ds_attribute]
        when :members
          ds_value = ds_value # only members uses arrays so far
        when :gid, :uid
          # OS X stores objects like uid/gid as strings.
          # Try casting to an integer for these cases to be
          # consistent with the other providers and the group type
          # validation
          begin
            ds_value = Integer(ds_value[0])
          rescue ArgumentError
            ds_value = ds_value[0]
          end
        else ds_value = ds_value[0]
      end
      attribute_hash[ds_to_ns_attribute_map[ds_attribute]] = ds_value
    end

    converted_hash_plist = get_shadowhashdata(attribute_hash[:name])

    # NBK: need to read the existing password here as it's not actually
    # stored in the user record. It is stored at a path that involves the
    # UUID of the user record for non-Mobile local acccounts.
    # Mobile Accounts are out of scope for this provider for now
    attribute_hash[:password] = self.get_password(attribute_hash[:guid], attribute_hash[:name], converted_hash_plist) if @resource_type.validproperties.include?(:password) and Puppet.features.root?

    # GDL: The salt and iterations properties are only available in versions of OS X
    #      greater than 10.7
    attribute_hash[:salt] = self.get_salt(attribute_hash[:name], converted_hash_plist)
    attribute_hash[:iterations] = self.get_iterations(attribute_hash[:name], converted_hash_plist)
    attribute_hash
  end

  def self.single_report(resource_name, *type_properties)
    # JJM 2007-07-24:
    #     Given a the name of an object and a list of properties of that
    #     object, return all property values in a hash.
    #
    #     This class method returns nil if the object doesn't exist
    #     Otherwise, it returns a hash of the object properties.

    all_present_str_array = list_all_present

    # NBK: shortcut the process if the resource is missing
    return nil unless all_present_str_array.include? resource_name

    dscl_vector = get_exec_preamble("-read", resource_name)
    begin
      dscl_output = execute(dscl_vector)
    rescue Puppet::ExecutionFailure => detail
      fail("Could not get report.  command execution failed.")
    end

    # (#11593) Remove support for OS X 10.4 and earlier
    fail_if_wrong_version
    dscl_plist = self.parse_dscl_plist_data(dscl_output)

    self.generate_attribute_hash(dscl_plist, *type_properties)
  end

  def self.fail_if_wrong_version
    fail("Puppet does not support OS X versions < 10.5") unless self.get_macosx_version_major >= "10.5"
  end

  def self.get_exec_preamble(ds_action, resource_name = nil)
    # JJM 2007-07-24
    #     DSCL commands are often repetitive and contain the same positional
    #     arguments over and over. See http://developer.apple.com/documentation/Porting/Conceptual/PortingUnix/additionalfeatures/chapter_10_section_9.html
    #     for an example of what I mean.
    #     This method spits out proper DSCL commands for us.
    #     We EXPECT name to be @resource[:name] when called from an instance object.

    # (#11593) Remove support for OS X 10.4 and earlier
    fail_if_wrong_version
    command_vector = [ command(:dscl), "-plist", "." ]

    # JJM: The actual action to perform.  See "man dscl"
    #      Common actiosn: -create, -delete, -merge, -append, -passwd
    command_vector << ds_action
    # JJM: get_ds_path will spit back "Users" or "Groups",
    # etc...  Depending on the Puppet::Type of our self.
    if resource_name
      command_vector << "/#{get_ds_path}/#{resource_name}"
    else
      command_vector << "/#{get_ds_path}"
    end
    # JJM:  This returns most of the preamble of the command.
    #       e.g. 'dscl / -create /Users/mccune'
    command_vector
  end

  def self.set_password(resource_name, guid, password_hash)
    # Use Puppet::Util::Package.versioncmp() to catch the scenario where a
    # version '10.10' would be < '10.7' with simple string comparison. This
    # if-statement only executes if the current version is less-than 10.7
    if (Puppet::Util::Package.versioncmp(get_macosx_version_major, '10.7') == -1)
      password_hash_file = "#{password_hash_dir}/#{guid}"
      begin
        File.open(password_hash_file, 'w') { |f| f.write(password_hash)}
      rescue Errno::EACCES => detail
        fail("Could not write to password hash file: #{detail}")
      end

      # NBK: For shadow hashes, the user AuthenticationAuthority must contain a value of
      # ";ShadowHash;". The LKDC in 10.5 makes this more interesting though as it
      # will dynamically generate ;Kerberosv5;;username@LKDC:SHA1 attributes if
      # missing. Thus we make sure we only set ;ShadowHash; if it is missing, and
      # we can do this with the merge command. This allows people to continue to
      # use other custom AuthenticationAuthority attributes without stomping on them.
      #
      # There is a potential problem here in that we're only doing this when setting
      # the password, and the attribute could get modified at other times while the
      # hash doesn't change and so this doesn't get called at all... but
      # without switching all the other attributes to merge instead of create I can't
      # see a simple enough solution for this that doesn't modify the user record
      # every single time. This should be a rather rare edge case. (famous last words)

      dscl_vector = self.get_exec_preamble("-merge", resource_name)
      dscl_vector << "AuthenticationAuthority" << ";ShadowHash;"
      begin
        dscl_output = execute(dscl_vector)
      rescue Puppet::ExecutionFailure => detail
        fail("Could not set AuthenticationAuthority.")
      end
    else
      # 10.7 uses salted SHA512 password hashes which are 128 characters plus
      # an 8 character salt. Previous versions used a SHA1 hash padded with
      # zeroes. If someone attempts to use a password hash that worked with
      # a previous version of OS X, we will fail early and warn them. If the
      # version of OS X is greater than 10.7, a salted-sha512 PBKDF2 password
      # will be used (and Puppet will fail if the password hash isn't 256
      # characters. As of 10.8, you ALSO have the condition where a machine
      # could have been upgraded and there could be users that still have a
      # 10.7-style password hash. Apple actually upgrades that hash to a 10.8-
      # style PBKDF2 password hash if/when the user logs in. Based on that
      # behavior, if a machine is on version 10.8 AND a user exists with a
      # 10.7-style password hash, AND Puppet is enforcing a 10.8 style hash,
      # then it will remove the 10.7-style hash and create a 10.8-style hash.
      if get_macosx_version_major == '10.7'
        if password_hash.length != 136
          fail("OS X 10.7 requires a Salted SHA512 hash password of 136 characters." + \
               " Please check your password and try again.")
        else
          converted_hash_plist = get_shadowhashdata(resource_name)
          set_salted_sha512(resource_name, password_hash, converted_hash_plist)
        end
      else
        if password_hash.length != 256
         fail("OS X versions > 10.7 require a Salted SHA512 PBKDF2 password hash of " + \
               "256 characters. Please check your password and try again.")
        else
          converted_hash_plist = get_shadowhashdata(resource_name)
          converted_hash_plist.delete('SALTED-SHA512') if converted_hash_plist['SALTED-SHA512']
          set_salted_sha512_pbkdf2(resource_name, 'entropy', password_hash, converted_hash_plist)
        end
      end
    end
  end

  def self.get_password(guid, username, converted_hash_plist)
    # Use Puppet::Util::Package.versioncmp() to catch the scenario where a
    # version '10.10' would be < '10.7' with simple string comparison. This
    # if-statement only executes if the current version is less-than 10.7
    if (Puppet::Util::Package.versioncmp(get_macosx_version_major, '10.7') == -1)
      password_hash = nil
      password_hash_file = "#{password_hash_dir}/#{guid}"
      if File.exists?(password_hash_file) and File.file?(password_hash_file)
        fail("Could not read password hash file at #{password_hash_file}") if not File.readable?(password_hash_file)
        f = File.new(password_hash_file)
        password_hash = f.read
        f.close
      end
      password_hash
    else
      return nil if not converted_hash_plist

      # If you've upgraded from 10.7 to 10.8, you probably have an old-style
      # users's plist that uses SALTED-SHA512 instead of SALTED-SHA512-PBKDF2.
      # In this case, we need to use the correct method to discover the hash.
      if converted_hash_plist['SALTED-SHA512']
        get_salted_sha512(converted_hash_plist)
      else
        get_salted_sha512_pbkdf2(converted_hash_plist, 'entropy')
      end
    end
  end

  def self.get_shadowhashdata(resource_name)
  #  This method will convert the user's plist located in
  #  /var/db/dslocal/nodes/Default/users to XML and return the
  #  value of the ShadowHashData key.  This value is a binary
  #  encoded plist that is converted and returned as a Hash.
    if (not File.exists?("#{users_plist_dir}/#{resource_name}.plist")) \
    or (not File.readable?("#{users_plist_dir}/#{resource_name}.plist"))
      fail("#{users_plist_dir}/#{resource_name}.plist is not readable, " + \
            "please check that permissions are correct.")
    else
      converted_users_plist = plutil('-convert',    \
                                     'xml1',        \
                                     '-o',          \
                                     '/dev/stdout', \
                                     "#{users_plist_dir}/#{resource_name}.plist")
      users_plist = Plist::parse_xml(converted_users_plist)
      if users_plist['ShadowHashData']
        password_hash_plist = users_plist['ShadowHashData'][0].string
        convert_binary_to_xml(password_hash_plist)
      else
        false
      end
    end
  end

  def self.set_shadowhashdata(resource_name, converted_hash_plist, users_plist)
  # This method converts the nested plist back to binary, embeds it
  # into the user's plist, and convert the resultant plist back to
  # a binary plist that can be read by the system. Arguments passed
  # are the username, the nested plist, and the user's plist (as a hash)
    changed_plist = convert_xml_to_binary(converted_hash_plist)
    users_plist['ShadowHashData'][0].string = changed_plist
    Plist::Emit.save_plist(users_plist, "#{users_plist_dir}/#{resource_name}.plist")
    plutil('-convert', 'binary1', "#{users_plist_dir}/#{resource_name}.plist")
  end

  def self.get_salted_sha512(converted_hash_plist)
  # This method retrieves the password hash from the embedded-plist
  # retrieved from the 'ShadowHashData' key in the user's plist.
  # Converted_hash_plist['SALTED-SHA512'].string is a Base64 encoded
  # string. The password_hash provided as a resource attribute is a
  # hex value. We need to convert the Base64 encoded string to a
  # hex value and provide it back to Puppet.
    converted_hash_plist['SALTED-SHA512'].string.unpack("H*").first
  end

  def self.set_salted_sha512(resource_name, password_hash, converted_hash_plist)
    # This method takes passed arguments of the username, the password hash
    # to be set, and the current converted_hash_plist retrieved from the
    # system and sets the salted-sha512 hash according to how OS X 10.7 prefers
    # to use it. Finally, set_shadowhashdata() is called to save the changes
    # back to the local system.
    converted_users_plist = plutil('-convert',    \
                                   'xml1',        \
                                   '-o',          \
                                   '/dev/stdout', \
                                   "#{users_plist_dir}/#{resource_name}.plist")
    users_plist = Plist::parse_xml(converted_users_plist)
    converted_hash_plist['SALTED-SHA512'].string = \
      password_hash.unpack('a2'*(password_hash.size/2)).collect { |i| i.hex.chr }.join
    set_shadowhashdata(resource_name, converted_hash_plist, users_plist)
  end

  def self.get_salted_sha512_pbkdf2(converted_hash_plist, field)
  # This method reads the passed converted_hash_plist hash and returns values
  # according to which field is passed.  Arguments passed are the hash
  # containing the value read from the 'ShadowHashData' key in the User's
  # plist, and the field to be read (one of 'entropy', 'salt', or 'iterations')
    case field
    when 'entropy', 'salt'
      converted_hash_plist['SALTED-SHA512-PBKDF2'][field].string.unpack('H*').first
    when 'iterations'
      Integer(converted_hash_plist['SALTED-SHA512-PBKDF2'][field])
    else
      fail("Puppet has tried to read an incorrect value from the \
            'SALTED-SHA512-PBKDF2' hash. Acceptable fields are 'salt', \
            'entropy', or 'iterations'.")
    end
  end

  def self.set_salted_sha512_pbkdf2(resource_name, field, value, converted_hash_plist)
  # This method accepts a passed value and one of three fields: 'salt',
  # 'entropy', or 'iterations'.  These fields correspond with the fields
  # utilized in a PBKDF2 password hashing system.
  # (see http://en.wikipedia.org/wiki/PBKDF2 for more information).
  # The arguments passed are the username, the field to be changed (whether
  # 'salt, 'entropy, or 'iterations'), and a hash containing the value
  # to be set for the 'ShadowHashData' key in the User's plist.
    case field
    when 'salt', 'entropy'
      unless converted_hash_plist['SALTED-SHA512-PBKDF2']
        converted_hash_plist['SALTED-SHA512-PBKDF2'] = {}
      end
      unless converted_hash_plist['SALTED-SHA512-PBKDF2'][field]
        converted_hash_plist['SALTED-SHA512-PBKDF2'][field] = \
          StringIO.new unless converted_hash_plist['SALTED-SHA512-PBKDF2'][field]
      end
      converted_hash_plist['SALTED-SHA512-PBKDF2'][field].string =  \
        value.unpack('a2'*(value.size/2)).collect { |i| i.hex.chr }.join
    when 'iterations'
      converted_hash_plist['SALTED-SHA512-PBKDF2'][field] = Integer(value)
    else
      fail("Puppet has tried to set an incorrect field for the \
            'SALTED-SHA512-PBKDF2' hash. Acceptable fields are 'salt', \
            'entropy', or 'iterations'.")
    end
    converted_users_plist = plutil('-convert',    \
                                   'xml1',        \
                                   '-o',          \
                                   '/dev/stdout', \
                                   "#{users_plist_dir}/#{resource_name}.plist")
    users_plist = Plist::parse_xml(converted_users_plist)
    # For 10.8, authentication will fail unless this field contains 8 *'s
    users_plist['passwd'] = '*'*8
    set_shadowhashdata(resource_name, converted_hash_plist, users_plist)
  end
  # This method will accept a hash that has been returned from Plist::parse_xml
  # and convert it to a binary plist (string value).
  def self.convert_xml_to_binary(plist_data)
    Puppet.debug('Converting XML plist to binary')
    Puppet.debug('Executing: \'plutil -convert binary1 -o - -\'')
    IO.popen('plutil -convert binary1 -o - -', mode='r+') do |io|
      io.write plist_data.to_plist
      io.close_write
      @converted_plist = io.read
    end
    @converted_plist
  end

  # This method will accept a binary plist (as a string) and convert it to a
  # hash via Plist::parse_xml.
  def self.convert_binary_to_xml(plist_data)
    Puppet.debug('Converting binary plist to XML')
    Puppet.debug('Executing: \'plutil -convert xml1 -o - -\'')
    IO.popen('plutil -convert xml1 -o - -', mode='r+') do |io|
      io.write plist_data
      io.close_write
      @converted_plist = io.read
    end
    Puppet.debug('Converting XML values to a hash.')
    @plist_hash = Plist::parse_xml(@converted_plist)
    @plist_hash
  end

  # Unlike most other *nixes, OS X doesn't provide built in functionality
  # for automatically assigning uids and gids to accounts, so we set up these
  # methods for consumption by functionality like --mkusers
  # By default we restrict to a reasonably sane range for system accounts
  def self.next_system_id(id_type, min_id=20)
    dscl_args = ['.', '-list']
    if id_type == 'uid'
      dscl_args << '/Users' << 'uid'
    elsif id_type == 'gid'
      dscl_args << '/Groups' << 'gid'
    else
      fail("Invalid id_type #{id_type}. Only 'uid' and 'gid' supported")
    end
    dscl_out = dscl(dscl_args)
    # We're ok with throwing away negative uids here.
    ids = dscl_out.split.compact.collect { |l| l.to_i if l.match(/^\d+$/) }
    ids.compact!.sort! { |a,b| a.to_f <=> b.to_f }
    # We're just looking for an unused id in our sorted array.
    ids.each_index do |i|
      next_id = ids[i] + 1
      return next_id if ids[i+1] != next_id and next_id >= min_id
    end
  end


  def ensure=(ensure_value)
    super
    # We need to loop over all valid properties for the type we're
    # managing and call the method which sets that property value
    # dscl can't create everything at once unfortunately.
    if ensure_value == :present
      @resource.class.validproperties.each do |name|
        next if name == :ensure
        # LAK: We use property.sync here rather than directly calling
        # the settor method because the properties might do some kind
        # of conversion.  In particular, the user gid property might
        # have a string and need to convert it to a number
        if @resource.should(name)
          @resource.property(name).sync
        elsif value = autogen(name)
          self.send(name.to_s + "=", value)
        else
          next
        end
      end
    end
  end

  def password=(passphrase)
    exec_arg_vector = self.class.get_exec_preamble("-read", @resource.name)
    exec_arg_vector << ns_to_ds_attribute_map[:guid]
    begin
      guid_output = execute(exec_arg_vector)
      guid_plist = Plist.parse_xml(guid_output)
      # Although GeneratedUID like all DirectoryService values can be multi-valued
      # according to the schema, in practice user accounts cannot have multiple UUIDs
      # otherwise Bad Things Happen, so we just deal with the first value.
      guid = guid_plist["dsAttrTypeStandard:#{ns_to_ds_attribute_map[:guid]}"][0]
      self.class.set_password(@resource.name, guid, passphrase)
    rescue Puppet::ExecutionFailure => detail
      fail("Could not set #{param} on #{@resource.class.name}[#{@resource.name}]: #{detail}")
    end
  end

  def salt=(salt)
  # This is the setter method for the 'salt' property that is only used when
  # PBKDF2 passwords are necessary. This method uses
  # self.set_salted_sha512_pbkdf2() to set the value in the User's plist.
    if (Puppet::Util::Package.versioncmp(self.class.get_macosx_version_major, '10.7') == 1)
      converted_hash_plist = self.class.get_shadowhashdata(@resource[:name])
      self.class.set_salted_sha512_pbkdf2(@resource[:name], 'salt', salt, converted_hash_plist)
    end
  end

  def iterations=(iterations)
  # This is the setter method for the 'iterations' property that is only used
  # when PBKDF2 passwords are necessary. This method uses
  # self.set_salted_sha512_pbkdf2() to set the value in the User's plist.
    if (Puppet::Util::Package.versioncmp(self.class.get_macosx_version_major, '10.7') == 1)
      converted_hash_plist = self.class.get_shadowhashdata(@resource[:name])
      self.class.set_salted_sha512_pbkdf2(@resource[:name], 'iterations', iterations, converted_hash_plist)
    end
  end

  def self.get_iterations(username, converted_hash_plist)
  # This is the getter method for the 'iterations' property that is only used
  # when PBKDF2 passwords are necessary. This method uses
  # self.get_salted_sha512_pbkdf2() to get the value from the User's plist.
    if converted_hash_plist
      get_salted_sha512_pbkdf2(converted_hash_plist, 'iterations') unless converted_hash_plist['SALTED-SHA512']
    end
  end

  def self.get_salt(username, converted_hash_plist)
  # This is the getter method for the 'salt' property that is only used
  # when PBKDF2 passwords are necessary. This method uses
  # self.get_salted_sha512_pbkdf2() to get the value from the User's plist.
    if converted_hash_plist
      get_salted_sha512_pbkdf2(converted_hash_plist, 'salt') unless converted_hash_plist['SALTED-SHA512']
    end
  end

  # NBK: we override @parent.set as we need to execute a series of commands
  # to deal with array values, rather than the single command nameservice.rb
  # expects to be returned by modifycmd. Thus we don't bother defining modifycmd.

  def set(param, value)
    self.class.validate(param, value)
    current_members = @property_value_cache_hash[:members]
    if param == :members
      # If we are meant to be authoritative for the group membership
      # then remove all existing members who haven't been specified
      # in the manifest.
      remove_unwanted_members(current_members, value) if @resource[:auth_membership] and not current_members.nil?

      # if they're not a member, make them one.
      add_members(current_members, value)
    elsif ns_to_ds_attribute_map.key? param
      exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
      # JJM: The following line just maps the NS name to the DS name
      #      e.g. { :uid => 'UniqueID' }
      exec_arg_vector << ns_to_ds_attribute_map[param]
      # JJM: The following line sends the actual value to set the property to
      exec_arg_vector << value.to_s
      begin
        execute(exec_arg_vector)
      rescue Puppet::ExecutionFailure => detail
        fail("Could not set #{param} on #{@resource.class.name}[#{@resource.name}]: #{detail}")
      end
    end
  end

  # NBK: we override @parent.create as we need to execute a series of commands
  # to create objects with dscl, rather than the single command nameservice.rb
  # expects to be returned by addcmd. Thus we don't bother defining addcmd.
  def create
    if exists?
      info "already exists"
      return nil
    end

    # NBK: First we create the object with a known guid so we can set the contents
    # of the password hash if required
    # Shelling out sucks, but for a single use case it doesn't seem worth
    # requiring people install a UUID library that doesn't come with the system.
    # This should be revisited if Puppet starts managing UUIDs for other platform
    # user records.
    guid = %x{/usr/bin/uuidgen}.chomp

    exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
    exec_arg_vector << ns_to_ds_attribute_map[:guid] << guid
    begin
      execute(exec_arg_vector)
    rescue Puppet::ExecutionFailure => detail
      fail("Could not set GeneratedUID for #{@resource.class.name} #{@resource.name}: #{detail}")
    end

    # create all the standard properties before setting password
    Puppet::Type.type(@resource.class.name).validproperties.each do |property|
      next if property == :ensure
      value = @resource.should(property)
      if property == :gid and value.nil?
        value = self.class.next_system_id(id_type='gid')
      end
      if property == :uid and value.nil?
        value = self.class.next_system_id(id_type='uid')
      end
      if value != "" and not value.nil?
        if property == :members
          add_members(nil, value)
        elsif ns_to_ds_attribute_map.key? property
          exec_arg_vector = self.class.get_exec_preamble("-create", @resource[:name])
          exec_arg_vector << ns_to_ds_attribute_map[property]
          next if property == :password  # skip setting the password here
          exec_arg_vector << value.to_s
          begin
            execute(exec_arg_vector)
          rescue Puppet::ExecutionFailure => detail
            fail("Could not create #{@resource.class.name} #{@resource.name}: #{detail}")
          end
        end
      end
    end

    # the dscl invocations above trigger updates by opendirectoryd, and those
    # are done asynchronously, with no obvious way to detect their completion.
    # So, solve this race condition the awful way, by sleeping.  The real
    # upstream fix will, one hopes, do a better job.
    Puppet.debug("sleeping four seconds to allow opendirectoryd's writes to the user plist file to quiesce.  Terrible hack.")
    sleep 4

    # and now set the password, salt, and iterations
    if value = @resource.should(:password) and value != ""
      self.class.set_password(@resource[:name], guid, value)
    end
    if value = @resource.should(:salt) and value != ""
      self.salt = value
    end
    if value = @resource.should(:iterations) and value != ""
      self.iterations = value
    end
  end

  def remove_unwanted_members(current_members, new_members)
    current_members.each do |member|
      if not new_members.flatten.include?(member)
        cmd = [:dseditgroup, "-o", "edit", "-n", ".", "-d", member, @resource[:name]]
        begin
          execute(cmd)
        rescue Puppet::ExecutionFailure => detail
          # TODO: We're falling back to removing the member using dscl due to rdar://8481241
          # This bug causes dseditgroup to fail to remove a member if that member doesn't exist
          cmd = [:dscl, ".", "-delete", "/Groups/#{@resource.name}", "GroupMembership", member]
          begin
            execute(cmd)
          rescue Puppet::ExecutionFailure => detail
            fail("Could not remove #{member} from group: #{@resource.name}, #{detail}")
          end
        end
      end
    end
  end

  def add_members(current_members, new_members)
    new_members.flatten.each do |new_member|
      if current_members.nil? or not current_members.include?(new_member)
        cmd = [:dseditgroup, "-o", "edit", "-n", ".", "-a", new_member, @resource[:name]]
        begin
          execute(cmd)
        rescue Puppet::ExecutionFailure => detail
          fail("Could not add #{new_member} to group: #{@resource.name}, #{detail}")
        end
      end
    end
  end

  def deletecmd
    # JJM: Like addcmd, only called when deleting the object itself
    #    Note, this isn't used to delete properties of the object,
    #    at least that's how I understand it...
    self.class.get_exec_preamble("-delete", @resource[:name])
  end

  def getinfo(refresh = false)
    # JJM 2007-07-24:
    #      Override the getinfo method, which is also defined in nameservice.rb
    #      This method returns and sets @infohash
    # I'm not re-factoring the name "getinfo" because this method will be
    # most likely called by nameservice.rb, which I didn't write.
    if refresh or (! defined?(@property_value_cache_hash) or ! @property_value_cache_hash)
      # JJM 2007-07-24: OK, there's a bit of magic that's about to
      # happen... Let's see how strong my grip has become... =)
      #
      # self is a provider instance of some Puppet::Type, like
      # Puppet::Type::User::ProviderDirectoryservice for the case of the
      # user type and this provider.
      #
      # self.class looks like "user provider directoryservice", if that
      # helps you ...
      #
      # self.class.resource_type is a reference to the Puppet::Type class,
      # probably Puppet::Type::User or Puppet::Type::Group, etc...
      #
      # self.class.resource_type.validproperties is a class method,
      # returning an Array of the valid properties of that specific
      # Puppet::Type.
      #
      # So... something like [:comment, :home, :password, :shell, :uid,
      # :groups, :ensure, :gid]
      #
      # Ultimately, we add :name to the list, delete :ensure from the
      # list, then report on the remaining list. Pretty whacky, ehh?
      type_properties = [:name] + self.class.resource_type.validproperties
      type_properties.delete(:ensure) if type_properties.include? :ensure
      type_properties << :guid  # append GeneratedUID so we just get the report here
      @property_value_cache_hash = self.class.single_report(@resource[:name], *type_properties)
      [:uid, :gid].each do |param|
        @property_value_cache_hash[param] = @property_value_cache_hash[param].to_i if @property_value_cache_hash and @property_value_cache_hash.include?(param)
      end
    end
    @property_value_cache_hash
  end
end


Puppet::Type.type(:darwinuser).provide :directoryservice, :parent => Puppet::Provider::NameService::CustomDirectoryService do
  desc "User management using DirectoryService on OS X."

  commands :dscl => "/usr/bin/dscl"
  confine :operatingsystem => :darwin
  defaultfor :operatingsystem => :darwin

  # JJM: DirectoryService can manage passwords.
  #      This needs to be a special option to dscl though (-passwd)
  has_feature :manages_passwords

  # JJM: comment matches up with the /etc/passwd concept of an user
  options :comment, :key => "realname"
  options :password, :key => "passwd"

  autogen_defaults :home => "/var/empty", :shell => "/usr/bin/false"

  verify :gid, "GID must be an integer" do |value|
    value.is_a? Integer
  end 

  verify :uid, "UID must be an integer" do |value|
    value.is_a? Integer
  end 

  def autogen_comment
    @resource[:name].capitalize
  end 

  # The list of all groups the user is a member of.
  # JJM: FIXME: Override this method...
  def groups
    groups = []
    groups.join(",")
  end 

  # This is really lame.  We have to iterate over each
  # of the groups and add us to them.
  def groups=(groups)
  end
end
