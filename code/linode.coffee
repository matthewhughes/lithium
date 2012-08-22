# linode.coffee
# ScraperWiki Limited.  2012.

LinodeClient = (require 'linode-api').LinodeClient
_            = require('underscore')
_s           = require('underscore.string')
async        = require 'async'

mex           = (require 'utility').mex
LithiumConfig = (require 'lithium_config').LithiumConfig
Instance      = (require 'instance').Instance

exports.Linode = class Linode extends Instance
  api_key = process.env['LINODE_API_KEY']
  api_key = 'fakeapikey' if not api_key?

  # Do Not Assign
  @client: new LinodeClient api_key

  @create: (config, callback) ->
    super config

    # Create Linode via this waterfall.
    # Parameters from the last function's call back are
    # sent to the next function in the array.
    async.waterfall [
      @_get_config_linode_plan
      @_linode_create
      @_update_linode_label
      @_addprivate
      @_distro
      @_create_disk
      @_disk_created
      @_create_linode_config
      @_cache_ips
      @_create_subdomain
    ], (err, result) =>
      # This is called at the end of the waterfall,
      # or if any of the callbacks returns an error.
      # TODO: improve error handling
      console.log err if err?
      @_got_linode_id result, callback if result?

  @destroy: (name, callback) ->
    @get name, (instance) =>
      @client.call 'linode.delete',
         'LinodeID': instance.id
         'skipChecks': true
         , (err, res) =>
           @client.call 'domain.resource.list',
             DomainID: 352960
             , (err, res) =>
               r = _.find res, (x) =>
                 x.NAME == name
               @client.call 'domain.resource.delete',
                 DomainID: 352960
                 ResourceID: r.RESOURCEID
                 , callback

  @rename: (name, newname, callback) ->
    @get name, (instance) =>
      @client.call 'linode.update',
         'LinodeID': instance.id
         'Label': newname
         , (err, res) ->
           callback(err)

  # Returns (by passing to the *callback* function) the arguments (err, res) where *err*
  # is a error, and *res* is an array of instances.
  @list: (callback) ->
    @client.call 'linode.list', null, (err, res) =>
      list = _.map res, _convert_to_instance
      async.map list, (x, cb) =>
        @_get_ips x.id, ( (err, public_ip, private_ip) =>
          x.ip_address = public_ip
          x.private_ip_address = private_ip
          cb null, x )
      , (error, results) -> callback err, results

  # Returns an instance given its name.
  # TODO: put err in to config
  @get: (name, callback) ->
    @list (err, list) ->
      k = _.find list, (n) ->
        n.name == name
      throw "instance not found" unless k?
      callback k

  # Returns (by passing to the *callback* function) the arguments (err, res) whre
  # *err* is an error, and *res* is an array of jobs.
  @jobs: (instance, callback) ->
    @client.call 'linode.job.list',
      'LinodeID': instance.id
      , callback

  start: (callback) ->
    Linode.client.call 'linode.boot',
      'LinodeID': @id
      , (err, res) ->
        callback()

  stop: (callback) ->
    Linode.client.call 'linode.shutdown',
      'LinodeID': @id
      , (err, res) ->
        callback()

  restart: (callback) ->
    Linode.client.call 'linode.reboot',
      'LinodeID': @id
      , (err, res) ->
        callback()


  ####### Only Private Methods Below Here #######

  ### @create waterfall functions ###

  # Get a config's corresponding Linode plan
  @_get_config_linode_plan: (callback) =>
    @_get_plan @config.ram, @config.disk_size, callback

  @_linode_create: (plan_id, callback) =>
    @client.call 'linode.create',
      'DatacenterID': 7
      'PlanID': plan_id
      'PaymentTerm': 1
    , (err, res) =>
      callback err, res

  @_update_linode_label: (res, callback) =>
      @linode_id = res['LinodeID']
      @list (err, l) =>
        instances = _.filter l, (x) =>
          instance_config = x.name.match(/.*(?=-\d+$)/)
          instance_config? and instance_config[0] == @config.name

        # Strip out everything except the final number from the instance names.
        numbers = _.map instances, (x) -> +x.name.replace(/.*(?=\d+$)/, '')

        number = mex numbers
        @instance_name = "#{@config.name}-#{number}"

        @client.call 'linode.update',
          'LinodeID': @linode_id
          'Label': @instance_name
          , callback

  @_addprivate: (res, callback) =>
    @client.call 'linode.ip.addprivate',
      'LinodeID': @linode_id
      , callback

  @_distro: (res, callback) =>
    @_get_distro @config.distribution, callback

  # Create a system (distribution) disk
  # TODO: multiple disks?
  # TODO: change root password default
  @_create_disk: (id, callback) =>
    @client.call 'linode.disk.createfromdistribution',
      'LinodeID': @linode_id
      'DistributionID': id
      'Label': 'system'
      'Size': @config.disk_size * 1000
      'rootPass': Math.random() + "" + Math.random()
      'rootSSHKey': LithiumConfig.sshkey_public()
      , callback

  @_disk_created: (res, callback) =>
    @disk_id = res['DiskID']
    @_get_kernel @config.kernel, callback

  @_create_linode_config: (kernel_id, callback) =>
    @client.call 'linode.config.create',
      'LinodeID': @linode_id
      'KernelID': kernel_id
      'Label': @config.name
      'Comments': @config.description
      'DiskList': @disk_id
      'RootDeviceNum': 1
      , callback

  @_cache_ips: (_, callback) =>
    @_get_ips @linode_id, (err, pub, prv) =>
      @public_ip = pub
      @private_ip = prv
      callback err, {}

  @_create_subdomain: (_, callback) =>
    @client.call 'domain.resource.create',
      DomainID: 352960
      Type: 'A'
      Name: @instance_name
      Target: @public_ip
      TTL_sec: 3600
      , callback

  @_got_linode_id: (res, callback) =>
      @client.call 'linode.list', {LinodeID:@linode_id}, (err, res) ->
        callback err, _convert_to_instance res[0]

  ### End create waterfall functions ###

  # Takes RAM as MB and disk as GB.
  @_get_plan: (ram, disk, callback) ->
    @client.call 'avail.LinodePlans', null, (err, res) ->
      p =  _.find res, (plan) ->
        plan.DISK == disk and plan.RAM == ram
      callback "Plan not found", null unless p?
      callback err, p.PLANID

  @_get_distro: (name, callback) ->
    @client.call 'avail.distributions', null, (err, res) ->
      d = _.find res, (distro) ->
        distro['LABEL'] == name
      callback err, d['DISTRIBUTIONID']

  @_get_kernel: (version, callback) ->
    @client.call 'avail.kernels', null, (err, res) ->
      k = _.find res, (kernel) ->
        _s.contains kernel['LABEL'], version
      callback err, k['KERNELID']

  @_get_ips: (linode_id, callback) ->
   @client.call 'linode.ip.list',
     'LinodeID': linode_id
     , (err, res) ->
       public_record = _.find res, (r) -> r.ISPUBLIC is 1
       private_record = _.find res, (r) -> r.ISPUBLIC is 0
       if private_record?
         callback err, public_record.IPADDRESS, private_record.IPADDRESS
       else
         callback err, public_record.IPADDRESS, null

# Convert the Linode API JSON representation for a linode server
# into an instance of the Linode class.
_convert_to_instance = (l) =>
  o = {name: l['LABEL'].toString(), state: l['STATUS'], id: l['LINODEID']}
  # The config is derived from the name, by removing the "-1"
  # bit at the end.
  config = o.name.replace /-\d+$/, ''
  new Linode config, o.id, o.name, o.state
