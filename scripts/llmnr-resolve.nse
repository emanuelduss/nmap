local nmap = require "nmap"
local stdnse = require "stdnse"
local table = require "table"
local packet = require "packet"
local ipOps = require "ipOps"
local target = require "target"
local math = require "math"
local string = require "string"

description = [[
Resolves a hostname by using the LLMNR (Link-Local Multicast Name Resolution) protocol.

The script works by sending a LLMNR Standard Query containing the hostname to
the 5355 UDP port on the 224.0.0.252 multicast address. It listens for any
LLMNR responses that are sent to the local machine with a 5355 UDP source port.
A hostname to resolve must be provided.

For more information, see:
* http://technet.microsoft.com/en-us/library/bb878128.aspx
]]

---
--@args llmnr-resolve.hostname Hostname to resolve.
--
--@args llmnr-resolve.timeout Max time to wait for a response. (default 3s)
--
--@usage
-- nmap --script llmnr-resolve --script-args 'llmnr-resolve.hostname=examplename' -e wlan0
--
--@output
-- Pre-scan script results:
-- | llmnr-resolve:
-- |   acer-PC : 192.168.1.4
-- |_  Use the newtargets script-arg to add the results as targets
--

prerule = function()
  if not nmap.is_privileged() then
    stdnse.verbose1("not running due to lack of privileges.")
    return false
  end
  return true
end

author = "Hani Benhabiles"

license = "Same as Nmap--See https://nmap.org/book/man-legal.html"

categories = {"discovery", "safe", "broadcast"}


--- Returns a raw llmnr query
-- @param hostname Hostname to query for.
-- @return query Raw llmnr query.
local llmnrQuery = function(hostname)
  return string.pack(">I2I2I2I2I2I2 s1x I2I2",
    math.random(0,65535), -- transaction ID
    0x0000, -- Flags: Standard Query
    0x0001, -- Questions = 1
    0x0000, -- Answer RRs = 0
    0x0000, -- Authority RRs = 0
    0x0000, -- Additional RRs = 0
    hostname, -- Hostname
    0x0001, -- Type: Host Address
    0x0001) -- Class: IN
end

--- Sends a llmnr query.
-- @param query Query to send.
local llmnrSend = function(query, mcast, mport)
  -- Multicast IP and UDP port
  local sock = nmap.new_socket()
  local status, err = sock:connect(mcast, mport, "udp")
  if not status then
    stdnse.debug1("%s", err)
    return
  end
  sock:send(query)
  sock:close()
end

-- Listens for llmnr responses
-- @param interface Network interface to listen on.
-- @param timeout Maximum time to listen.
-- @param result table to put responses into.
local llmnrListen = function(interface, timeout, result)
  local condvar = nmap.condvar(result)
  local start = nmap.clock_ms()
  local listener = nmap.new_socket()
  local status, l3data, _

  -- packets that are sent to our UDP port number 5355
  local filter = 'dst host ' .. interface.address .. ' and udp src port 5355'
  listener:set_timeout(100)
  listener:pcap_open(interface.device, 1024, true, filter)

  while (nmap.clock_ms() - start) < timeout do
    status, _, _, l3data = listener:pcap_receive()
    if status then
      local p = packet.Packet:new(l3data, #l3data)
      -- Skip IP and UDP headers
      local llmnr = string.sub(l3data, p.ip_hl*4 + 8 + 1)
      -- Flags
      local trans, flags, questions = string.unpack(">I2 I2 I2", llmnr)

      -- Make verifications
      -- Message == Response bit
      -- and 1 Question (hostname we requested) and
      if ((flags >> 15) == 1) and questions == 0x01 then
        stdnse.debug1("got response from %s", p.ip_src)
        -- Skip header's 12 bytes
        -- extract host length
        local qlen, index = string.unpack(">B", llmnr, 13)
        -- Skip hostname, null byte, type field and class field
        index = index + qlen + 1 + 2 + 2

        -- Now, answer record
        local response, alen = {}
        -- Extract hostname with the correct case sensitivity.
        response.hostname, index = string.unpack(">s1x", llmnr, index)

        -- skip type, class, ttl, dlen
        index = index + 2 + 2 + 4 + 2
        response.address, index = string.unpack(">c4", llmnr, index)
        response.address = ipOps.str_to_ip(response.address)
        table.insert(result, response)
      else
        stdnse.debug1("skipped llmnr response.")
      end
    end
  end
  condvar("signal")
end

-- Returns the network interface used to send packets to a target host.
--@param target host to which the interface is used.
--@return interface Network interface used for target host.
local getInterface = function(interfaces, target)
  -- First, create dummy UDP connection to get interface
  local sock = nmap.new_socket()
  local status, err = sock:connect(target, "12345", "udp")
  if not status then
    stdnse.verbose1("%s", err)
    return
  end
  local status, address, _, _, _ = sock:get_info()
  if not status then
    stdnse.verbose1("%s", err)
    return
  end
  for _, interface in pairs(interfaces) do
    if interface.address == address then
      return interface
    end
  end
end

local filter_interfaces = function (if_table)
  if if_table.up == "up" and if_table.address:match("%d+%.%d+%.%d+%.%d+") then
    return if_table
  end
end


action = function()
  local timeout = stdnse.parse_timespec(stdnse.get_script_args(SCRIPT_NAME .. ".timeout"))
  timeout = (timeout or 3) * 1000
  local hostname = stdnse.get_script_args(SCRIPT_NAME .. ".hostname")
  local result, output = {}, {}
  local mcast = "224.0.0.252"
  local mport = 5355

  -- Check if a valid hostname was provided
  if not hostname or #hostname == 0 then
    stdnse.debug1("no hostname was provided.")
    return
  end

  -- Check if a valid interface was provided
  local interface
  local interfaces = stdnse.get_script_interfaces(filter_interfaces)
  if #interfaces > 1 then
    -- TODO: send on multiple interfaces
    interface = getInterface(interfaces, mcast)
  elseif #interfaces == 1 then
    interface = interfaces[1]
  end

  if not interface then
    return stdnse.format_output(false, ("Couldn't get interface for %s"):format(mcast))
  end

  -- Launch listener thread
  stdnse.new_thread(llmnrListen, interface, timeout, result)
  -- Craft raw query
  local query = llmnrQuery(hostname)
  -- Small sleep so the listener doesn't miss the response
  stdnse.sleep(0.5)
  -- Send query
  llmnrSend(query, mcast, mport)
  -- Wait for listener thread to finish
  local condvar = nmap.condvar(result)
  condvar("wait")

  -- Check responses
  if #result > 0 then
    for _, response in pairs(result) do
      table.insert(output, response.hostname.. " : " .. response.address)
      if target.ALLOW_NEW_TARGETS then
        target.add(response.address)
      end
    end
    if ( not(target.ALLOW_NEW_TARGETS) ) then
      table.insert(output,"Use the newtargets script-arg to add the results as targets")
    end
    return stdnse.format_output(true, output)
  end
end
