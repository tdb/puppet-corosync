require 'pathname'
require Pathname.new(__FILE__).dirname.dirname.expand_path + 'crmsh'

Puppet::Type.type(:cs_location).provide(:crm, parent: Puppet::Provider::Crmsh) do
  desc 'Specific provider for a rather specific type since I currently have no plan to
        abstract corosync/pacemaker vs. keepalived.  This provider will check the state
        of current primitive locations on the system; add, delete, or adjust various
        aspects.'

  # Path to the crm binary for interacting with the cluster configuration.
  # Decided to just go with relative.
  commands crm: 'crm'

  def self.instances
    block_until_ready

    instances = []

    cmd = [command(:crm), 'configure', 'show', 'xml']
    if Puppet::Util::Package.versioncmp(Puppet::PUPPETVERSION, '3.4') == -1
      # rubocop:disable Lint/UselessAssignment
      raw, status = Puppet::Util::SUIDManager.run_and_capture(cmd)
      # rubocop:enable Lint/UselessAssignment
    else
      # rubocop:disable Lint/UselessAssignment
      raw = Puppet::Util::Execution.execute(cmd)
      status = raw.exitstatus
      # rubocop:enable Lint/UselessAssignment
    end
    doc = REXML::Document.new(raw)

    doc.root.elements['configuration'].elements['constraints'].each_element('rsc_location') do |e|
      items = e.attributes

      location_instance = {
        name:               items['id'],
        ensure:             :present,
        primitive:          items['rsc'],
        node_name:          items['node'],
        score:              items['score'],
        resource_discovery: items['resource-discovery'],
        provider:           name
      }
      instances << new(location_instance)
    end
    instances
  end

  # Create just adds our resource to the property_hash and flush will take care
  # of actually doing the work.
  def create
    @property_hash = {
      name:               @resource[:name],
      ensure:             :present,
      primitive:          @resource[:primitive],
      node_name:          @resource[:node_name],
      score:              @resource[:score],
      resource_discovery: @resource[:resource_discovery]
    }
  end

  # Unlike create we actually immediately delete the item.
  def destroy
    debug('Removing location')
    Puppet::Provider::Crmsh.run_command_in_cib(['crm', 'configure', 'delete', @resource[:name]], @resource[:cib])
    @property_hash.clear
  end

  #
  # Getter that obtains the our service that should have been populated by
  # prefetch or instances (depends on if your using puppet resource or not).
  def primitive
    @property_hash[:primitive]
  end

  # Getter that obtains the our node_name that should have been populated by
  # prefetch or instances (depends on if your using puppet resource or not).
  def node_name
    @property_hash[:node_name]
  end

  # Getter that obtains the our score that should have been populated by
  # prefetch or instances (depends on if your using puppet resource or not).
  def score
    @property_hash[:score]
  end

  # Our setters for the node_name and score.  Setters are used when the
  # resource already exists so we just update the current value in the property
  # hash and doing this marks it to be flushed.

  def primitive=(should)
    @property_hash[:primitive] = should
  end

  def node_name=(should)
    @property_hash[:node_name] = should
  end

  def score=(should)
    @property_hash[:score] = should
  end

  # Flush is triggered on anything that has been detected as being
  # modified in the property_hash.  It generates a temporary file with
  # the updates that need to be made.  The temporary file is then used
  # as stdin for the crm command.
  def flush
    unless @property_hash.empty?
      updated = "location #{@property_hash[:name]} #{@property_hash[:primitive]}"
      updated << " resource-discovery=#{@property_hash[:resource_discovery]}" if feature?(:discovery)
      updated << " #{@property_hash[:score]}: #{@property_hash[:node_name]}"
      debug("Loading update: #{updated}")
      Tempfile.open('puppet_crm_update') do |tmpfile|
        tmpfile.write(updated)
        tmpfile.flush
        Puppet::Provider::Crmsh.run_command_in_cib(['crm', 'configure', 'load', 'update', tmpfile.path.to_s], @resource[:cib])
      end
    end
  end
end
